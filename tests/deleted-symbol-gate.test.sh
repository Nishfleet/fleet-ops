#!/usr/bin/env bash
# tests/deleted-symbol-gate.test.sh
#
# fleet-ops#6052: a mechanical gate so a PR that deletes a lib/ or bin/
# symbol definition cannot merge while any test still references it.
#
# Fault: #5993 (seat-lib deletion, #4263) merged 2026-09-12T13:19Z while the
# P14 suite still asserted the deleted contract. Main then went red THREE
# separate times, one cause at a time, each costing a judge run and
# red-blocking every open PR:
#   1. pi-issue-run resume tool-count (stubbed session_tool_calls)
#   2. tests/seat-credentials-bad-replay.test.sh extracting
#      is_credentials_error / mark_seat_credentials_bad from the deleted
#      lib/seat-lib.sh
#   3. tests/repair-rung.test.sh:46 asserting _pick_repair_rung_seat
# Each was found by a P14 run on the NEXT PR, not on #5993 itself.
#
# The gate (the issue's "smallest thing", as a P14 step): take the PR's
# deleted definitions on lib/ bin/ (diff lines of the forms `name() {`,
# `name=`, `export name=`, python `def name(` / `class Name`), drop names
# still defined somewhere in the head tree (the #6037 re-host/restore path),
# and fail if any remaining name is still referenced under tests/ — the scan
# is the whole tests/ tree, so ci.yml-listed, bash-hosted (#4396 pattern) and
# unlisted-orphan tests all count.
#
# This file IS the P14 step: on pull_request events the live section diffs
# origin/main...HEAD (checkout has fetch-depth: 0) and a violation fails P14,
# which branch protection requires — so the PR cannot merge until the test is
# ported or the symbol is re-hosted. Hosted by tests/ci-standards-audit.test.sh
# (the worker App cannot push .github/workflows/**); the named pin in
# tests/p14-test-listing-gate.test.sh keeps that host line pinned.
#
# Hermetic: offline fixtures + a throwaway git repo in a scratch dir prove
# the acceptance drill (a deletion with the test unported goes RED on the
# gate; the same diff with the test ported goes GREEN). No gh, no network,
# no systemd, no writes outside the scratch dir.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- the gate ---------------------------------------------------------------
# deleted_symbol_gate PATCH_FILE TESTS_DIR [SCAN_DIR...]
#
#   PATCH_FILE  unified patch, already filtered to lib/ and bin/ paths
#               (empty file = no deletions = vacuous pass)
#   TESTS_DIR   directory whose files count as "tests still referencing"
#   SCAN_DIR..  head-tree dirs where a surviving definition keeps the
#               contract alive (live: lib/ and bin/ of the repo)
#
# Exit 0 when every deleted definition is either still defined in a scan dir
# or unreferenced by TESTS_DIR; exit 1 when a deleted definition still has a
# tests/ reference. Every judgement prints an OK/FAIL line.
deleted_symbol_gate() {
    local patch="$1" tests_dir="$2"
    shift 2
    local scan_dirs=("$@")
    local names count name re where rc=0 violations=0

    # Deleted definition lines. In a -U0 patch every deletion starts with a
    # single `-` (the `--- a/...` header starts with `--`, so it cannot
    # match); added and context lines never start with `-`.
    names="$(sed -nE \
        -e 's/^-([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(.*/\1/p' \
        -e 's/^-([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' \
        -e 's/^-export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' \
        -e 's/^-def[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(.*/\1/p' \
        -e 's/^-class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[(:]/\1/p' \
        "$patch" | sort -u)"

    if [[ -z "$names" ]]; then
        ok "gate: 0 deleted lib/ bin/ definition(s) — vacuous"
        return 0
    fi
    count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
    echo "gate: checking $count deleted lib/ bin/ definition(s): $(printf '%s' "$names" | tr '\n' ' ')"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # A surviving definition (re-hosted or re-added in the same PR) keeps
        # the contract alive — #6037 re-hosted #5993's symbols this way.
        re="^${name}[[:space:]]*[=(]|^[[:space:]]*(def|class)[[:space:]]+${name}([^A-Za-z0-9_]|$)"
        for d in ${scan_dirs[@]+"${scan_dirs[@]}"}; do
            if grep -rqE -- "$re" "$d" 2>/dev/null; then
                ok "gate: deleted '$name' is still defined in the head tree (re-hosted/re-added)"
                continue 2
            fi
        done
        # Word-boundary fixed-string scan of the whole tests tree; comments,
        # grep patterns, extract_fn calls and source stubs all count.
        where="$(grep -rlFw -- "$name" "$tests_dir" 2>/dev/null || true)"
        if [[ -n "$where" ]]; then
            echo "FAIL: gate: tests/ still references deleted symbol '$name' — port the test or re-host the symbol (fleet-ops#6052):" >&2
            printf '%s\n' "$where" | head -5 | while IFS= read -r f; do
                echo "FAIL:   $f" >&2
            done
            violations=$((violations + 1))
            rc=1
        else
            ok "gate: deleted '$name' has no tests/ reference — ported"
        fi
    done <<<"$names"

    return "$rc"
}

# --- fixtures ---------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixture patch: deletes drill_dummy_6052 from lib/, adds its replacement.
# The `+` line must never extract (only `-` lines are deletions).
cat >"$tmp/dummy-deleted.patch" <<'PATCH'
diff --git a/lib/dummy-lib-6052.sh b/lib/dummy-lib-6052.sh
--- a/lib/dummy-lib-6052.sh
+++ b/lib/dummy-lib-6052.sh
@@ -1,3 +1,4 @@
-drill_dummy_6052() {
-    echo dummy
-}
+drill_replacement_6052() {
+    echo replacement
+}
PATCH

# 1. RED: a test still asserts the deleted dummy (the #5993 state).
mkdir -p "$tmp/tests-unported"
printf '# asserts the deleted contract: grep drill_dummy_6052\n' >"$tmp/tests-unported/stale.test.sh"
out="$(deleted_symbol_gate "$tmp/dummy-deleted.patch" "$tmp/tests-unported" "$tmp/empty-scan" 2>&1)" \
    && fail "1. expected RED: test still asserts the deleted dummy"
grep -q "drill_dummy_6052" <<<"$out" || fail "1. RED output must name the deleted symbol; got: $out"
ok "1. RED: deletion + test still asserting it fails the gate (drill_dummy_6052)"

# 2. GREEN: the same deletion with the test ported to the new contract.
mkdir -p "$tmp/tests-ported"
printf '# ported: asserts drill_replacement_6052 now\n' >"$tmp/tests-ported/ported.test.sh"
out="$(deleted_symbol_gate "$tmp/dummy-deleted.patch" "$tmp/tests-ported" "$tmp/empty-scan" 2>&1)" \
    || fail "2. expected GREEN after the test port; got: $out"
ok "2. GREEN: the same deletion with the test ported passes the gate"

# 3. GREEN: the symbol is re-hosted in the head tree (#6037 path) — the
#    stale reference is allowed because the contract still exists.
mkdir -p "$tmp/scan/lib"
printf 'drill_dummy_6052() {\n    :\n}\n' >"$tmp/scan/lib/other-6052.sh"
out="$(deleted_symbol_gate "$tmp/dummy-deleted.patch" "$tmp/tests-unported" "$tmp/scan/lib" 2>&1)" \
    || fail "3. expected GREEN when the symbol is still defined elsewhere; got: $out"
grep -q "still defined" <<<"$out" || fail "3. output must say 'still defined'; got: $out"
ok "3. GREEN: deleted symbol re-hosted in the head tree keeps the gate green"

# 4. VACUOUS: a comment deletion (even one containing the name) extracts
#    nothing and never fires.
cat >"$tmp/comment-only.patch" <<'PATCH'
diff --git a/lib/dummy-lib-6052.sh b/lib/dummy-lib-6052.sh
--- a/lib/dummy-lib-6052.sh
+++ b/lib/dummy-lib-6052.sh
@@ -1,1 +0,0 @@
-# drill_dummy_6052 documentation comment
PATCH
out="$(deleted_symbol_gate "$tmp/comment-only.patch" "$tmp/tests-unported" "$tmp/empty-scan" 2>&1)" \
    || fail "4. comment-only deletions must be vacuous; got: $out"
grep -q "vacuous" <<<"$out" || fail "4. expected the vacuous line; got: $out"
ok "4. VACUOUS: comment deletions never fire (no false positive)"

# 5. ASSIGNMENT + EXPORT forms: bash top-level state counts as a symbol.
cat >"$tmp/flag-deleted.patch" <<'PATCH'
diff --git a/bin/dummy-bin-6052 b/bin/dummy-bin-6052
--- a/bin/dummy-bin-6052
+++ b/bin/dummy-bin-6052
@@ -1,2 +1,1 @@
 #!/usr/bin/env bash
-DRILL_FLAG_6052=1
-export DRILL_FLAG_6052=1
PATCH
mkdir -p "$tmp/tests-flag"
printf '# sets DRILL_FLAG_6052 for the replay\n' >"$tmp/tests-flag/flag.test.sh"
out="$(deleted_symbol_gate "$tmp/flag-deleted.patch" "$tmp/tests-flag" "$tmp/empty-scan" 2>&1)" \
    && fail "5a. expected RED for the deleted assignment still referenced by tests; got: $out"
grep -q "DRILL_FLAG_6052" <<<"$out" || fail "5a. RED output must name DRILL_FLAG_6052; got: $out"
ok "5a. RED: deleted assignment/export still referenced by tests fails the gate"

mkdir -p "$tmp/scan2/bin"
printf 'DRILL_FLAG_6052=1\nexport DRILL_FLAG_6052=1\n' >"$tmp/scan2/bin/elsewhere-6052"
out="$(deleted_symbol_gate "$tmp/flag-deleted.patch" "$tmp/tests-flag" "$tmp/scan2/bin" 2>&1)" \
    || fail "5b. expected GREEN while the flag is still defined; got: $out"
ok "5b. GREEN: deleted assignment still defined elsewhere passes"

# 6. PYTHON forms: def/class deletions in lib/*.py count too.
cat >"$tmp/py-deleted.patch" <<'PATCH'
diff --git a/lib/dummy-py-6052.py b/lib/dummy-py-6052.py
--- a/lib/dummy-py-6052.py
+++ b/lib/dummy-py-6052.py
@@ -1,2 +1,0 @@
-def drill_dummy_py_6052(nodes):
-    return nodes
-class Drill6052(Base):
-    pass
PATCH
mkdir -p "$tmp/tests-py"
printf 'from dummy_py_6052 import drill_dummy_py_6052, Drill6052\n' >"$tmp/tests-py/importer.test.py"
out="$(deleted_symbol_gate "$tmp/py-deleted.patch" "$tmp/tests-py" "$tmp/empty-scan" 2>&1)" \
    && fail "6a. expected RED for deleted python defs still imported; got: $out"
grep -q "drill_dummy_py_6052" <<<"$out" && grep -q "Drill6052" <<<"$out" \
    || fail "6a. RED output must name both python symbols; got: $out"
ok "6a. RED: deleted python def/class still referenced by tests fails the gate"

mkdir -p "$tmp/scan3/lib"
printf 'def drill_dummy_py_6052(nodes):\n    return nodes\nclass Drill6052(Base):\n    pass\n' >"$tmp/scan3/lib/re-hosted-6052.py"
out="$(deleted_symbol_gate "$tmp/py-deleted.patch" "$tmp/tests-py" "$tmp/scan3/lib" 2>&1)" \
    || fail "6b. expected GREEN while the python symbols are still defined; got: $out"
ok "6b. GREEN: python def/class still defined elsewhere passes"

# 7. END-TO-END DRILL (the acceptance, through real git): a throwaway repo
#    where commit 2 deletes a dummy symbol while a test still asserts it —
#    the gate goes RED on the real `git diff -U0` output; after porting the
#    test reference the same diff goes GREEN.
gdir="$tmp/repo"
mkdir -p "$gdir"
git -C "$gdir" init -q
git -C "$gdir" config user.email drill-6052@example.invalid
git -C "$gdir" config user.name drill-6052
mkdir -p "$gdir/lib"
cat >"$gdir/lib/drill.sh" <<'EOF'
# drill fixture (fleet-ops#6052)
drill_dummy_6052() {
    echo "i am the dummy"
}
keep_me_6052() {
    :
}
EOF
git -C "$gdir" add -A
git -C "$gdir" commit -qm "add drill fixture"
tdrill="$tmp/drill-tests"
mkdir -p "$tdrill"
printf 'the drill test asserts drill_dummy_6052 still exists\n' >"$tdrill/assert.test.sh"
sed -i '/^drill_dummy_6052() {/,/^}/d' "$gdir/lib/drill.sh"
git -C "$gdir" add -A
git -C "$gdir" commit -qm "delete drill_dummy_6052 (the deletion PR)"
git -C "$gdir" diff -U0 HEAD~1..HEAD -- lib/ >"$gdir/live.patch"
out="$(deleted_symbol_gate "$gdir/live.patch" "$tdrill" "$gdir/lib" 2>&1)" \
    && fail "7a. drill: expected RED on the real deletion with the test unported; got: $out"
grep -q "drill_dummy_6052" <<<"$out" || fail "7a. drill RED output must name the symbol; got: $out"
ok "7a. DRILL RED: real git deletion + unported test goes red on the gate"
printf 'ported: the dummy is gone; keep_me_6052 remains\n' >"$tdrill/assert.test.sh"
out="$(deleted_symbol_gate "$gdir/live.patch" "$tdrill" "$gdir/lib" 2>&1)" \
    || fail "7b. drill: expected GREEN after porting the test; got: $out"
ok "7b. DRILL GREEN: the same deletion with the test ported goes green"

# --- live: this test IS the P14 step (fleet-ops#6052) -----------------------
# On pull_request events the checkout (fetch-depth: 0, reusable-pr-checks.yml)
# has origin/main, so origin/main...HEAD is exactly the PR's own diff. A
# violation here fails P14, which branch protection requires — the PR cannot
# merge until the test is ported or the symbol re-hosted. Other events
# (push to main, merge_group, local runs) skip the live diff; the fixtures
# and drill above always run.
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    live_patch="$(mktemp)"
    trap 'rm -rf "$tmp" "$live_patch"' EXIT
    git -C "$repo_root" rev-parse --verify -q origin/main >/dev/null \
        || fail "live gate: origin/main missing on a pull_request event (fetch-depth: 0 broken?)"
    git -C "$repo_root" diff -U0 origin/main...HEAD -- lib/ bin/ >"$live_patch"
    if ! deleted_symbol_gate "$live_patch" "$repo_root/tests" "$repo_root/lib" "$repo_root/bin"; then
        fail "live gate (fleet-ops#6052): this PR deletes lib/ or bin/ definition(s) that tests/ still reference — port the test(s) or re-host the symbol(s), then re-push"
    fi
    ok "live gate: no deleted lib/ bin/ symbol in this PR is still referenced by tests/"
else
    ok "live gate skipped (GITHUB_EVENT_NAME=${GITHUB_EVENT_NAME:-unset}; only pull_request gates)"
fi

echo "deleted-symbol-gate: all checks passed"
