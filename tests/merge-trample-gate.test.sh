#!/usr/bin/env bash
# tests/merge-trample-gate.test.sh
#
# fleet-ops#1229 drill: a stale-base / worktree-gap PR whose merge diff
# deletes files its own commits never meant to touch must REJECT.
# Recreates PR #1228 (commit parented on #1215 deleting salvage while
# editing the ledger) and the HEAD-tree squash class (two-dot vs main
# shows a main-only file as deleted; the PR commit never touched it).
#
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit (nishfleet-worker cannot push .github/workflows/**).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-merge-trample-gate"
lib="$repo_root/lib/merge-trample-gate.py"
fixtures="$here/fixtures/merge-trample-gate"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
conference="$repo_root/prompts/senior-conference.md"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "merge-trample-gate.py failed py_compile"

# --- ledger line ----------------------------------------------------------
ledger=$("$gate" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'fleet-ops #1229' <<<"$ledger" || fail "ledger line must cite fleet-ops #1229"
grep -q 'PR #1228' <<<"$ledger" || fail "ledger line must cite origin PR #1228"
grep -q 'worktree-gap' <<<"$ledger" || fail "ledger line must name worktree-gap"
ok "ledger line is non-empty and cites the incident"

# --- fixture: REJECT the live #1228 worktree-gap --------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/worktree-gap-1228.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "worktree-gap-1228 must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "worktree-gap-1228 must REJECT: $out"
jq -e '.classes | index("worktree_gap")' <<<"$out" >/dev/null \
  || fail "worktree-gap-1228 must name worktree_gap: $out"
jq -e '.worktree_gap_paths | index("bin/pi-salvage-worktree")' <<<"$out" >/dev/null \
  || fail "worktree-gap-1228 must name bin/pi-salvage-worktree: $out"
rule=$(jq -r '.rule' <<<"$out")
[[ "$rule" == "$ledger" ]] || fail "REJECT.rule must be the ledger line verbatim"
ok "drill REJECT: #1228 worktree-gap (salvage deleted beside a ledger edit)"

# --- fixture: REJECT HEAD-tree squash (issue formula: merge diff vs touched)
set +e
out=$("$gate" evaluate --input "$fixtures/ghost-head-tree-squash.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "ghost-head-tree-squash must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "ghost must REJECT: $out"
jq -e '.classes | index("ghost")' <<<"$out" >/dev/null \
  || fail "ghost must name class ghost: $out"
jq -e '.ghost_paths | index("just-landed-on-main.txt")' <<<"$out" >/dev/null \
  || fail "ghost must name the main-only file: $out"
ok "drill REJECT: HEAD-tree squash deletes a file the PR commit never touched"

# --- fixture: PASS a three-dot-only feature edit --------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/clean-three-dot.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "clean-three-dot must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "clean must PASS: $out"
ok "drill PASS: three-dot feature edit with no ghost and no gap"

# --- fixture: PASS a dedicated delete (no other changes) ------------------
set +e
out=$("$gate" evaluate --input "$fixtures/dedicated-delete.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "dedicated-delete must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "dedicated-delete must PASS: $out"
ok "drill PASS: delete-only PR is not worktree-gap"

# --- fixture: PASS revert title / revert/ branch --------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/revert-allowed.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "revert-allowed must exit 0, got $rc: $out"
jq -e '.reason=="revert-title"' <<<"$out" >/dev/null \
  || fail "revert must allow via revert-title: $out"
ok "drill PASS: Revert title is allowed"

# --- fixture: PASS trample-ok: body line ----------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/trample-ok-allowed.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "trample-ok must exit 0, got $rc: $out"
jq -e '.reason=="trample-ok"' <<<"$out" >/dev/null \
  || fail "trample-ok body must allow: $out"
ok "drill PASS: trample-ok: body line is allowed"

# --- git drill: recreate #1228 and the stale-base HEAD-tree squash --------
scratch="$(mktemp -d -t merge-trample.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

git_ident() {
    git -C "$1" config user.email trample-test@localhost
    git -C "$1" config user.name trample-test
}

repo="$scratch/repo"
git -c init.defaultBranch=main init -q "$repo"
git_ident "$repo"
printf 'base\n' >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -q -m base

# main lands salvage (stand-in for #1215)
printf 'salvage\n' >"$repo/bin-pi-salvage-worktree"
mkdir -p "$repo/bin"
mv "$repo/bin-pi-salvage-worktree" "$repo/bin/pi-salvage-worktree"
git -C "$repo" add bin/pi-salvage-worktree
git -C "$repo" commit -q -m 'salvage: bank dying workers (#1215)'
mb=$(git -C "$repo" rev-parse HEAD)

# worktree-gap: next commit deletes salvage AND edits an unrelated ledger file
printf 'ledger v2\n' >"$repo/bin/fleet-decisions-ledger"
git -C "$repo" add bin/fleet-decisions-ledger
git -C "$repo" rm -q bin/pi-salvage-worktree
git -C "$repo" commit -q -m 'fix(decisions-ledger): ignore systemd self-talk'
gap_head=$(git -C "$repo" rev-parse HEAD)

set +e
out=$("$gate" evaluate --repo "$repo" --base "$mb" --head "$gap_head" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "git worktree-gap must exit 1, got $rc: $out"
jq -e '.classes | index("worktree_gap")' <<<"$out" >/dev/null \
  || fail "git worktree-gap must name worktree_gap: $out"
jq -e '.worktree_gap_paths | index("bin/pi-salvage-worktree")' <<<"$out" >/dev/null \
  || fail "git worktree-gap must name salvage: $out"
ok "git drill REJECT: #1228-shaped commit (delete merge-base files + other edits)"

# Reset to post-salvage and build a clean feature branch, then a HEAD-tree squash.
git -C "$repo" checkout -q -B main "$mb"
printf 'feature\n' >"$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q -m 'fix: add feature'
feature=$(git -C "$repo" rev-parse HEAD)

# main moves: land an unrelated file after the feature branched
git -C "$repo" checkout -q -B main "$mb"
printf 'new on main\n' >"$repo/just-landed-on-main.txt"
git -C "$repo" add just-landed-on-main.txt
git -C "$repo" commit -q -m 'feat: unrelated file on main'
main_moved=$(git -C "$repo" rev-parse HEAD)

# HEAD-tree squash: take the feature TREE (no just-landed file) and commit it
# as a child of current main. That is what a two-dot squash publishes.
feature_tree=$(git -C "$repo" rev-parse "$feature^{tree}")
squash=$(git -C "$repo" commit-tree "$feature_tree" -p "$main_moved" -m 'fix: add feature (#1)')

# Default three-dot against merge-base of (main_moved, squash)=mb would not
# see just-landed as a PR delete. Two-dot vs current main does.
set +e
out=$("$gate" evaluate --repo "$repo" --base "$main_moved" --head "$squash" \
    --diff-base "$main_moved" --touched-commits "$feature" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "git HEAD-tree squash must exit 1, got $rc: $out"
jq -e '.classes | index("ghost")' <<<"$out" >/dev/null \
  || fail "git HEAD-tree squash must name ghost: $out"
jq -e '.ghost_paths | index("just-landed-on-main.txt")' <<<"$out" >/dev/null \
  || fail "git HEAD-tree squash must name just-landed-on-main.txt: $out"
ok "git drill REJECT: stale-base HEAD-tree squash deletes a file the PR never touched"

# A real 3-way (diff against merge-base) of the FEATURE commit, not the
# squash, stays PASS — GitHub 3-way squash of a merely-behind PR keeps
# main-only files. Default evaluate uses merge-base as diff-base.
set +e
out=$("$gate" evaluate --repo "$repo" --base "$main_moved" --head "$feature" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "merely-behind feature must PASS default evaluate, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "merely-behind must PASS: $out"
ok "git drill PASS: behind-main PR evaluated three-dot (no false rebase-required)"

# --- sweep: the worktree-gap commit on first-parent is a hit --------------
git -C "$repo" checkout -q -B main "$gap_head"
set +e
sweep=$("$gate" sweep --repo "$repo" --since '1 hour ago' 2>&1)
src=$?
set -e
[[ "$src" -eq 0 ]] || fail "sweep must exit 0, got $src: $sweep"
jq -e '.hits | length >= 1' <<<"$sweep" >/dev/null \
  || fail "sweep must report the worktree-gap commit: $sweep"
jq -e '[.hits[].worktree_gap_paths[]?] | index("bin/pi-salvage-worktree")' <<<"$sweep" >/dev/null \
  || fail "sweep hit must name salvage: $sweep"
ok "sweep reports the worktree-gap first-parent commit"

# --- senior conference references the gate --------------------------------
grep -F -q 'fleet-merge-trample-gate evaluate' "$conference" \
  || fail "senior-conference.md must reference the gate"
grep -F -q "$ledger" "$conference" \
  || fail "senior-conference.md must carry the ledger line verbatim"
ok "senior-conference.md carries the gate and the ledger line"

# --- heartbeat arms only after the gate -----------------------------------
python3 - "$tier1" <<'PY' || fail "heartbeat must call the gate before gh pr merge --auto"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
gate = text.find("fleet-merge-trample-gate")
arm = text.find("gh pr merge")
auto = text.find("--auto --squash")
if gate < 0:
    raise SystemExit("fleet-merge-trample-gate missing from tier1")
# The arm we care about is the queue-pass auto-squash, which sits after
# the trample gate. An earlier gh pr merge in another block is allowed
# only if the gate still precedes the queue-pass marker+arm pair.
queue = text.find("2. queue pass starting")
if queue < 0:
    raise SystemExit("queue pass marker missing")
gate_in_queue = text.find("fleet-merge-trample-gate", queue)
arm_in_queue = text.find("gh pr merge", queue)
if gate_in_queue < 0 or arm_in_queue < 0:
    raise SystemExit("queue pass must call the gate and gh pr merge")
if gate_in_queue > arm_in_queue:
    raise SystemExit("trample gate must run BEFORE gh pr merge in the queue pass")
if "--auto --squash" not in text[arm_in_queue:arm_in_queue + 200]:
    raise SystemExit("queue-pass gh pr merge must still be --auto --squash")
PY
ok "heartbeat queue pass runs the gate before arming auto-merge"

# --- MANIFEST + no dispatcher / no new unit -------------------------------
grep -q 'bin/fleet-merge-trample-gate' "$manifest" \
  || fail "MANIFEST must install bin/fleet-merge-trample-gate"
grep -q 'lib/merge-trample-gate.py' "$manifest" \
  || fail "MANIFEST must install lib/merge-trample-gate.py"
[[ ! -e "$repo_root/bin/fleet-merge-trample-dispatcher" ]] \
  || fail "must not add a dispatcher; the gate is a pure evaluator"
[[ ! -e "$repo_root/systemd/fleet-merge-trample-gate.service" ]] \
  || fail "must not add a systemd unit"
ok "MANIFEST installs the gate; no dispatcher / no new unit"

echo "OK: merge-trample-gate drill: REJECT worktree-gap and HEAD-tree squash, PASS clean/delete-only/revert/trample-ok"
