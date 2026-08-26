#!/usr/bin/env bash
# tests/senior-panel-tally.test.sh
#
# Proves the senior-auditor conference tally (fleet-ops #223) without
# convening any seat. Pure verdicts-in / result-out covering the issue's
# stubbed acceptance:
#   - 2-of-3 APPROVE -> green (a lone REJECT is noted, non-blocking)
#   - 2-of-3 REJECT  -> red with reasons
#   - < 3 verdicts   -> PENDING (fail-closed, never auto-green)
#   - unanimous approve / unanimous reject
#   - malformed verdict counts as a missing seat (fail-closed)

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/senior-panel-tally.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "tally script not found: $script"
node --check "$script" || fail "tally script failed node --check"
node "$script" --help >/dev/null || fail "tally --help failed"

cd "$repo_root"

run() { printf '%s' "$1" | node "$script"; }

# 2-of-3 APPROVE -> APPROVE (lone REJECT noted, non-blocking).
r="$(run '[{"seat":"glm-5.2-devin","verdict":"APPROVE","reason":"ok"},{"seat":"glm-5.3-free","verdict":"APPROVE","reason":"ok"},{"seat":"ds4-pro-straitly","verdict":"REJECT","reason":"no test"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "APPROVE" ]] || fail "2-of-3 approve must be APPROVE"
[[ "$(printf '%s' "$r" | jq -r '.approves')" == "2" ]] || fail "approves count"
[[ "$(printf '%s' "$r" | jq -r '.missing')" == "0" ]] || fail "no missing on full panel"
printf '%s' "$r" | jq -e '.note | test("non-blocking")' >/dev/null || fail "lone reject must be noted non-blocking"
ok "2-of-3 APPROVE -> green, dissent non-blocking"

# Unanimous APPROVE.
r="$(run '[{"seat":"a","verdict":"APPROVE","reason":"x"},{"seat":"b","verdict":"APPROVE","reason":"y"},{"seat":"c","verdict":"APPROVE","reason":"z"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "APPROVE" ]] || fail "unanimous approve"
printf '%s' "$r" | jq -e '.note | test("unanimous")' >/dev/null || fail "unanimous note"
ok "unanimous APPROVE -> green"

# 2-of-3 REJECT -> REJECT with reasons.
r="$(run '[{"seat":"a","verdict":"REJECT","reason":"r1"},{"seat":"b","verdict":"REJECT","reason":"r2"},{"seat":"c","verdict":"APPROVE","reason":"ok"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "REJECT" ]] || fail "2-of-3 reject must be REJECT"
[[ "$(printf '%s' "$r" | jq -r '.rejects')" == "2" ]] || fail "rejects count"
# REJECT surfaces only the rejectors' reasons (for the loop-to-green worker).
[[ "$(printf '%s' "$r" | jq -r '.reasons | length')" == "2" ]] || fail "REJECT must surface rejector reasons"
printf '%s' "$r" | jq -e '.reasons | any(test("r1"))' >/dev/null || fail "reason r1 missing"
printf '%s' "$r" | jq -e '.reasons | any(test("r2"))' >/dev/null || fail "reason r2 missing"
ok "2-of-3 REJECT -> red with rejector reasons"

# Unanimous REJECT.
r="$(run '[{"seat":"a","verdict":"REJECT","reason":"x"},{"seat":"b","verdict":"REJECT","reason":"y"},{"seat":"c","verdict":"REJECT","reason":"z"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "REJECT" ]] || fail "unanimous reject"
ok "unanimous REJECT -> red"

# < 3 verdicts -> PENDING (fail-closed). A 1-1 split with a missing seat is
# PENDING, NOT APPROVE — the conference did not convene 2-of-3 either way.
r="$(run '[{"seat":"a","verdict":"APPROVE","reason":"ok"},{"seat":"b","verdict":"REJECT","reason":"r"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "partial panel must be PENDING, not APPROVE"
[[ "$(printf '%s' "$r" | jq -r '.missing')" == "1" ]] || fail "missing count"
printf '%s' "$r" | jq -e '.note | test("fail-closed")' >/dev/null || fail "PENDING must say fail-closed"
ok "partial panel (1-1 + missing) -> PENDING, fail-closed"

# 2 APPROVE + 1 missing -> still PENDING (need 3 verdicts to admit 2-of-3).
r="$(run '[{"seat":"a","verdict":"APPROVE","reason":"ok"},{"seat":"b","verdict":"APPROVE","reason":"ok"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "2 approve + missing must be PENDING, never auto-green"
ok "2 APPROVE + missing seat -> PENDING (never auto-green)"

# Empty panel -> PENDING.
r="$(run '[]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "empty panel must be PENDING"
[[ "$(printf '%s' "$r" | jq -r '.missing')" == "3" ]] || fail "all missing"
ok "empty panel -> PENDING"

# Malformed verdict counts as a missing seat (fail-closed).
r="$(run '[{"seat":"a","verdict":"APPROVE","reason":"ok"},{"seat":"","verdict":"APPROVE","reason":"ok"},{"seat":"c","verdict":"MAYBE","reason":"x"}]')"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "PENDING" ]] || fail "malformed verdicts must fail-closed to PENDING"
[[ "$(printf '%s' "$r" | jq -r '.missing')" == "2" ]] || fail "two malformed -> two missing"
ok "malformed verdicts -> PENDING (fail-closed)"

echo "OK: senior-panel tally is correct"
