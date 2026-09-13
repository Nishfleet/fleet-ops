#!/usr/bin/env bash
# tests/workflow-registration-inventory.test.sh
#
# fleet-ops#5692 phase 3 — fleet-workflow-registration-scan tests.
#
# Proves the scanner's decision without reaching GitHub. GitHub is
# stubbed through the scanner's documented GH env seam; the git side is
# stubbed so the "fetch origin to a temp ref" step materialises the temp
# ref against the LOCAL fixture SHA instead of the network (the ls-tree
# step in the scanner then reads the same tree, so the diff is fully
# deterministic and offline).
#
#   (a) a synthetic ACTIVE registration whose path is NOT on the default
#       branch is flagged — exit 1, report names it
#   (b) an inventory whose ACTIVE registrations all exist on the default
#       branch is clean — exit 0
#   (c) --report always exits 0, even with an orphan, and writes the report
#   (d) a real gh-api failure is the reserved exit 3 — NOT exit 1, so it
#       can never be mistaken for an orphan finding by the heartbeat
#   (e) a git fetch failure is also the reserved exit 3
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/fleet-workflow-registration-scan"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "scanner script not found: $script"
bash -n "$script" || fail "scanner failed bash -n"
"$script" --help >/dev/null || fail "scanner --help failed"
ok "script parses, --help exits 0"

# Fixture SHA: the tree the stubbed "origin default branch" resolves to.
FIXTURE_SHA="$(git -C "$repo_root" rev-parse HEAD)"
REGISTRY_REF="refs/tmp/fleet-workflow-registration-scan"

# --- mock seams --------------------------------------------------------
# mock-bin/gh   — implements the four api calls the scanner makes, with
#                 all --jq work pre-emulated (the stub echoes exactly
#                 what the real jq expressions would produce).
# mock-bin/git  — intercepts `fetch <url> <branch-ref>:<ref>` and materialises
#                 refs/tmp/... at FIXTURE_SHA locally instead of hitting
#                 the network (respecting MOCK_FETCH_FAIL=1 to simulate a
#                 network failure); every other git invocation passes through.
mock_bin="$(mktemp -d)"
trap 'rm -rf "$mock_bin"; git -C "$repo_root" update-ref -d "$REGISTRY_REF" 2>/dev/null || true' EXIT

cat > "$mock_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# drop --jq args; the outputs below are pre-emulated jq results
args=()
skip=0
for a in "$@"; do
  if [[ $skip -eq 1 ]]; then skip=0; continue; fi
  case "$a" in --jq) skip=1 ;; *) args+=("$a") ;; esac
done
subcmd="${args[0]:-}"
endpoint="${args[1]:-}"
case "$subcmd/$endpoint" in
  api/repos/mock/repo)
    echo 'main' ;;
  api/repos/mock/repo/branches/main)
    echo "$MOCK_FIXTURE_SHA" ;;
  api/repos/mock/repo/actions/workflows)
    # active registrations, pre-emulated through real jq: id|path per line
    jq -r '.workflows[] | select(.state=="active") | "\(.id)|\(.path)"' \
        "$MOCK_REGISTRATIONS_JSON" ;;
  api/repos/mock/repo/actions/workflows/*/runs?per_page=1)
    echo '3|2026-01-01T00:00:00Z success' ;;
  *)
    echo "mock gh: unhandled: $*" >&2; exit 9 ;;
esac
STUB

cat > "$mock_bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* ]]; then
  # fleet-workflow-registration-scan calls: git -C <root> fetch --depth 1 <url> refs/heads/<branch>:<ref>
  [[ "${MOCK_FETCH_FAIL:-0}" == "1" ]] && exit 128
  tail_arg="${*: -1}"
  ref="${tail_arg#*:}"
  exec "$REAL_GIT" update-ref "$ref" "$MOCK_FIXTURE_SHA"
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$mock_bin/gh" "$mock_bin/git"
REAL_GIT="$(command -v git)"
export REAL_GIT MOCK_FIXTURE_SHA="$FIXTURE_SHA"

run_scan_env() {  # run_scan_env REPORT_PATH [KEY=VAL...] -- [extra args...]
    local report="$1"; shift
    local extra_env=()
    while [[ "$1" != "--" ]]; do extra_env+=("$1"); shift; done
    shift
    env -i \
        PATH="$mock_bin:$PATH" HOME="$HOME" \
        MOCK_FIXTURE_SHA="$FIXTURE_SHA" REAL_GIT="$REAL_GIT" \
        FLEET_REGISTRATION_SCAN_REPORT="$report" \
        MOCK_REGISTRATIONS_JSON="$mock_bin/registrations.json" \
        "${extra_env[@]}" \
        "$script" "mock/repo" "$@"
}
run_scan() {  # run_scan REPORT_PATH [extra args...]
    local report="$1"; shift
    run_scan_env "$report" -- "$@"
}

# --- registrations payloads -------------------------------------------
# (a) synthetic orphan: ghost.yml is ACTIVE on GitHub but absent from the
#     fixture tree; ci.yml exists so it must never be flagged.
cat > "$mock_bin/registrations.json" <<'EOF'
{"workflows":[
  {"id":123,"name":"CI","path":".github/workflows/ci.yml","state":"active"},
  {"id":999,"name":"Ghost","path":".github/workflows/ghost.yml","state":"active"}
]}
EOF

# --- (a) orphan must be flagged ---------------------------------------
orphan_report="$mock_bin/report-orphan.md"
set +e
run_scan "$orphan_report" > "$mock_bin/orphan.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "synthetic orphan must exit 1, got $rc; out: $(cat "$mock_bin/orphan.out")"
grep -q "ghost.yml" "$orphan_report" || fail "report must name the orphan path ghost.yml"
grep -q "999" "$orphan_report" || fail "report must name the orphan workflow id 999"
if grep -qF '.github/workflows/ci.yml` (workflow id 123' "$orphan_report"; then
    fail "ci.yml exists on the default branch and must NOT be flagged as an orphan"
fi
ok "synthetic orphan flagged: exit 1, report names ghost.yml (id 999), healthy ci.yml not flagged"

# --- (b) clean inventory exits 0 --------------------------------------
# All active registrations exist on the fixture default branch, so derive
# them from the same tree the scanner will ls-tree.
mapfile -t files < <(git -C "$repo_root" ls-tree -r --name-only "HEAD" -- .github/workflows | grep -E '\.ya?ml$')
[[ ${#files[@]} -gt 0 ]] || fail "fixture tree must contain at least one workflow"
{
    echo '{"workflows":['
    first=1
    for f in "${files[@]}"; do
        [[ $first -eq 1 ]] || echo ,
        printf '{"id":%d,"name":"W %s","path":"%s","state":"active"}' \
            $((RANDOM % 10000 + 1)) "$f" "$f"
        first=0
    done
    echo ']}'
} > "$mock_bin/registrations.json"

clean_report="$mock_bin/report-clean.md"
set +e
run_scan "$clean_report" > "$mock_bin/clean.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "clean inventory must exit 0, got $rc; out: $(cat "$mock_bin/clean.out")"
grep -q "Orphans.*\*\*0\*\*" "$clean_report" || fail "clean report must show 0 orphans"
ok "clean inventory exits 0, report shows 0 orphans"

# --- (c) --report always exits 0, orphan or not -----------------------
# Restore the orphan payload and run with --report.
cat > "$mock_bin/registrations.json" <<'EOF'
{"workflows":[
  {"id":999,"name":"Ghost","path":".github/workflows/ghost.yml","state":"active"}
]}
EOF
report_report="$mock_bin/report-mode.md"
set +e
run_scan "$report_report" --report > "$mock_bin/report.out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "--report must exit 0 even with an orphan, got $rc; out: $(cat "$mock_bin/report.out")"
[[ -s "$report_report" ]] || fail "--report must write a non-empty report"
grep -q "ghost.yml" "$report_report" || fail "--report output must still contain the orphan"
ok "--report exits 0 with orphan present, report written and complete"

# --- real-failure stub rebuilt with a fail toggle ---------------------
# Same output paths for every healthy call; MOCK_GH_WORKFLOWS_FAIL=1
# makes the workflows listing fail so scenario (d) can exercise the
# scanner's reserved exit-3 mapping.
cat > "$mock_bin/gh" <<'STUB'
#!/usr/bin/env bash
args=()
skip=0
for a in "$@"; do
  if [[ $skip -eq 1 ]]; then skip=0; continue; fi
  case "$a" in --jq) skip=1 ;; *) args+=("$a") ;; esac
done
subcmd="${args[0]:-}"
endpoint="${args[1]:-}"
if [[ "${MOCK_GH_WORKFLOWS_FAIL:-0}" == "1" && "$subcmd/$endpoint" == "api/repos/mock/repo/actions/workflows" ]]; then
  echo "mock gh: workflows listing failed" >&2
  exit 1
fi
case "$subcmd/$endpoint" in
  api/repos/mock/repo)
    echo 'main' ;;
  api/repos/mock/repo/branches/main)
    echo "$MOCK_FIXTURE_SHA" ;;
  api/repos/mock/repo/actions/workflows)
    jq -r '.workflows[] | select(.state=="active") | "\(.id)|\(.path)"' \
        "$MOCK_REGISTRATIONS_JSON" ;;
  api/repos/mock/repo/actions/workflows/*/runs?per_page=1)
    echo '3|2026-01-01T00:00:00Z success' ;;
  *)
    echo "mock gh: unhandled: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$mock_bin/gh"

# --- (d) gh api failure -> reserved exit 3, NOT 1 (not an orphan) -----
gfail_report="$mock_bin/report-ghfail.md"
set +e
run_scan_env "$gfail_report" MOCK_GH_WORKFLOWS_FAIL=1 -- > "$mock_bin/ghfail.out" 2>&1
rc=$?
set -e
[[ $rc -eq 3 ]] || fail "gh api failure must exit 3 (reserved real-failure), got $rc; out: $(cat "$mock_bin/ghfail.out")"
[[ ! -s "$gfail_report" ]] || fail "gh api failure must abort BEFORE the report is written"
ok "gh api failure exits 3 (not 1) and writes no report"

# --- (e) git fetch failure -> reserved exit 3 -------------------------
fetchfail_report="$mock_bin/report-fetchfail.md"
set +e
run_scan_env "$fetchfail_report" MOCK_FETCH_FAIL=1 -- > "$mock_bin/fetchfail.out" 2>&1
rc=$?
set -e
[[ $rc -eq 3 ]] || fail "git fetch failure must exit 3 (reserved real-failure), got $rc; out: $(cat "$mock_bin/fetchfail.out")"
[[ ! -s "$fetchfail_report" ]] || fail "git fetch failure must abort BEFORE the report is written"
ok "git fetch failure exits 3 (not 1), no report written"

ok "all workflow-registration-inventory tests passed"
