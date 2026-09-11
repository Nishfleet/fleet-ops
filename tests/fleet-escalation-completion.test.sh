#!/usr/bin/env bash
# tests/fleet-escalation-completion.test.sh
#
# Escalation COMPLETION invariant (fleet-ops#468, decisions-ledger 2026-08-27
# "escalation matrix FIXES, not just routes"). Every escalation chain must
# terminate in a verified fix (detector-green) or a Nish-reserved wall.
# A stalled chain climbs the ladder (re-fire -> fail-loud -> unit-escalation).
#
# What we prove:
#   1. No STOP-REASON (or terminal reason) -> exit 0, clean.
#   2. Open unit-failure chain, detector RED, within budget -> exit 0 (in-flight).
#   3. Same chain past budget, pipeline idle -> first tick re-fires
#      (repair) -> exit 0, stall marker set.
#   4. Next tick still stalled, pipeline idle -> FAIL LOUD (exit 1).
#   5. Detector GREEN + non-terminal STOP-REASON + pipeline IDLE -> stale
#      trip ladder (fleet-ops#5190): LOUD + re-fire the auditor pipeline ->
#      exit 0; quiet hold between actions; FAIL LOUD (exit 1) only once the
#      re-fire bound is spent — never on consecutive stale ticks.
#   6. Detector GREEN + non-terminal STOP-REASON + pipeline ACTIVE -> the
#      closeout is in flight -> exit 0 (not stale).
#   7. NISH-ESCALATIONS.md holds hash -> Nish-reserved wall -> exit 0.
#   8. Pipeline-active guard: a dispatch in flight resets the progress clock.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-escalation-completion"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-escalation-completion not found: $bin"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t completion.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# systemctl mock: per-unit state via env var (store path cannot ride in
# the SYSTEMCTL variable — the bin quotes "$SYSTEMCTL" so a space in it
# would break word splitting). Uses SYSCTL_STORE env.
sysctl_store="$scratch/sysctl"
mkdir -p "$sysctl_store"
cat >"$scratch/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${SYSCTL_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  --user)
    cmd="$1"; shift
    case "$cmd" in
      show)
        unit=""; prop=""
        for a in "$@"; do
          case "$a" in
            --property=*) prop="${a#--property=}" ;;
            --value) ;;
            *) [ -z "$unit" ] && unit="$a" ;;
          esac
        done
        if [ -f "$store/$unit.result" ]; then cat "$store/$unit.result"; else echo "success"; fi
        ;;
      is-active)
        unit="$1"
        if [ -f "$store/$unit.active" ]; then cat "$store/$unit.active"; else echo "active"; fi
        ;;
      restart) echo "restarted" >&2 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/systemctl"

# Default: failed unit is RED (detector not green), pipeline idle.
echo "exit-code" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "failed"    > "$sysctl_store/pi-issue@0509-1.service.active"
echo "inactive"  > "$sysctl_store/stop-escalation.service.active"

# The STOP-REASON points at the failed unit.
STOP_REASON="$scratch/STOP-REASON.json"
SEEN="$scratch/seen.txt"
WALLED="$scratch/stop-escalation-walled.txt"
NISH="$scratch/NISH-ESCALATIONS.md"
AUDLOG="$scratch/AUDITOR-LOG.md"

write_trip() {
  local reason="${1:-unit-failure}" unit="${2:-pi-issue@0509-1.service}"
  python3 - "$STOP_REASON" "$reason" "$unit" <<'PY'
import sys, json
path, reason, unit = sys.argv[1:]
json.dump({"reason": reason, "detail": {"unit": unit}}, open(path, "w"))
PY
}

run_bin() {
  local now="$1"
  set +e
  FLEET_ESCALATION_COMPLETION_STATE="$scratch/state" \
  FLEET_ESCALATION_COMPLETION_BUDGET="3600" \
  FLEET_STOP_REASON="$STOP_REASON" \
  FLEET_STOP_ESCALATION_SEEN="$SEEN" \
  FLEET_STOP_ESCALATION_WALLED="$WALLED" \
  FLEET_NISH_ESCALATIONS="$NISH" \
  FLEET_AUDITOR_LOG="$AUDLOG" \
  FLEET_ESCALATION_COMPLETION_SYSTEMCTL="$scratch/systemctl" \
  SYSCTL_STORE="$sysctl_store" \
  FLEET_ESCALATION_COMPLETION_NOW="$now" \
  FLEET_ESCALATION_COMPLETION_DRY_RUN="1" \
  FLEET_ESCALATION_COMPLETION_STALE_HOLD="${STALE_HOLD:-10800}" \
  FLEET_ESCALATION_COMPLETION_STALE_REFIRES="${STALE_REFIRES:-2}" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

rm -rf "$scratch/state"; mkdir -p "$scratch/state"

# --- 1. no STOP-REASON -> clean ---------------------------------------------
rm -f "$STOP_REASON"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "no STOP-REASON should exit 0 (got $rc)"
ok "no STOP-REASON exits 0"

# --- 1b. terminal reason -> clean -------------------------------------------
write_trip "auditor-resolved"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "terminal STOP-REASON should exit 0 (got $rc)"
ok "terminal STOP-REASON exits 0"

# --- 2. open chain, detector red, within budget -> in-flight, exit 0 --------
write_trip "unit-failure"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "in-flight chain within budget should exit 0 (got $rc)"
grep -q "in-flight" "$scratch/err.log" || fail "missing in-flight log"
ok "open chain within budget is in-flight (exit 0)"

# --- 3. past budget, pipeline idle, first stale tick -> repair re-fire -------
rc=$(run_bin "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "first stale tick should exit 0 (repair) (got $rc)"
grep -q "REPAIR" "$scratch/err.log" || fail "missing REPAIR loud line"
ok "past budget, first stale tick re-fires (repair, exit 0)"

# --- 4. still stalled next tick -> FAIL LOUD --------------------------------
rc=$(run_bin "2026-08-27T04:00:00Z")
[[ "$rc" == "1" ]] || fail "second stale tick should fail loud (got $rc)"
grep -q "FAIL-LOUD" "$scratch/err.log" || fail "missing FAIL-LOUD loud line"
ok "consecutive stale tick fails loud (exit 1)"

# --- 5. detector green + non-terminal + pipeline idle -> stale trip ladder --
# fleet-ops#5190: a stale trip re-fires the auditor pipeline and HOLDS
# (exit 0) instead of failing the heartbeat every tick; exit 1 is reserved
# for a chain still stale after the re-fire bound is spent.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
echo "success" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "active"  > "$sysctl_store/pi-issue@0509-1.service.active"
# 5a. First stale tick: LOUD + re-fire + hold (exit 0), not a heartbeat failure.
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "first stale tick should re-fire and hold (exit 0), got $rc"
grep -q "STALE-TRIP" "$scratch/err.log" || fail "missing STALE-TRIP loud line"
grep -q "would restart stop-escalation.service" "$scratch/err.log" \
  || fail "stale trip must re-fire the auditor pipeline (restart stop-escalation.service)"
ok "stale trip: LOUD + auditor re-fire, exit 0 (no heartbeat failure)"
# 5b. Next tick inside the hold window: quiet hold — no second action, no
# second STALE-TRIP line (bounded, not one per tick).
rc=$(run_bin "2026-08-27T00:30:00Z")
[[ "$rc" == "0" ]] || fail "held stale tick should exit 0 (got $rc)"
! grep -q "STALE-TRIP" "$scratch/err.log" \
  || fail "held stale tick must not re-emit STALE-TRIP (bounded lines)"
grep -q "stale trip held" "$scratch/err.log" || fail "missing stale-trip hold log"
ok "stale tick inside hold window is quiet (exit 0, no second STALE-TRIP)"
# 5c. Tick past the hold window: second action -> second re-fire -> exit 0.
rc=$(run_bin "2026-08-27T04:00:00Z")
[[ "$rc" == "0" ]] || fail "second stale-trip action should re-fire (exit 0), got $rc"
grep -q "re-fire 2/2" "$scratch/err.log" || fail "missing second re-fire log"
ok "stale tick past hold re-fires again (re-fire 2/2, exit 0)"
# 5d. Still stale once the re-fire bound is spent: FAIL LOUD once (exit 1).
rc=$(run_bin "2026-08-27T08:00:00Z")
[[ "$rc" == "1" ]] || fail "stale trip past re-fire bound should fail loud (got $rc)"
grep -q "STALE-TRIP" "$scratch/err.log" || fail "missing STALE-TRIP on fail-loud tick"
grep -q "FAIL-LOUD" "$scratch/err.log" || fail "missing FAIL-LOUD line"
ok "stale trip past re-fire bound fails loud (exit 1)"
# 5e. The tick right after a fail-loud is a quiet hold (exit 0): two
# consecutive stale ticks must not both exit 1.
rc=$(run_bin "2026-08-27T08:10:00Z")
[[ "$rc" == "0" ]] || fail "tick after fail-loud must hold (exit 0), got $rc"
ok "consecutive stale ticks never both fail (post-fail hold, exit 0)"
# 5f. And the ladder cycles: the next action tick re-fires again rather
# than failing forever.
rc=$(run_bin "2026-08-27T12:00:00Z")
[[ "$rc" == "0" ]] || fail "post-fail action tick should re-fire (exit 0), got $rc"
grep -q "re-fire 1/2" "$scratch/err.log" || fail "ladder must cycle back to re-fire 1/2"
ok "stale-trip ladder cycles (fail-loud -> re-fire), exit 0"

# --- 6. green detector + non-terminal + pipeline ACTIVE -> closeout in flight
echo "activating" > "$sysctl_store/stop-escalation.service.active"
rc=$(run_bin "2026-08-27T00:01:00Z")
[[ "$rc" == "0" ]] || fail "green detector + active pipeline should exit 0 (got $rc)"
grep -q "closeout in flight" "$scratch/err.log" || fail "missing closeout-in-flight log"
echo "inactive" > "$sysctl_store/stop-escalation.service.active"
ok "green detector + active pipeline = closeout in flight (exit 0)"

# --- 7. NISH wall reached -> legal terminal ---------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
echo "exit-code" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "failed"    > "$sysctl_store/pi-issue@0509-1.service.active"
# Recompute the hash the bin would use (sha256 of the STOP-REASON file).
hash=$(sha256sum "$STOP_REASON" | awk '{print $1}')
printf 'CAP-REACHED hash=%s count=2\n' "$hash" > "$NISH"
rc=$(run_bin "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "Nish-reserved wall should exit 0 (got $rc)"
grep -q "Nish-reserved wall" "$scratch/err.log" || fail "missing wall log"
ok "Nish-reserved wall is a legal terminal (exit 0)"

# --- 7b. LADDER-WALLED chain -> dispatcher-spent terminal (exit 0) -------
# fleet-ops#623 / 2026-08-28 storm fix: a fully-walled seat ladder records the
# hash in stop-escalation-walled.txt and deliberately does NOT write a
# NISH-ESCALATIONS.md line for a non-payment reason. Without this case the
# chain had no legal terminal and the enforcer re-fired STALE-TRIP every tick
# (green detector + idle pipeline + non-terminal STOP-REASON), failing
# fleet-heartbeat.service and summoning a fresh auditor for a spent chain.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$NISH"
echo "success" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "active"  > "$sysctl_store/pi-issue@0509-1.service.active"
echo "inactive" > "$sysctl_store/stop-escalation.service.active"
write_trip "unit-failure"
hash=$(sha256sum "$STOP_REASON" | awk '{print $1}')
printf '%s 1789079695\n' "$hash" > "$WALLED"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "ladder-walled chain should exit 0 (got $rc)"
grep -q "ladder-walled" "$scratch/err.log" || fail "missing ladder-walled log"
! grep -q "STALE-TRIP" "$scratch/err.log" \
  || fail "ladder-walled chain must not STALE-TRIP"
terminal=$(jq -r '.terminal // ""' "$scratch/state/$hash.json" 2>/dev/null || true)
[[ "$terminal" == "ladder-walled" ]] || fail "chain state must record terminal=ladder-walled (got '$terminal')"
# A different hash in the ledger must NOT free this chain: it still
# STALE-TRIPs (first stale tick re-fires + holds, exit 0 — fleet-ops#5190).
printf 'deadbeef 1789079695\n' > "$WALLED"
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "unwalled hash must still STALE-TRIP (re-fire+hold exit 0, got $rc)"
grep -q "STALE-TRIP" "$scratch/err.log" || fail "unwalled hash missing STALE-TRIP loud line"
rm -f "$WALLED"
# Restore the RED detector case 8 expects (7b flipped it green).
echo "exit-code" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "failed"    > "$sysctl_store/pi-issue@0509-1.service.active"
ok "ladder-walled chain is a legal terminal (exit 0); unwalled hash still trips"

# --- 8. pipeline-active guard on stalled chain ------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$NISH"
# Establish first_seen at 00:00 (age 0, in-flight).
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "guard: first run should exit 0 (got $rc)"
# Red detector, past budget, but pipeline actively dispatching -> not stalled.
echo "activating" > "$sysctl_store/stop-escalation.service.active"
rc=$(run_bin "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "stalled-age chain with active pipeline should exit 0 (got $rc)"
grep -qE "actively dispatching|closeout in flight" "$scratch/err.log" || fail "missing actively-dispatching/closeout log"
echo "inactive" > "$sysctl_store/stop-escalation.service.active"
ok "pipeline-active guard prevents false stall (exit 0)"

# --- 8b. observe-to-close: a STALE-TRIP chain that was loud (re-fire +
# hold, exit 0) must recover to clean (exit 0) once the auditor advances
# STOP-REASON to a terminal reason, so the detector->queue reconciler
# observe-to-closes the filed alarm issue. This is the exact closeout
# trajectory fleet-ops#4919 (chain fbe128) rides: the warning fired on a
# green+idle non-terminal STOP-REASON, the senior auditor then wrote
# auditor-resolved, and the next heartbeat tick must exit 0 clean (no
# STALE-TRIP) for the alarm to resolve.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
echo "success" > "$sysctl_store/pi-issue@0509-1.service.result"
echo "active"  > "$sysctl_store/pi-issue@0509-1.service.active"
echo "inactive" > "$sysctl_store/stop-escalation.service.active"
# Trip open (non-terminal), detector green, pipeline idle -> STALE-TRIP
# re-fire + hold (exit 0 — the ladder is in motion, not a failure).
write_trip "unit-failure"
rc=$(run_bin "2026-08-27T00:00:00Z")
[[ "$rc" == "0" ]] || fail "observe-to-close: open trip on green+idle should re-fire and hold (exit 0), got $rc"
grep -q "STALE-TRIP" "$scratch/err.log" || fail "observe-to-close: missing STALE-TRIP loud line"
# Senior auditor closes the STOP-REASON (advance to terminal). Detector stays green.
write_trip "auditor-resolved"
rc=$(run_bin "2026-08-27T00:01:00Z")
[[ "$rc" == "0" ]] || fail "observe-to-close: terminal STOP-REASON must exit 0 clean (got $rc)"
grep -q "no open escalation chain" "$scratch/err.log" \
  || fail "observe-to-close: missing clean close log"
! grep -q "STALE-TRIP" "$scratch/err.log" \
  || fail "observe-to-close: STALE-TRIP must not re-fire after closeout"
ok "observe-to-close: STALE-TRIP chain closes clean once STOP-REASON is advanced to terminal (exit 0)"

# --- 9. wiring pins (fleet-ops#480) ----------------------------------------
# The bin is only "enforced" if heartbeat actually runs it, MANIFEST
# installs it once, the matrix says enforced, and the CI-listed canary
# runner keeps invoking this suite (worker tokens cannot push workflows).
tier1="$repo_root/bin/fleet-heartbeat-tier1"
grep -F 'fleet-escalation-completion' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-escalation-completion"
grep -F 'escalation_completion_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture escalation_completion_rc"
grep -F -- 'exit "${escalation_completion_rc}"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the completion enforcer fails loud"
n=$(grep -cF 'bin/fleet-escalation-completion ' "$repo_root/MANIFEST" || true)
[[ "$n" == "1" ]] || fail "MANIFEST must list fleet-escalation-completion exactly once (got $n)"
grep -F 'fleet-escalation-completion.test.sh' "$here/escalation-coverage-canary.test.sh" >/dev/null \
  || fail "escalation-coverage-canary.test.sh must invoke this suite (fleet-ops#480)"

matrix="$repo_root/config/rule-enforcement.json"
row_n=$(jq '[.rules[] | select(.id=="led-escalation-matrix-fixes")] | length' "$matrix")
[[ "$row_n" == "1" ]] || fail "matrix must have exactly one led-escalation-matrix-fixes row (got $row_n)"
src=$(jq -r '.rules[] | select(.id=="led-escalation-matrix-fixes") | .source' "$matrix")
[[ "$src" == "decisions-ledger.md: 2026-08-27 | escalation matrix FIXES, not just routes" ]] \
  || fail "matrix source mismatch: $src"
status=$(jq -r '.rules[] | select(.id=="led-escalation-matrix-fixes") | .status' "$matrix")
[[ "$status" == "enforced" ]] || fail "led-escalation-matrix-fixes must stay enforced (got $status)"
proof=$(jq -r '.rules[] | select(.id=="led-escalation-matrix-fixes") | .proof' "$matrix")
[[ "$proof" == *fleet-escalation-completion* ]] || fail "proof must name fleet-escalation-completion"
ok "wiring: heartbeat fail-loud, MANIFEST once, nested canary runner, matrix enforced"

echo "OK: fleet-escalation-completion: chain tracking, stall ladder, stale-trip, wall, pipeline guard"
