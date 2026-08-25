#!/usr/bin/env bash
# tests/fleet-heartbeat-undersaturation.test.sh
#
# Proves the undersaturation alarm (fleet-ops#75) does what the issue's
# acceptance criteria demand, entirely offline with mocked systemctl + gh:
#
#   1. work>0 / running=0  (first wedged tick)  -> repair actions attempted
#      (reset-failed on failed pi-issue units, stale active-seats reaped,
#      intake restarted) AND a one-tick marker is set; exit 0.
#   2. work>0 / running=0  (second consecutive) -> FAIL LOUD (exit non-zero),
#      marker cleared. Never degrades silently.
#   3. work>0 / running>0                     -> NO repair action; exit 0.
#
# Also proves the per-tick THROUGHPUT line is emitted to the triage file in
# every scenario (it is unconditional, best-effort).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-undersaturation"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t undersat.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# intake-repos.json: one enrolled repo ("demo").
intake_json="$scratch/intake-repos.json"
cat >"$intake_json" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON

log_dir="$scratch/log"
triage="$scratch/triage.md"
seat_state="$scratch/pi-packet"
mkdir -p "$log_dir" "$seat_state/active-seats"

# Shared call log: every mutating systemctl call appends here so the test can
# assert repair actions were (or were not) attempted.
calls="$scratch/calls.log"
: >"$calls"

# --- fake gh ----------------------------------------------------------------
# Controlled by $WORK_READY / $WORK_INPROGRESS files (numbers). pr list always
# returns [] so throughput = 0 (we assert the line is emitted, not the count).
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
# Drop everything up to and including the subcommand token we care about.
# We pattern-match on argv so flag order does not matter.
case "$*" in
  *"issue list"*)
    if [[ "$*" == *"-l agent-ready"* ]]; then
      n=$(cat "${WORK_READY:-/dev/null}" 2>/dev/null || echo 0)
    elif [[ "$*" == *"-l agent-in-progress"* ]]; then
      n=$(cat "${WORK_INPROGRESS:-/dev/null}" 2>/dev/null || echo 0)
    else
      n=0
    fi
    # gh --jq 'length' over --json number: emit the count directly.
    printf '%s\n' "$n"
    exit 0
    ;;
  *"pr list"*)
    printf '[]\n'
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake systemctl ---------------------------------------------------------
# Behavior is driven by scratch state files:
#   $RUNNING_UNITS   one unit per line (active/activating pi-issue@ units)
#   $FAILED_UNITS    one unit per line (failed pi-issue@ units, for reset-failed)
#   $LIVE_SEAT_UNITS a set of unit names (.service) considered live for the
#                    active-seats is-active probe; anything else -> inactive.
#   $WEDGED_UNITS    unit names considered `activating` but stuck past the
#                    P15 wedge-age bound (is-active -> activating, show -> old).
#   $FRESH_ACTIVATING_UNITS  unit names `activating` but young (live).
# Mutating calls (reset-failed, start) append to $CALLS.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift
case "$cmd" in
  list-units)
    # Emit the running units list as no-legend plain output (first token is
    # the unit name; the rest of the line is ignored by awk '{print $1}').
    if [[ -f "${RUNNING_UNITS:-/dev/nonexistent}" ]]; then
      while IFS= read -r u; do
        [[ -n "$u" ]] && printf '%s loaded active running -\n' "$u"
      done < "${RUNNING_UNITS:-/dev/nonexistent}"
    fi
    exit 0
    ;;
  --state=failed)
    # `systemctl --user --state=failed --no-legend` — we shifted --user, so
    # $cmd is "--state=failed". Emit failed units.
    if [[ -f "${FAILED_UNITS:-/dev/nonexistent}" ]]; then
      cat "${FAILED_UNITS:-/dev/nonexistent}"
    fi
    exit 0
    ;;
  reset-failed)
    unit="$1"
    printf 'reset-failed %s\n' "$unit" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  start)
    unit="$1"
    printf 'start %s\n' "$unit" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  is-active)
    unit="$1"
    printf 'is-active %s\n' "$unit" >>"${CALLS:-/dev/null}"
    if [[ -f "${LIVE_SEAT_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${LIVE_SEAT_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo active
    elif [[ -f "${WEDGED_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${WEDGED_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo activating
    elif [[ -f "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo activating
    else
      echo inactive
    fi
    exit 0
    ;;
  show)
    # ActiveEnterTimestampMonotonic (us). Wedged units are old (>55min),
    # fresh-activating are young. Real systemd prints the value only with
    # --value; the probe also passes --property and --value.
    unit="$1"
    now_us=$(awk '{print int($1*1000000)}' /proc/uptime)
    if [[ -f "${WEDGED_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${WEDGED_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo "$(( now_us - 3600000000 ))"
    elif [[ -f "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo "$(( now_us - 60000000 ))"
    else
      echo 0
    fi
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# Common env for every invocation. Exports so the fake binaries (which run
# in child processes) inherit the state-file pointers.
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export PI_PACKET_STATE="$seat_state"
export CALLS="$calls"
export WORK_READY="$scratch/work_ready"
export WORK_INPROGRESS="$scratch/work_inprogress"
# Pointers the fake systemctl reads to decide what to return per scenario.
RUNNING_UNITS="$scratch/running_units"
FAILED_UNITS="$scratch/failed_units"
LIVE_SEAT_UNITS="$scratch/live_seat_units"
WEDGED_UNITS="$scratch/wedged_units"
FRESH_ACTIVATING_UNITS="$scratch/fresh_activating_units"
export RUNNING_UNITS FAILED_UNITS LIVE_SEAT_UNITS WEDGED_UNITS FRESH_ACTIVATING_UNITS
: >"$RUNNING_UNITS"; : >"$FAILED_UNITS"; : >"$LIVE_SEAT_UNITS"; : >"$WEDGED_UNITS"; : >"$FRESH_ACTIVATING_UNITS"

run_helper() {
  set +e
  env_out=$(SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  rm -f "$log_dir"/* "$triage" "$calls" "$seat_state"/active-seats/*
  : >"$calls"
  : >"$RUNNING_UNITS"; : >"$FAILED_UNITS"; : >"$LIVE_SEAT_UNITS"
  : >"$WEDGED_UNITS"; : >"$FRESH_ACTIVATING_UNITS"
}

# ============================================================================
# Scenario 1: work>0 / running=0, FIRST wedged tick -> repair + marker, exit 0
# ============================================================================
reset_state
printf '3\n' >"$scratch/work_ready"        # 3 agent-ready issues
printf '2\n' >"$scratch/work_inprogress"   # 2 agent-in-progress issues
: >"$scratch/running_units"                # zero running pi-issue workers
printf 'pi-issue@demo-9.service\npi-issue@demo-10.service\n' >"$scratch/failed_units"
# Two stale active-seat registry files whose units are NOT live (running=0).
printf '{"unit":"pi-issue-demo-9","provider":"devin","model":"glm-5-2"}' \
    >"$seat_state/active-seats/pi-issue-demo-9.json"
printf '{"unit":"pi-issue-demo-10","provider":"minimax","model":"MiniMax-M3"}' \
    >"$seat_state/active-seats/pi-issue-demo-10.json"
: >"$scratch/live_seat_units"              # no live seats -> both reaped

run_helper
[[ "$env_rc" == 0 ]] || fail "scenario1: first wedged tick must exit 0, got $env_rc ($env_out)"

# Repair actions attempted: reset-failed on both failed pi-issue units.
grep -qx 'reset-failed pi-issue@demo-9.service' "$calls" \
    || fail "scenario1: reset-failed pi-issue@demo-9.service not attempted ($(cat "$calls"))"
grep -qx 'reset-failed pi-issue@demo-10.service' "$calls" \
    || fail "scenario1: reset-failed pi-issue@demo-10.service not attempted"
# Stale active-seats reaped (both files gone).
[[ ! -f "$seat_state/active-seats/pi-issue-demo-9.json" ]] \
    || fail "scenario1: stale active-seat pi-issue-demo-9.json not reaped"
[[ ! -f "$seat_state/active-seats/pi-issue-demo-10.json" ]] \
    || fail "scenario1: stale active-seat pi-issue-demo-10.json not reaped"
# Intake restarted for the enrolled repo.
grep -qx 'start pi-intake@demo.service' "$calls" \
    || fail "scenario1: intake restart for demo not attempted ($(cat "$calls"))"
# Marker set for the next tick.
[[ -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario1: undersaturation.flag not set after repair"
# Repair + throughput loud lines in triage.
grep -q 'UNDERSAT-REPAIR' "$triage" || fail "scenario1: triage missing UNDERSAT-REPAIR"
grep -q 'THROUGHPUT' "$triage" || fail "scenario1: triage missing THROUGHPUT line"
ok "scenario1: work>0/running=0 first tick -> repair attempted, marker set, exit 0"

# ============================================================================
# Scenario 2: work>0 / running=0, SECOND consecutive -> FAIL LOUD, marker cleared
# ============================================================================
# Reuse scenario1 state EXCEPT we pre-seed the flag so this looks like the
# next tick after a repair that recovered nothing. Keep work>0, running=0.
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$log_dir/undersaturation.flag"
: >"$calls"   # fresh call log — a fail-loud tick must NOT re-attempt repair

run_helper
[[ "$env_rc" != 0 ]] \
    || fail "scenario2: second consecutive wedged tick must exit non-zero, got 0 ($env_out)"
[[ "$env_rc" == 1 ]] || fail "scenario2: expected exit 1, got $env_rc ($env_out)"

# Fail loud must NOT re-attempt repair (that already ran last tick).
if grep -qE '^(reset-failed|start) ' "$calls"; then
    fail "scenario2: fail-loud tick must not re-attempt repair, but calls=($(cat "$calls"))"
fi
# Marker cleared so the post-failure tick can attempt repair again.
[[ ! -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario2: undersaturation.flag must be cleared after fail-loud"
# Throughput still emitted (unconditional), and the fail-loud line is present.
grep -q 'UNDERSAT-FAIL-LOUD' "$triage" || fail "scenario2: triage missing UNDERSAT-FAIL-LOUD"
grep -q 'THROUGHPUT' "$triage" || fail "scenario2: triage missing THROUGHPUT line on fail-loud tick"
ok "scenario2: second consecutive wedged tick -> fail loud (exit 1), no re-repair, marker cleared"

# ============================================================================
# Scenario 3: work>0 / running>0 -> NO repair, exit 0, marker cleared
# ============================================================================
reset_state
printf '5\n' >"$scratch/work_ready"
printf '1\n' >"$scratch/work_inprogress"
printf 'pi-issue@demo-9.service\n' >"$scratch/running_units"   # one live worker
: >"$scratch/failed_units"
# A live active-seat that must NOT be reaped (its unit is running).
printf '{"unit":"pi-issue-demo-9","provider":"devin","model":"glm-5-2"}' \
    >"$seat_state/active-seats/pi-issue-demo-9.json"
printf 'pi-issue@demo-9.service\n' >"$scratch/live_seat_units"
# Pre-seed a stale flag from a prior wedged tick — healthy now must clear it.
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$log_dir/undersaturation.flag"

run_helper
[[ "$env_rc" == 0 ]] || fail "scenario3: healthy tick must exit 0, got $env_rc ($env_out)"

# No repair actions.
if grep -qE '^(reset-failed|start) ' "$calls"; then
    fail "scenario3: healthy tick must not repair, but calls=($(cat "$calls"))"
fi
# Live active-seat must be preserved (not reaped — running>0).
[[ -f "$seat_state/active-seats/pi-issue-demo-9.json" ]] \
    || fail "scenario3: live active-seat was wrongly reaped on a healthy tick"
# Stale marker cleared.
[[ ! -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario3: stale flag must be cleared on healthy tick"
# No UNDERSAT-REPAIR / UNDERSAT-FAIL-LOUD lines; throughput still present.
! grep -q 'UNDERSAT-REPAIR' "$triage" || fail "scenario3: triage must not have UNDERSAT-REPAIR"
! grep -q 'UNDERSAT-FAIL-LOUD' "$triage" || fail "scenario3: triage must not have UNDERSAT-FAIL-LOUD"
grep -q 'THROUGHPUT' "$triage" || fail "scenario3: triage missing THROUGHPUT line on healthy tick"
ok "scenario3: work>0/running>0 -> no repair, live seat kept, marker cleared, exit 0"

ok "undersaturation: repair on first wedge, fail-loud on second, no-op when healthy"

# ============================================================================
# Scenario 4 (P15): in the REPAIR path (running=0), a unit stuck in
# `activating` past the wedge-age bound is reaped; a fresh-activating unit
# stays live. This mirrors seat-lib's probe; the inlined copy here is the
# heartbeat's repair path and must agree.
# ============================================================================
reset_state
printf '5\n' >"$scratch/work_ready"
printf '0\n' >"$scratch/work_inprogress"
: >"$scratch/running_units"   # running=0 -> repair path fires
: >"$scratch/failed_units"
# One wedged (3600s into activating) and one fresh (60s) registry entry.
printf '{"unit":"pi-issue-demo-9","provider":"devin","model":"glm-5-2"}' \
    >"$seat_state/active-seats/pi-issue-demo-9.json"
printf '{"unit":"pi-issue-demo-10","provider":"devin","model":"glm-5-2"}' \
    >"$seat_state/active-seats/pi-issue-demo-10.json"
printf 'pi-issue@demo-9.service\n' >"$scratch/wedged_units"
printf 'pi-issue@demo-10.service\n' >"$scratch/fresh_activating_units"

run_helper
[[ "$env_rc" == 0 ]] || fail "scenario4: wedged-tick must exit 0, got $env_rc ($env_out)"

# DEBUG (P15 CI repro): surface the real state so a CI-only failure is diagnosable.
{
    echo "--- s4 debug: env_out ---"
    printf '%s\n' "$env_out"
    echo "--- s4 debug: active-seats after ---"
    ls -la "$seat_state/active-seats/" 2>&1 || true
    echo "--- s4 debug: wedged_units ---"; cat "$scratch/wedged_units" 2>&1 || true
    echo "--- s4 debug: fresh_activating_units ---"; cat "$scratch/fresh_activating_units" 2>&1 || true
    echo "--- s4 debug: live_seat_units ---"; cat "$scratch/live_seat_units" 2>&1 || true
    echo "--- s4 debug: calls.log ---"; cat "$calls" 2>&1 || true
} >&2

# The wedged phantom must be reaped; the fresh live one kept.
[[ ! -f "$seat_state/active-seats/pi-issue-demo-9.json" ]] \
    || fail "scenario4: wedged-activating phantom was not reaped"
[[ -f "$seat_state/active-seats/pi-issue-demo-10.json" ]] \
    || fail "scenario4: fresh-activating live seat was wrongly reaped"
grep -q 'wedged active-seat' <<<"$env_out" \
    || fail "scenario4: stderr missing wedged-reap log line: $env_out"
ok "scenario4: wedged-activating phantom reaped, fresh-activating kept (P15)"
