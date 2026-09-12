#!/usr/bin/env bash
# tests/fleet-red-main-suspicion.test.sh
#
# fleet-ops#4845: the red-main guardrail must group open PRs by FAIL CAUSE,
# not by check name alone. The old detector counted PRs whose `P14 tests /
# PR checks` check had conclusion=FAILURE and cried `red-main-suspicion` at
# >=3 — so a busy queue where 4 PRs fail the same-named check for DIFFERENT
# reasons (a shellcheck on the file that PR edits, an unwired test file, a
# scenario regression) read as "main is red" when main was green. Crying
# wolf is the failure mode: a judge hunts a main-red fix that does not exist,
# and a detector that fires on every busy queue is one a judge learns to
# ignore — so a GENUINE red main arrives pre-discredited.
#
# This test proves the two mechanical fixes:
#   1. FALSE-POSITIVE DRILL: 4 PRs failing the same-named check for 3
#      distinct normalised causes emit `pr-checks-red: 4 PRs, 3 distinct
#      causes` and NOT `red-main-suspicion`.
#   2. POSITIVE CONTROL: 3 branches sharing ONE normalised FAIL line (a
#      shellcheck on three different files) still emit `red-main-suspicion`
#      — the detector is not weakened, only made cause-aware.
#   3. Normalisation: absolute paths and PR-specific file names are stripped
#      so two PRs failing the same check for the same reason collapse to one
#      cause, while different reasons stay distinct.
#
# Offline: FLEET_RED_MAIN_INPUT supplies the failing-PR set, so no live gh
# is touched. The live host is never mutated.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-red-main-suspicion"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "fleet-red-main-suspicion failed bash -n"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# run INPUT — run the detector with the given failing-PR JSON array.
run() {
    FLEET_RED_MAIN_INPUT="$1" bash "$bin" 2>/dev/null
}

# --- 1. FALSE-POSITIVE DRILL: 4 PRs, 3 distinct causes ---------------------
# The issue's exact scenario: #4828 shellcheck on the file it edits, #4830
# and #4792 both an unwired test file, #4422 a scenario regression. After
# normalisation these are 3 distinct causes, so the line must be the
# throughput line, never the guardrail.
drill='[
 {"number":4828,"check":"P14 tests / PR checks","fail_line":"FAIL: shellcheck not clean on lib/pi-intake-tick.sh"},
 {"number":4830,"check":"P14 tests / PR checks","fail_line":"FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test, live/destructive, nor a known orphan:"},
 {"number":4792,"check":"P14 tests / PR checks","fail_line":"FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test, live/destructive, nor a known orphan:"},
 {"number":4422,"check":"P14 tests / PR checks","fail_line":"FAIL: scenario1: must exit 0, got 1 ([2026-09-08T04:04:58Z] [fleet-escalation-canary] escalation coverage canary starting (repo=/tmp/esc-canary.IutDHE/repo)"}
]'
out="$(run "$drill")" || fail "false-positive drill: detector exited non-zero: $out"
grep -q '^pr-checks-red: 4 PRs, 3 distinct causes$' <<<"$out" \
    || fail "false-positive drill: expected 'pr-checks-red: 4 PRs, 3 distinct causes', got: $out"
grep -q '^red-main-suspicion:' <<<"$out" \
    && fail "false-positive drill: must NOT emit red-main-suspicion, got: $out"
ok "false-positive drill: 4 PRs, 3 distinct causes -> pr-checks-red, not red-main-suspicion"

# --- 2. POSITIVE CONTROL: 3 branches, 1 normalised cause -------------------
# Three PRs each with a shellcheck failure on a DIFFERENT file. Normalisation
# strips the PR-specific file name, so all three collapse to the same cause
# and the detector must still cry wolf (it is not weakened, only made
# cause-aware).
control='[
 {"number":4828,"check":"P14 tests / PR checks","fail_line":"FAIL: shellcheck not clean on lib/pi-intake-tick.sh"},
 {"number":4831,"check":"P14 tests / PR checks","fail_line":"FAIL: shellcheck not clean on lib/litellm-seat.sh"},
 {"number":4832,"check":"P14 tests / PR checks","fail_line":"FAIL: shellcheck not clean on bin/fleet-claim"}
]'
out="$(run "$control")" || true
grep -q '^red-main-suspicion: 3 branches share FAIL: shellcheck not clean on$' <<<"$out" \
    || fail "positive control: expected 'red-main-suspicion: 3 branches share FAIL: shellcheck not clean on', got: $out"
ok "positive control: 3 branches, 1 normalised cause -> red-main-suspicion still fires"

# --- 3. Normalisation strips absolute paths and PR-specific file names -----
# Two PRs failing the same check for the same reason (an unwired test file)
# must collapse to one cause even though the surrounding text differs in
# path-bearing detail; a genuinely different reason stays distinct.
norm='[
 {"number":4830,"check":"P14 tests / PR checks","fail_line":"FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test, live/destructive, nor a known orphan:"},
 {"number":4792,"check":"P14 tests / PR checks","fail_line":"FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test, live/destructive, nor a known orphan:"},
 {"number":4422,"check":"P14 tests / PR checks","fail_line":"FAIL: scenario1: must exit 0, got 1 ([2026-09-08T04:04:58Z] [fleet-escalation-canary] escalation coverage canary starting (repo=/tmp/esc-canary.IutDHE/repo)"}
]'
out="$(run "$norm")" || fail "normalisation: detector exited non-zero: $out"
grep -q '^pr-checks-red: 3 PRs, 2 distinct causes$' <<<"$out" \
    || fail "normalisation: expected 'pr-checks-red: 3 PRs, 2 distinct causes', got: $out"
ok "normalisation: same-reason PRs collapse, different reasons stay distinct"

# --- 4. Empty set: no failing PRs -> clean throughput line ------------------
out="$(run '[]')" || fail "empty set: detector exited non-zero: $out"
grep -q '^pr-checks-red: 0 PRs, 0 distinct causes$' <<<"$out" \
    || fail "empty set: expected 'pr-checks-red: 0 PRs, 0 distinct causes', got: $out"
ok "empty set: no failing PRs -> pr-checks-red: 0 PRs, 0 distinct causes"

echo "ALL PASS"
