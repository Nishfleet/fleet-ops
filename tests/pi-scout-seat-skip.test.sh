#!/usr/bin/env bash
# tests/pi-scout-seat-skip.test.sh
#
# A saturated seat pool is INFRASTRUCTURE, not a scout outcome.
#
# Observed 2026-09-08 on netcup-rs2000: the #4450 low-water trigger fired 56
# scout starts in 3h while intake bursts held every seat. pi-scout-run exited
# 1 -> systemd marked pi-scout@0509 FAILED -> OnFailure summoned
# pi-scout-repair@0509, which failed identically. A repair hop for a non-fault,
# plus a failed unit on every guardrail sweep (reset-failed by hand 3 runs
# running).
#
# Proven here:
#   1. Shape: pi-scout-run exits the reserved SKIP code (75, EX_TEMPFAIL) on
#      the no-seat path, and both pi-scout@.service and its repair twin mark 75
#      a success so the units stay green and OnFailure / the unit-escalation
#      drop-in never fire (fleet-ops#5071).
#   2. The dry trap: SuccessExitStatus=75 makes SERVICE_RESULT="success", so a
#      naive resolve_exit would read the SKIP as a GREEN run that filed
#      nothing and burn consecutive_dry until SCOUT-FUTILITY parked a healthy
#      scout. A seat SKIP must leave consecutive_dry untouched.
#   3. The masking bug: today a SKIP takes the crash path, fails the
#      provider-wall test, and resets consecutive_wall to 0 — so a genuine
#      provider-wall streak interleaved with one saturation tick never reaches
#      N and never escalates. A seat SKIP must leave consecutive_wall untouched.
#   4+5. Control group: real green-dry runs still increment consecutive_dry,
#      and a real non-wall crash still resets consecutive_wall. The SKIP path
#      must not blanket-neutralize the detector it sits next to.
#
# The live pi-scout@ oneshot is the outermost edge (it would run a real LLM);
# the classification decision is exercised through the real helper.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/scout-futility-check"
scout_run="$repo_root/bin/pi-scout-run"
unit="$repo_root/systemd/pi-scout@.service"
repair_unit="$repo_root/systemd/pi-scout-repair@.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$scout_run" ]] || fail "missing: $scout_run"
bash -n "$bin" || fail "scout-futility-check: bash syntax error"
bash -n "$scout_run" || fail "pi-scout-run: bash syntax error"

# --- 1. shape ---------------------------------------------------------------
grep -q 'SEAT_SKIP_EXIT=75' "$scout_run" \
  || fail "pi-scout-run must define the reserved SKIP code 75"
# The no-seat branch must exit SKIP, never 1 (1 = FAILED unit + repair hop).
noseat="$(awk '/no healthy seat available/,/^fi$/' "$scout_run")"
[[ -n "$noseat" ]] || fail "pi-scout-run: no-seat branch not found"
grep -q 'exit "\$SEAT_SKIP_EXIT"' <<<"$noseat" \
  || fail "pi-scout-run no-seat branch must exit \$SEAT_SKIP_EXIT, not 1"
! grep -qE '^\s*exit 1\s*$' <<<"$noseat" \
  || fail "pi-scout-run no-seat branch must not exit 1 (fails the unit)"
grep -qE '^SuccessExitStatus=75$' "$unit" \
  || fail "pi-scout@.service must mark 75 a success so OnFailure does not fire"
grep -q 'OnFailure=pi-scout-repair@%i.service' "$unit" \
  || fail "pi-scout@.service must keep OnFailure for REAL failures"
# fleet-ops#5071: the repair twin runs the same wrapper through the same
# no-seat SKIP, so it needs the same line — a saturated pool must not record
# the repair unit FAILED and fire the unit-escalation@%n drop-in.
grep -qE '^SuccessExitStatus=75$' "$repair_unit" \
  || fail "pi-scout-repair@.service must mark 75 a success (same SKIP contract as the scout)"
[[ "$(grep -cE '^SuccessExitStatus=' "$repair_unit")" == "1" ]] \
  || fail "pi-scout-repair@.service must carry exactly one SuccessExitStatus (the reserved SKIP code only)"
grep -q 'SEAT_SKIP_EXIT=75' "$bin" \
  || fail "scout-futility-check must share the reserved SKIP code"
ok "shape: no-seat exits 75, unit treats 75 as success, OnFailure kept for real faults"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no "$unit" "$repair_unit" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for pi-scout units"
  ok "systemd-analyze verify accepts pi-scout units with SuccessExitStatus=75"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

# --- scratch environment (mirrors tests/scout-futility.test.sh) -------------
scratch="$(mktemp -d -t scout-seat-skip.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"; mkdir -p "$HOME"
state="$scratch/state"; mkdir -p "$state"
triage="$scratch/triage.md"; : >"$triage"

export SCOUT_FUTILITY_STATE_DIR="$state"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export SCOUT_FUTILITY_N=3
export SCOUT_FUTILITY_BUFFER=12
export SCOUT_FUTILITY_REPO="Nishfleet/fleet-ops"
export SCOUT_FUTILITY_FILE=1
export SCOUT_FUTILITY_READY_COUNT=2
export SCOUT_FUTILITY_PROM="$scratch/fleet-scout.prom"
export WORK_SUPPLY_CLAIMED_COUNT=0

gh_log="$scratch/gh.log"; : >"$gh_log"
open_issues="$scratch/open-issues.json"; echo '[]' >"$open_issues"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue create"*) echo "https://github.com/Nishfleet/fleet-ops/issues/999"; exit 0 ;;
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then cat "${GH_OPEN_ISSUES}"; else echo '[]'; fi
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake" GH_LOG="$gh_log" GH_OPEN_ISSUES="$open_issues"
export PATH="$scratch:$PATH"

state_field() {
  grep -E "^${1}=" "$state/${2:-0509}.state" 2>/dev/null | head -n 1 | cut -d= -f2-
}
seed() { # seed <dry> <wall> — overwrite counters between begin and end
  local f="$state/0509.state"
  [[ -f "$f" ]] || fail "seed: no state file yet"
  sed -i -E "s/^consecutive_dry=.*/consecutive_dry=$1/; s/^consecutive_wall=.*/consecutive_wall=$2/" "$f"
  grep -qE "^consecutive_dry=$1$" "$f" || printf 'consecutive_dry=%s\n' "$1" >>"$f"
  grep -qE "^consecutive_wall=$2$" "$f" || printf 'consecutive_wall=%s\n' "$2" >>"$f"
}

# --- 2. seat SKIP must not burn consecutive_dry -----------------------------
# Production shape: no argv, systemd env. SuccessExitStatus=75 => SERVICE_RESULT
# is "success" while EXIT_STATUS stays 75. One below N, so a wrong increment
# here would immediately park the scout and file a bogus SCOUT-FUTILITY.
: >"$gh_log"; : >"$triage"
"$bin" begin 0509 >/dev/null
seed 2 2
SERVICE_RESULT=success EXIT_STATUS=75 "$bin" end 0509 >/dev/null \
  || fail "scenario2: end must exit 0 on a seat skip"
[[ "$(state_field consecutive_dry)" == "2" ]] \
  || fail "scenario2: seat SKIP must leave consecutive_dry=2, got '$(state_field consecutive_dry)'"
! grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario2: seat SKIP must not escalate (triage=$(cat "$triage"))"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario2: seat SKIP must not file a futility ticket"
ok "scenario2: seat SKIP leaves consecutive_dry untouched and does not escalate"

# --- 3. seat SKIP must not mask a provider-wall streak ----------------------
[[ "$(state_field consecutive_wall)" == "2" ]] \
  || fail "scenario3: seat SKIP must leave consecutive_wall=2, got '$(state_field consecutive_wall)'"
[[ "$(state_field last_exit)" == "75" ]] \
  || fail "scenario3: seat SKIP must record last_exit=75, got '$(state_field last_exit)'"
ok "scenario3: seat SKIP leaves consecutive_wall untouched (no wall-streak masking)"

# --- 4. control: a real green dry run still increments ----------------------
: >"$gh_log"; : >"$triage"
"$bin" begin 0509 >/dev/null
seed 0 0
SERVICE_RESULT=success EXIT_STATUS=0 "$bin" end 0509 >/dev/null \
  || fail "scenario4: end must exit 0"
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario4: a real green dry run must still increment to 1, got '$(state_field consecutive_dry)'"
ok "scenario4: control — green-and-empty detector still increments"

# --- 5. control: a real non-wall crash still resets consecutive_wall --------
"$bin" begin 0509 >/dev/null
seed 1 2
SERVICE_RESULT=exit-code EXIT_STATUS=1 "$bin" end 0509 >/dev/null \
  || fail "scenario5: end must exit 0"
[[ "$(state_field consecutive_wall)" == "0" ]] \
  || fail "scenario5: a real non-wall crash must still reset consecutive_wall, got '$(state_field consecutive_wall)'"
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario5: a crash must leave consecutive_dry=1, got '$(state_field consecutive_dry)'"
ok "scenario5: control — real crash path unchanged"

echo "PASS: pi-scout-seat-skip"
