#!/usr/bin/env bash
# tests/fleet-research-sweep-canary.test.sh
#
# Proves the continuous-research prevention canary (fleet-ops#3130) offline:
#   1. state.json missing -> exit 1 (watcher broken), LOUD.
#   2. state.json unparseable -> exit 1 (watcher broken).
#   3. state.json missing last_run_at -> exit 1 (watcher broken).
#   4. Healthy sweep (ran + >= 1 mechanism in window) -> exit 0, no filing,
#      observe-to-close closes any open canary-filed ticket.
#   5. Ran but produced 0 mechanisms in window -> exit 0, files
#      `fix(research-sweep):` ticket with the marker + evidence body.
#   6. Did not run in window -> exit 0, files `fix(research-sweep):` ticket.
#   7. Dedup: second tick with same violation + open ticket -> no second
#      filing.
#   8. FLEET_RESEARCH_SWEEP_FILE=0 -> exit 0, no filing, LOUD.
#   9. Heartbeat-tier1 wires block 46 + MANIFEST installs it +
#      ci-standards-audit hosts this test.
#  10. --help exits 0 without touching state.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-research-sweep-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"
host_audit="$repo_root/tests/ci-standards-audit.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$manifest" ]] || fail "missing: $manifest"
[[ -f "$host_audit" ]] || fail "missing: $host_audit"
command -v jq >/dev/null 2>&1 || fail "jq missing"
bash -n "$bin" || fail "canary: bash -n"
bash -n "$tier1" || fail "tier1: bash -n"
ok "scripts compile"

scratch="$(mktemp -d -t research-sweep-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"

export HOME="$scratch/home"
mkdir -p "$HOME"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_RESEARCH_SWEEP_REPO="Nishfleet/fleet-ops"
export FLEET_RESEARCH_SWEEP_FILE=1
# Fixed reference "now" so the 7-day window is deterministic.
export FLEET_RESEARCH_SWEEP_NOW="2026-09-07T12:00:00Z"

# Stub gh to log calls and return canned JSON for issue list / close.
gh_log="$scratch/gh.log"
gh_close_log="$scratch/gh.close.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue close"*)
    printf '%s\n' "$*" >>"${GH_CLOSE_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export GH_CLOSE_LOG="$gh_close_log"
export PATH="$scratch:$PATH"

# Stub fleet-issue-file to log create calls so we can assert title/body.
issue_file_log="$scratch/issue-file.log"
issue_file="$scratch/fleet-issue-file"
cat >"$issue_file" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "ARGS=$*" >>"${ISSUE_FILE_LOG:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/999"
exit 0
FAKE
chmod +x "$issue_file"
export FLEET_ISSUE_FILE="$issue_file"
export ISSUE_FILE_LOG="$issue_file_log"

# state fixture writer: args last_run_at, then a JSON array of deltas.
write_state() {
    local last_run="$1" deltas="$2"
    printf '{"last_run_at":"%s","deltas":%s}\n' "$last_run" "$deltas" >"$scratch/state.json"
    export FLEET_RESEARCH_SWEEP_STATE="$scratch/state.json"
}

# open_issue num marker — GH_OPEN_ISSUES fixture with one issue whose body
# carries the canary marker (or a plain body when marker empty).
open_issue() {
    local num="$1" marker="$2"
    if [[ -n "$marker" ]]; then
        printf '[{"number": %s, "body": "some body\\nfleet-research-sweep-canary:\\n"}]' \
            "$num"
    else
        printf '[{"number": %s, "body": "unrelated"}]' "$num"
    fi
}

run_canary() {
    local rc2
    set +e
    "$bin" 2>&1
    rc2=$?
    set -e
    echo "RC=$rc2"
}

# =========================================================================
# 1. state.json missing -> exit 1 (watcher broken)
# =========================================================================
export FLEET_RESEARCH_SWEEP_STATE="$scratch/nope.json"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "1" ]] || fail "scenario 1: missing state should exit 1, got $rc"
printf '%s\n' "$out" | grep -q 'RESEARCH-SWEEP-WATCHER-BROKEN' \
  || fail "scenario 1: must LOUD WATCHER-BROKEN"
ok "scenario 1: state missing -> exit 1 + LOUD"

# =========================================================================
# 2. state.json unparseable -> exit 1 (watcher broken)
# =========================================================================
printf 'junk\n' >"$scratch/state.json"
export FLEET_RESEARCH_SWEEP_STATE="$scratch/state.json"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "1" ]] || fail "scenario 2: unparseable state should exit 1, got $rc"
printf '%s\n' "$out" | grep -q 'RESEARCH-SWEEP-WATCHER-BROKEN' \
  || fail "scenario 2: must LOUD WATCHER-BROKEN"
ok "scenario 2: unparseable state -> exit 1 + LOUD"

# =========================================================================
# 3. state.json missing last_run_at -> exit 1 (watcher broken)
# =========================================================================
printf '{"deltas":[]}\n' >"$scratch/state.json"
export FLEET_RESEARCH_SWEEP_STATE="$scratch/state.json"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "1" ]] || fail "scenario 3: missing last_run_at should exit 1, got $rc"
printf '%s\n' "$out" | grep -q 'RESEARCH-SWEEP-WATCHER-BROKEN' \
  || fail "scenario 3: must LOUD WATCHER-BROKEN"
ok "scenario 3: missing last_run_at -> exit 1 + LOUD"

# =========================================================================
# 4. Healthy sweep (ran + >= 1 mechanism in window) -> exit 0, no filing,
#    observe-to-close closes any open canary-filed ticket.
# =========================================================================
write_state "2026-09-07T10:00:00Z" \
  '[{"status":"filed","filed_at":"2026-09-06T10:00:00Z","title":"A real mechanism"}]'
printf '[{"number": 42, "body": "some body\\nfleet-research-sweep-canary:\\n"}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
rm -f "$issue_file_log" "$gh_close_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 4: healthy sweep should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'research sweep healthy' \
  || fail "scenario 4: must say healthy: $out"
[[ ! -s "$issue_file_log" ]] || fail "scenario 4: healthy sweep must not file: $(cat "$issue_file_log")"
grep -q 'issue close 42' "$gh_close_log" \
  || fail "scenario 4: healthy sweep must observe-to-close open ticket 42: $(cat "$gh_close_log")"
ok "scenario 4: healthy sweep -> exit 0, no file, observe-to-close"

# =========================================================================
# 5. Ran but produced 0 mechanisms in window -> exit 0, files ticket.
# =========================================================================
write_state "2026-09-07T10:00:00Z" '[]'
printf '[]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 5: ran-but-no-proposal should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'RESEARCH-SWEEP-MISSED' \
  || fail "scenario 5: must LOUD MISSED: $out"
grep -q 'produced 0 mechanism proposals' "$issue_file_log" \
  || fail "scenario 5: must file a produced-0 ticket: $(cat "$issue_file_log")"
grep -q 'fix(research-sweep):' "$issue_file_log" \
  || fail "scenario 5: ticket title must be fix(research-sweep): $(cat "$issue_file_log")"
ok "scenario 5: ran but produced 0 -> exit 0, files fix(research-sweep) ticket"

# =========================================================================
# 6. Did not run in window -> exit 0, files ticket.
# =========================================================================
write_state "2026-08-01T10:00:00Z" '[]'
printf '[]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 6: did-not-run should exit 0, got $rc"
grep -q 'did not run in the last 7d' "$issue_file_log" \
  || fail "scenario 6: must file a did-not-run ticket: $(cat "$issue_file_log")"
ok "scenario 6: did not run -> exit 0, files fix(research-sweep) ticket"

# =========================================================================
# 7. Dedup: second tick with same violation + open ticket -> no second filing.
# =========================================================================
write_state "2026-09-07T10:00:00Z" '[]'
printf '[{"number": 77, "body": "some body\\nfleet-research-sweep-canary:\\n"}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 7: dedup tick should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'dedup' \
  || fail "scenario 7: must say dedup: $out"
[[ ! -s "$issue_file_log" ]] || fail "scenario 7: dedup must not file: $(cat "$issue_file_log")"
ok "scenario 7: dedup -> exit 0, no second filing"

# =========================================================================
# 8. FLEET_RESEARCH_SWEEP_FILE=0 -> exit 0, no filing, LOUD.
# =========================================================================
write_state "2026-09-07T10:00:00Z" '[]'
printf '[]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
export FLEET_RESEARCH_SWEEP_FILE=0
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 8: file=0 should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'file skipped' \
  || fail "scenario 8: must say file skipped: $out"
[[ ! -s "$issue_file_log" ]] || fail "scenario 8: file=0 must not file: $(cat "$issue_file_log")"
export FLEET_RESEARCH_SWEEP_FILE=1
ok "scenario 8: file=0 -> exit 0, no filing"

# =========================================================================
# 9. Heartbeat-tier1 wires block 46 + MANIFEST installs it + host audit.
# =========================================================================
grep -q '46. RESEARCH-SWEEP CANARY' "$tier1" \
  || fail "scenario 9: tier1 must wire block 46"
grep -q 'research_sweep_canary_rc' "$tier1" \
  || fail "scenario 9: tier1 must propagate research_sweep_canary_rc"
grep -q 'bin/fleet-research-sweep-canary /home/nish/.local/bin/fleet-research-sweep-canary' "$manifest" \
  || fail "scenario 9: MANIFEST must install the canary"
grep -q 'fleet-research-sweep-canary.test.sh' "$host_audit" \
  || fail "scenario 9: ci-standards-audit must host this test"
ok "scenario 9: tier1 + MANIFEST + host audit wired"

# =========================================================================
# 10. --help exits 0 without touching state.
# =========================================================================
export FLEET_RESEARCH_SWEEP_STATE="$scratch/nope.json"
out=$("$bin" --help)
rc=$?
[[ "$rc" == "0" ]] || fail "scenario 10: --help should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'usage: fleet-research-sweep-canary' \
  || fail "scenario 10: --help must print usage"
ok "scenario 10: --help -> exit 0, no state touch"

echo "ALL PASS"
