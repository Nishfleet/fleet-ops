#!/usr/bin/env bash
# tests/senior-panel-conference.test.sh
#
# Proves the senior-auditor conference script (fleet-ops #223) in stub mode
# and the fail-closed live path, without convening any real seat.
#
# Covers:
#   - default stub outcome -> APPROVE with 2-of-3 and a lone reject noted
#   - --outcome=reject     -> REJECT with rejector reasons
#   - --outcome=pending    -> PENDING, escalated, fail-closed
#   - --live without a bridge -> PENDING (fail-closed), escalated
#   - comment body is rendered for each result

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/senior-panel-conference.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "conference script not found: $script"
node --check "$script" || fail "conference script failed node --check"
node "$script" --help >/dev/null || fail "conference --help failed"

cd "$repo_root"

packet() {
  printf '%s' '{"repo":"Nishfleet/fleet-ops","prNumber":223,"prTitle":"test","prBody":"body","diff":"diff","changedFiles":["bin/x"],"additions":1,"deletions":0,"closingIssueNumber":223,"closingIssueBody":"issue","ciCheckRuns":[],"triggers":["control-plane-paths"]}'
}

# 1. Default stub (no env, no flags) -> APPROVE, 2-of-3, one dissent noted.
r="$(packet | node "$script")"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "APPROVE" ]] || fail "default stub must be APPROVE"
[[ "$(printf '%s' "$r" | jq -r '.mode')" == "stub" ]] || fail "default mode must be stub"
[[ "$(printf '%s' "$r" | jq -r '.escalated')" == "false" ]] || fail "stub approve must not escalate"
[[ "$(printf '%s' "$r" | jq -r '.tally.approves')" == "2" ]] || fail "stub approve must be 2-of-3"
[[ "$(printf '%s' "$r" | jq -r '.tally.rejects')" == "1" ]] || fail "stub approve must have 1 dissent"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'admitted 2-of-3' || fail "comment must note admitted 2-of-3"
ok "default stub -> APPROVE with 2-of-3 and noted dissent"

# 2. --outcome=reject -> REJECT with rejector reasons.
r="$(packet | node "$script" --outcome=reject)"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "REJECT" ]] || fail "--outcome=reject must be REJECT"
[[ "$(printf '%s' "$r" | jq -r '.tally.rejects')" == "2" ]] || fail "reject outcome must have 2 rejects"
[[ "$(printf '%s' "$r" | jq -r '.escalated')" == "false" ]] || fail "reject must not escalate"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'Reasons to address before re-push' || fail "comment must list reasons before re-push"
printf '%s' "$r" | jq -r '.tally.reasons | length' | grep -q '^2$' || fail "reject must surface 2 rejector reasons"
ok "--outcome=reject -> red with 2 rejector reasons"

# 3. --outcome=pending -> PENDING, escalated, fail-closed.
r="$(packet | node "$script" --outcome=pending)"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "--outcome=pending must be PENDING"
[[ "$(printf '%s' "$r" | jq -r '.escalated')" == "true" ]] || fail "pending outcome must escalate"
[[ "$(printf '%s' "$r" | jq -r '.tally.missing')" == "1" ]] || fail "pending outcome must show 1 missing seat"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'could not convene 2-of-3' || fail "comment must say conference could not convene"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'Fail-closed' || fail "comment must say fail-closed"
ok "--outcome=pending -> PENDING, escalated, fail-closed"

# 4. --live with no bridge configured -> PENDING (fail-closed).
r="$(packet | node "$script" --live)"
[[ "$(printf '%s' "$r" | jq -r '.mode')" == "live" ]] || fail "--live must set mode live"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "live without bridge must fail-closed to PENDING"
[[ "$(printf '%s' "$r" | jq -r '.escalated')" == "true" ]] || fail "live without bridge must escalate"
[[ "$(printf '%s' "$r" | jq -r '.tally.missing')" == "3" ]] || fail "live without bridge must show all 3 seats missing"
ok "--live without bridge -> PENDING, all seats missing, fail-closed"

# 5. SENIOR_PANEL_STUB_OUTCOME env overrides the default approve.
#    Set and export the env in a subshell so both sides of the pipe see it.
r="$(
  SENIOR_PANEL_STUB_OUTCOME=reject
  export SENIOR_PANEL_STUB_OUTCOME
  packet | node "$script"
)"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "REJECT" ]] || fail "env SENIOR_PANEL_STUB_OUTCOME=reject must produce REJECT"
ok "env SENIOR_PANEL_STUB_OUTCOME=reject overrides default approve"

# 6. CLI flag --outcome wins over env.
r="$(
  SENIOR_PANEL_STUB_OUTCOME=reject
  export SENIOR_PANEL_STUB_OUTCOME
  packet | node "$script" --outcome=approve
)"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "APPROVE" ]] || fail "CLI --outcome must override env"
ok "CLI --outcome overrides env SENIOR_PANEL_STUB_OUTCOME"

echo "OK: senior-panel-conference is correct"
