#!/usr/bin/env bash
# tests/fleet-gh-budget-guard.test.sh
#
# fleet-ops#5489 required items 1 + 4: the shared GitHub App budget guard
# (lib/gh-budget-guard.sh). Proves, entirely offline with scratch state
# files and no gh calls:
#
#   1. gh_budget_read parses the exporter side-car (resources.core shape
#      AND the old flat shape); missing file -> nonzero.
#   2. gh_budget_line prints the issue's `gh_app: remaining=<n>
#      reset_in=<m>` field; unknown budget never fakes a number; a past
#      reset floors at 0.
#   3. gh_budget_loud writes ONE [GH-APP-BUDGET] line to the judges'
#      triage file and dedups within the window.
#   4. gh_budget_reserve_hold (item 4): remaining below the floor ->
#      returns 0 (caller pauses) + pause line + deduped LOUD line; at or
#      above the floor -> returns 1 (proceed); stale side-car -> returns 1
#      fail-open with the stale line; missing side-car -> returns 1
#      fail-open.
#   5. Hermeticity: with HOME stubbed to a scratch dir and no env
#      overrides, the guard's default state path is missing -> reserve
#      fails open (a test run can never trip the live VPS gate).
#
# Hosted by tests/fleet-heartbeat-throughput-split.test.sh so it runs in
# CI without a workflow-file edit (fleet-ops#566).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
guard="$repo_root/lib/gh-budget-guard.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -r "$guard" ]] || fail "missing: $guard"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t ghbudgetguard.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# shellcheck disable=SC1090
source "$guard"

# Point every guard path at the scratch dir BEFORE any call.
export GH_BUDGET_STATE="$scratch/gh-rate-limit.json"
export GH_BUDGET_TRIAGE="$scratch/triage.md"
export GH_BUDGET_LAST_LOUD="$scratch/last-loud"
export GH_BUDGET_LOUD_WINDOW_S="1800"
: >"$GH_BUDGET_TRIAGE"

write_state() { # <remaining> <limit> <reset> <fetched_at>
    cat >"$GH_BUDGET_STATE" <<JSON
{"resources":{"core":{"remaining":$1,"limit":$2,"reset":$3}},"fetched_at":$4}
JSON
}

# --- 1. gh_budget_read ------------------------------------------------------
write_state 700 5000 "$(( $(date +%s) + 1800 ))" "$(date +%s)"
read -r remaining limit reset fetched <<<"$(gh_budget_read)"
[[ "$remaining" == "700" && "$limit" == "5000" ]] || fail "gh_budget_read misparsed resources.core: got $remaining/$limit"
# Old flat shape (no resources wrapper) still parses.
printf '{"remaining":900,"limit":5000,"reset":0,"fetched_at":%s}' "$(date +%s)" >"$GH_BUDGET_STATE"
read -r remaining limit _ <<<"$(gh_budget_read)"
[[ "$remaining" == "900" ]] || fail "gh_budget_read misparsed flat shape: got $remaining"
rm -f "$GH_BUDGET_STATE"
gh_budget_read >/dev/null 2>&1 && fail "gh_budget_read succeeded on a missing file"
ok "scenario1: gh_budget_read parses both side-car shapes; missing file fails"

# --- 2. gh_budget_line ------------------------------------------------------
now=$(date +%s)
line=$(gh_budget_line 700 "$(( now + 90 ))")
case "$line" in
    "gh_app: remaining=700 reset_in="[1-9]*) : ;;
    *) fail "gh_budget_line wrong: $line" ;;
esac
[[ "$line" =~ reset_in=([0-9]+)$ ]] || fail "reset_in not numeric: $line"
(( BASH_REMATCH[1] > 0 && BASH_REMATCH[1] <= 90 )) || fail "reset_in not in (0,90]: $line"
line=$(gh_budget_line 700 "$(( now - 10 ))")
[[ "$line" == "gh_app: remaining=700 reset_in=0" ]] || fail "past reset must floor at 0: $line"
line=$(gh_budget_line)
[[ "$line" == "gh_app: remaining=unknown reset_in=unknown" ]] || fail "unknown must not fake a number: $line"
ok "scenario2: gh_budget_line prints the gh_app field; unknown stays unknown; past reset floors at 0"

# --- 3. gh_budget_loud + dedup ---------------------------------------------
gh_budget_loud "first fault line" >/dev/null
[[ "$(grep -c 'GH-APP-BUDGET' "$GH_BUDGET_TRIAGE")" == "1" ]] || fail "loud line missing from triage"
grep -q "first fault line" "$GH_BUDGET_TRIAGE" || fail "loud line lost its message"
gh_budget_loud "second fault line" >/dev/null
[[ "$(grep -c 'GH-APP-BUDGET' "$GH_BUDGET_TRIAGE")" == "1" ]] || fail "dedup window did not suppress a second line"
GH_BUDGET_LOUD_WINDOW_S=0 gh_budget_loud "third fault line" >/dev/null
[[ "$(grep -c 'GH-APP-BUDGET' "$GH_BUDGET_TRIAGE")" == "2" ]] || fail "zero window must allow a new line"
ok "scenario3: gh_budget_loud writes one deduped [GH-APP-BUDGET] triage line"

# --- 4. gh_budget_reserve_hold ---------------------------------------------
# 4a. Below the floor: return 0 (pause) + pause line + LOUD line.
: >"$GH_BUDGET_TRIAGE"; rm -f "$GH_BUDGET_LAST_LOUD"
write_state 300 5000 "$(( $(date +%s) + 1500 ))" "$(date +%s)"
hold_out="$(gh_budget_reserve_hold 1200 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "0" ]] || fail "below floor must return 0 (pause), got rc=$rc: $hold_out"
grep -q "reserve floor reached" <<<"$hold_out" || fail "pause line missing: $hold_out"
grep -q "remaining=300 < reserve=1200" <<<"$hold_out" || fail "pause line lost the numbers: $hold_out"
grep -q "GH-APP-BUDGET" "$GH_BUDGET_TRIAGE" || fail "reserve hold did not raise the LOUD triage line"
# 4b. At/above the floor: return 1 (proceed), no LOUD.
write_state 4500 5000 "$(( $(date +%s) + 1500 ))" "$(date +%s)"
gh_budget_reserve_hold 1200 >/dev/null 2>&1 && fail "healthy budget must NOT hold (return 1)"
[[ "$(grep -c 'GH-APP-BUDGET' "$GH_BUDGET_TRIAGE")" == "1" ]] || fail "healthy budget must not write a LOUD line"
# 4c. Stale side-car: fail-open (return 1), with the stale line, no hold.
write_state 300 5000 "$(( $(date +%s) + 1500 ))" "$(( $(date +%s) - 900 ))"
stale_out="$(GH_BUDGET_MAX_AGE=420 gh_budget_reserve_hold 1200 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "1" ]] || fail "stale state must fail open (return 1), got rc=$rc"
grep -q "state stale" <<<"$stale_out" || fail "stale line missing: $stale_out"
# 4d. Missing side-car: fail-open (return 1).
rm -f "$GH_BUDGET_STATE"
miss_out="$(gh_budget_reserve_hold 1200 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "1" ]] || fail "missing state must fail open (return 1), got rc=$rc"
ok "scenario4: reserve holds below the floor, proceeds above it, fails open on stale/missing"

# --- 5. Hermeticity: scratch HOME, no overrides -----------------------------
env_home="$scratch/fakehome"
mkdir -p "$env_home"
hermetic_out="$(HOME="$env_home" bash -c '
    source "'"$guard"'"
    gh_budget_reserve_hold 1200
' 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "1" ]] || fail "scratch HOME must fail open (return 1), got rc=$rc: $hermetic_out"
grep -q "state unreadable" <<<"$hermetic_out" || fail "hermetic fail-open line missing: $hermetic_out"
ok "scenario5: scratch HOME sees no side-car and fails open — test runs never trip the live gate"

echo "ALL TESTS PASSED (tests/fleet-gh-budget-guard.test.sh)"
