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
      if [[ "$*" == *".[].number"* ]]; then
        [[ -f "${WORK_READY_NUMBERS:-/dev/null}" ]] && cat "${WORK_READY_NUMBERS}"
        exit 0
      fi
      # Prefer the mutable numbers file (label edits update it) so a recompute
      # after a flip reflects the new ready count; fall back to the static
      # count file for the count-only scenarios that never mutate labels.
      if [[ -s "${WORK_READY_NUMBERS:-/dev/null}" ]]; then
        wc -l < "${WORK_READY_NUMBERS}" | tr -d ' '
      else
        cat "${WORK_READY:-/dev/null}" 2>/dev/null || echo 0
      fi
      exit 0
    elif [[ "$*" == *"-l agent-in-progress"* ]]; then
      # count_work asks for length; the stale-label reap asks for the actual
      # numbers via --jq '.[].number'. Distinguish on the jq filter so both
      # the existing count scenarios and the new reap scenarios stay honest.
      if [[ "$*" == *".[].number"* ]]; then
        [[ -f "${WORK_INPROGRESS_NUMBERS:-/dev/null}" ]] \
          && cat "${WORK_INPROGRESS_NUMBERS}"
        exit 0
      fi
      if [[ -s "${WORK_INPROGRESS_NUMBERS:-/dev/null}" ]]; then
        wc -l < "${WORK_INPROGRESS_NUMBERS}" | tr -d ' '
      else
        cat "${WORK_INPROGRESS:-/dev/null}" 2>/dev/null || echo 0
      fi
      exit 0
    else
      printf '0\n'
      exit 0
    fi
    ;;
  *"issue edit"*)
    # $1=issue $2=edit $3=<N>. Record the mutation AND mirror it into the
    # numbers files so a recompute (count_work) sees the label change — the
    # real gh would return the updated list on the next call.
    num="$3"
    printf 'issue edit %s\n' "$*" >>"${CALLS:-/dev/null}"
    if [[ "$*" == *"--remove-label agent-in-progress"* ]] \
       && [[ -f "${WORK_INPROGRESS_NUMBERS:-/dev/null}" ]]; then
      grep -vxF "$num" "${WORK_INPROGRESS_NUMBERS}" >"${WORK_INPROGRESS_NUMBERS}.tmp" 2>/dev/null || true
      mv "${WORK_INPROGRESS_NUMBERS}.tmp" "${WORK_INPROGRESS_NUMBERS}"
    fi
    if [[ "$*" == *"--add-label agent-ready"* ]] \
       && [[ -n "${WORK_READY_NUMBERS:-}" ]]; then
      printf '%s\n' "$num" >>"${WORK_READY_NUMBERS}"
    fi
    exit 0
    ;;
  *"issue comment"*)
    printf 'issue comment %s\n' "$*" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  *"pr list"*)
    # The reap's PR-existence probe: --head claim/issue-<N>. Return a
    # non-empty array iff <N> is in $OPEN_PR_ISSUES (one per line). The
    # throughput call has no --head claim/issue- and falls through to [].
    if [[ "$*" == *"--head claim/issue-"* ]]; then
      nn=$(printf '%s' "$*" | sed -n 's/.*--head claim\/issue-\([0-9][0-9]*\).*/\1/p')
      if [[ -f "${OPEN_PR_ISSUES:-/dev/null}" ]] \
         && grep -qxF "$nn" "${OPEN_PR_ISSUES}" 2>/dev/null; then
        printf '[{"number":1}]\n'
      else
        printf '[]\n'
      fi
      exit 0
    fi
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
    # Parse: systemctl show UNIT [--property=PROP] [--value].
    # fleet-ops#1155: the worker counter now inspects ExecStart for live
    # worker literals: "pi --print", "pi-issue-run", "pi-packet-run".
    prop="ActiveEnterTimestampMonotonic"
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p|--property) prop="$2"; shift 2 ;;
        --property=*) prop="${1#--property=}"; shift ;;
        --value) shift ;;
        *.service) unit="$1"; shift ;;
        *) shift ;;
      esac
    done
    case "$prop" in
      ExecStart)
        if [[ -f "${RUNNING_EXEC:-/dev/nonexistent}" ]]; then
          grep -F "${unit}|" "${RUNNING_EXEC:-/dev/nonexistent}" 2>/dev/null | head -n1 | cut -d'|' -f2-
        else
          # Default: any unit declared as live for this tick is a pi worker.
          if grep -qxF "$unit" "${RUNNING_UNITS:-/dev/nonexistent}" 2>/dev/null \
             || grep -qxF "$unit" "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" 2>/dev/null \
             || grep -qxF "$unit" "${WEDGED_UNITS:-/dev/nonexistent}" 2>/dev/null; then
            inst=""
            case "$unit" in
              pi-issue@*) inst="${unit#pi-issue@}"; inst="${inst%.service}"; printf '/home/nish/.local/bin/pi-issue-run %s\n' "$inst" ;;
              pi-packet@*) inst="${unit#pi-packet@}"; inst="${inst%.service}"; printf '/home/nish/.local/bin/pi-packet-run %s\n' "$inst" ;;
              *) printf '/home/nish/.local/bin/pi --print --provider devin --model swe-1-7\n' ;;
            esac
          fi
        fi
        ;;
      ActiveEnterTimestampMonotonic|*)
        now_s=$(awk '{print int($1)}' /proc/uptime)
        if (( now_s < 3700 )); then now_s=3700; fi
        if [[ -f "${WEDGED_UNITS:-/dev/nonexistent}" ]] \
           && grep -qxF "$unit" "${WEDGED_UNITS:-/dev/nonexistent}" 2>/dev/null; then
          echo "$(( (now_s - 3600) * 1000000 ))"
        elif [[ -f "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" ]] \
           && grep -qxF "$unit" "${FRESH_ACTIVATING_UNITS:-/dev/nonexistent}" 2>/dev/null; then
          echo "$(( (now_s - 60) * 1000000 ))"
        else
          echo 0
        fi
        ;;
    esac
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# The probe (inside the bin) and the mock's `show` case both read the clock
# via `awk '{print int($1)}' /proc/uptime`. On a fresh GitHub runner (uptime
# < 1h) a 3600s-old monotonic timestamp is not representable (negative),
# and the probe's ^[0-9]+$ guard would keep the wedged phantom. Floor the
# simulated uptime at 3700s so the probe's clock and the mock agree on any
# runner: wedged age = 3600s > 3300s max -> reaped, fresh age = 60s -> live.
# Exported so the bin subprocess (and its children) see it.
awk() {
  if [[ "$*" == *'/proc/uptime'* ]] && [[ "$*" == *'print int($1)'* ]]; then
    local real_s
    real_s=$(command awk '{print int($1)}' /proc/uptime)
    if (( real_s < 3700 )); then real_s=3700; fi
    echo "$real_s"
  else
    command awk "$@"
  fi
}
export -f awk

# Common env for every invocation. Exports so the fake binaries (which run
# in child processes) inherit the state-file pointers.
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export PI_PACKET_STATE="$seat_state"
export CALLS="$calls"
export WORK_READY="$scratch/work_ready"
export WORK_INPROGRESS="$scratch/work_inprogress"
# fleet-ops#1558: pin the admit floor so scenarios do not read live
# MemAvailable / seat-lib. Override per-scenario when testing the floor.
export FLEET_UNDERSAT_ADMIT_CEILING=25
# Stale-label reap scenarios: the actual issue numbers labelled agent-in-progress
# (one per line), and the subset of those that have an open claim/issue-<N> PR.
# WORK_READY_NUMBERS mirrors the ready set so a flip (agent-in-progress ->
# agent-ready) is reflected on recompute. The static WORK_READY / WORK_INPROGRESS
# count files remain for the count-only scenarios that never mutate labels.
export WORK_INPROGRESS_NUMBERS="$scratch/work_inprogress_numbers"
export WORK_READY_NUMBERS="$scratch/work_ready_numbers"
export OPEN_PR_ISSUES="$scratch/open_pr_issues"
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
  : >"$WORK_INPROGRESS_NUMBERS"; : >"$WORK_READY_NUMBERS"; : >"$OPEN_PR_ISSUES"
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

# The wedged phantom must be reaped; the fresh live one kept.
if [[ -f "$seat_state/active-seats/pi-issue-demo-9.json" ]]; then
    {
        echo "=== s4 FAILURE dump ==="
        echo "--- env_out ---"; printf '%s\n' "$env_out"
        echo "--- active-seats after ---"; ls -la "$seat_state/active-seats/" 2>&1 || true
        echo "--- calls.log ---"; cat "$calls" 2>&1 || true
        echo "--- wedged_units ---"; cat "$scratch/wedged_units" 2>&1 || true
        echo "--- fresh_activating_units ---"; cat "$scratch/fresh_activating_units" 2>&1 || true
        echo "--- live_seat_units ---"; cat "$scratch/live_seat_units" 2>&1 || true
        echo "--- /proc/uptime ---"; cat /proc/uptime 2>&1 || true
        echo "--- uname ---"; uname -a 2>&1 || true
    } >&2
    fail "scenario4: wedged-activating phantom was not reaped"
fi
[[ -f "$seat_state/active-seats/pi-issue-demo-10.json" ]] \
    || fail "scenario4: fresh-activating live seat was wrongly reaped"
grep -q 'wedged active-seat' <<<"$env_out" \
    || fail "scenario4: stderr missing wedged-reap log line: $env_out"
ok "scenario4: wedged-activating phantom reaped, fresh-activating kept (P15)"

# ============================================================================
# Scenario 5 (auditor-finding-C): a finished worker opened a PR but left the
# agent-in-progress label on. tier1 §3 holds on open PRs (work in flight), so
# the stale label survives and the watchdog counts it as work=1/running=0.
# OLD behaviour: repair (restart intake, which skips — no agent-ready issues),
# set marker; next tick fail-loud -> permanent false wedge. NEW behaviour: the
# stale label is a LABEL-HYGIENE fault, not a wedge -> clear it (remove
# agent-in-progress only; the open PR is the deliverable, do NOT re-queue) and
# exit 0. No repair, no marker, no fail-loud.
# ============================================================================
reset_state
printf '0\n' >"$scratch/work_ready"        # zero agent-ready
printf '0\n' >"$scratch/work_inprogress"   # static count fallback (post-clear = 0)
printf '61\n' >"$WORK_INPROGRESS_NUMBERS"  #   issue #61 (stale agent-in-progress)
printf '61\n' >"$OPEN_PR_ISSUES"           #   #61 has an open claim PR
: >"$scratch/running_units"                # zero live workers (worker long gone)
: >"$scratch/failed_units"
# Pre-seed the wedge marker so we PROVE the stale-label path does NOT fail loud
# even when the previous tick was wedged (the regression's exact second tick).
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$log_dir/undersaturation.flag"

run_helper
[[ "$env_rc" == 0 ]] \
    || fail "scenario5: stale-label tick must exit 0 (label hygiene), got $env_rc ($env_out)"

# The stale agent-in-progress label was removed (remove-only — no add-label,
# because the open PR is the deliverable and must not be re-queued).
grep -q 'issue edit' "$calls" \
    || fail "scenario5: no gh issue edit call recorded ($(cat "$calls"))"
grep -q -- '--remove-label agent-in-progress' "$calls" \
    || fail "scenario5: --remove-label agent-in-progress not issued"
if grep -q -- '--add-label agent-ready' "$calls"; then
    fail "scenario5: must NOT add agent-ready (open PR = work done, not re-queue): $(cat "$calls")"
fi
# No repair actions (the only "work" was a stale label, now cleared).
if grep -qE '^(reset-failed|start) ' "$calls"; then
    fail "scenario5: stale-label tick must not repair, but calls=($(cat "$calls"))"
fi
# No fail-loud; the label-hygiene loud line IS emitted so the action is visible.
! grep -q 'UNDERSAT-FAIL-LOUD' "$triage" \
    || fail "scenario5: triage must NOT have UNDERSAT-FAIL-LOUD (stale label is not a wedge)"
! grep -q 'UNDERSAT-REPAIR' "$triage" \
    || fail "scenario5: triage must NOT have UNDERSAT-REPAIR"
grep -q 'UNDERSAT-LABEL-HYGIENE' "$triage" \
    || fail "scenario5: triage missing UNDERSAT-LABEL-HYGIENE line"
# Marker cleared (healthy outcome), so the post-hygiene tick starts clean.
[[ ! -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario5: stale wedge marker must be cleared after label hygiene"
ok "scenario5: stale agent-in-progress + open PR + no live worker -> label cleared, exit 0 (not fail loud)"

# ============================================================================
# Scenario 6 (auditor-finding-C, no-PR complement): a stale agent-in-progress
# label with NO live worker and NO open PR. tier1 §3 owns this (flip to
# agent-ready + delete branch) but if it failed, the label survives. The reap
# mirrors §3: flip agent-in-progress -> agent-ready (re-queue). After the flip
# there is genuine ready work with no worker, so the wedge repair (restart
# intake) fires and the marker is set — exit 0 on the first tick. This proves
# the reap does not strand no-PR stale labels by silently dropping them.
# ============================================================================
reset_state
printf '0\n' >"$scratch/work_ready"
printf '0\n' >"$scratch/work_inprogress"
printf '42\n' >"$WORK_INPROGRESS_NUMBERS"
: >"$OPEN_PR_ISSUES"                       # no open PR for #42
: >"$scratch/running_units"
: >"$scratch/failed_units"

run_helper
[[ "$env_rc" == 0 ]] \
    || fail "scenario6: no-PR stale-label first tick must exit 0, got $env_rc ($env_out)"

# Label flipped to agent-ready (remove + add), not dropped.
grep -q -- '--remove-label agent-in-progress' "$calls" \
    || fail "scenario6: --remove-label agent-in-progress not issued"
grep -q -- '--add-label agent-ready' "$calls" \
    || fail "scenario6: --add-label agent-ready not issued (no-PR stale label must be re-queued)"
# The flip produced genuine ready work with no worker -> intake restarted.
grep -qx 'start pi-intake@demo.service' "$calls" \
    || fail "scenario6: intake restart not attempted after flip ($(cat "$calls"))"
# Label hygiene + repair both visible; no fail-loud on the first tick.
grep -q 'UNDERSAT-LABEL-HYGIENE' "$triage" || fail "scenario6: missing UNDERSAT-LABEL-HYGIENE"
grep -q 'UNDERSAT-REPAIR' "$triage" || fail "scenario6: missing UNDERSAT-REPAIR (post-flip ready work)"
! grep -q 'UNDERSAT-FAIL-LOUD' "$triage" || fail "scenario6: must not fail-loud on first tick"
[[ -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario6: marker must be set (genuine wedge remains after flip)"
ok "scenario6: stale agent-in-progress + no PR + no live worker -> flipped to agent-ready, intake restarted, exit 0"

# ============================================================================
# Scenario 7 (fleet-ops#1155): an odd-named pi unit is still a live worker.
# The worker-count counter must inspect ExecStart for "pi --print", not unit
# names. A `pi-systemd-run --unit weird-1155-undersaturation -- ... pi --print`
# unit must suppress the false FleetUndersaturated alarm.
# ============================================================================
reset_state
printf '3\n' >"$scratch/work_ready"
printf '0\n' >"$scratch/work_inprogress"
printf 'weird-1155-undersaturation.service\n' >"$scratch/running_units"
: >"$scratch/failed_units"

run_helper
[[ "$env_rc" == 0 ]] \
    || fail "scenario7: odd-named live worker must be healthy, got $env_rc ($env_out)"
if grep -qE '^(reset-failed|start) ' "$calls"; then
    fail "scenario7: odd-named live worker must not repair, but calls=($(cat "$calls"))"
fi
! grep -q 'UNDERSAT-FAIL-LOUD' "$triage" || fail "scenario7: must not fail-loud on odd-named live worker"
! grep -q 'UNDERSAT-REPAIR' "$triage" || fail "scenario7: must not repair on odd-named live worker"
ok "scenario7: odd-named pi --print worker suppresses FleetUndersaturated (fleet-ops#1155)"

# ============================================================================
# Scenario 8 (fleet-ops#1558): below admit floor with supply.
# ready >= admit AND 0 < running < admit -> REPAIR on first tick (not a full
# wedge). Pins "25-when-supply-exists" without paging when MemAvailable drops.
# ============================================================================
reset_state
export FLEET_UNDERSAT_ADMIT_CEILING=5
printf '8\n' >"$scratch/work_ready"          # ready >= admit
printf '0\n' >"$scratch/work_inprogress"
printf 'pi-issue@demo-1.service\n' >"$scratch/running_units"  # running=1 < 5
: >"$scratch/failed_units"
printf 'pi-issue@demo-1.service\n' >"$scratch/live_seat_units"
printf '{"unit":"pi-issue-demo-1","provider":"devin","model":"glm-5-2"}' \
    >"$seat_state/active-seats/pi-issue-demo-1.json"

run_helper
[[ "$env_rc" == 0 ]] \
    || fail "scenario8: below-admit first tick must exit 0, got $env_rc ($env_out)"
grep -q 'UNDERSAT-REPAIR' "$triage" \
    || fail "scenario8: triage missing UNDERSAT-REPAIR"
grep -q 'below-admit-floor' <<<"$env_out" \
    || fail "scenario8: stderr must name reason=below-admit-floor: $env_out"
grep -qx 'start pi-intake@demo.service' "$calls" \
    || fail "scenario8: intake restart not attempted ($(cat "$calls"))"
[[ -f "$log_dir/undersaturation.flag" ]] \
    || fail "scenario8: marker must be set after below-admit repair"
ok "scenario8: ready>=admit and running<admit -> repair (fleet-ops#1558)"

# ============================================================================
# Scenario 9 (fleet-ops#1558): running already at the admit floor is healthy
# even when ready >> admit. Self-throttled / at-ceiling is not a fault.
# ============================================================================
reset_state
export FLEET_UNDERSAT_ADMIT_CEILING=2
printf '30\n' >"$scratch/work_ready"
printf '0\n' >"$scratch/work_inprogress"
printf 'pi-issue@demo-1.service\npi-issue@demo-2.service\n' >"$scratch/running_units"
: >"$scratch/failed_units"

run_helper
[[ "$env_rc" == 0 ]] \
    || fail "scenario9: at-admit tick must exit 0, got $env_rc ($env_out)"
if grep -qE '^(reset-failed|start) ' "$calls"; then
    fail "scenario9: at-admit must not repair, but calls=($(cat "$calls"))"
fi
! grep -q 'UNDERSAT-REPAIR' "$triage" || fail "scenario9: must not UNDERSAT-REPAIR when running>=admit"
! grep -q 'UNDERSAT-FAIL-LOUD' "$triage" || fail "scenario9: must not fail-loud when running>=admit"
ok "scenario9: running>=admit with ready>>admit is healthy (fleet-ops#1558)"

# Restore the default admit pin for any later scenarios.
export FLEET_UNDERSAT_ADMIT_CEILING=25

ok "undersaturation: stale agent-in-progress label is hygiene, not a wedge (auditor-finding-C)"
ok "undersaturation: admit-floor below-target is a fault (fleet-ops#1558)"
