#!/usr/bin/env bash
# tests/fleet-completion-canary.test.sh
#
# Alert-repair COMPLETION invariant (fleet-ops#468, packet 11).
# fleet-escalation-completion already covers the unit-escalation plane.
# This canary covers Prometheus alert chains: firing → DISPATCH → unit
# result → detector-green, with hop clocks, and climbs the ladder itself.
#
# What we prove (hermetic, no live 9090/systemd):
#   1. Empty world → exit 0, fleet_chain_open exported as 0 (absent() rail).
#   2. CanaryDrill DISPATCH + dead unit past RUN clock → stall, REDISPATCH
#      log line, STOP-REASON reason=alert-repair-stalled, --print-seat used,
#      dispatcher is NEVER invoked with AMX (drill skip-list).
#   3. DISPATCH + RESOLVED → chains.terminated.jsonl terminal=green + cycle.
#   4. Firing real alert, no DISPATCH, past 10 min → AMX redispatch.
#   5. Watchdog firing is ignored.
#  5c. FleetSloSeatAvailSlowBurn firing is ignored (WFR-input slow-burn class —
#      no dispatch exists by design, fleet-ops#2429).
#   6. VERIFY ... resolved counts as terminal-green.
#   7. Unit-escalation STOP-REASON within 24h budget → open, not stalled,
#      and this canary does not overwrite it.
#   8. MANIFEST + timer named-reason + nested from coverage canary.
#  10. Dispatch plane (fleet-ops#1009): orphan past deadline, retries < 2 →
#      re-dispatch via pi-systemd-run with --chain-id --hop+1, ledger closed
#      redispatched, SAME packet file re-issued.
#  11. Dispatch plane: orphan past deadline, retries >= 2 → STOP-REASON
#      reason=dispatch-orphan, no re-dispatch.
#  12. Dispatch plane: completed-success (journal) → close green.
#  13. Dispatch plane: in-flight (active) → leave open.
#  14. Dispatch plane: orphan before deadline → waiting, no re-dispatch.
#  15. Dispatch plane: --collect unit, Started-only journal → completed-success.
#  16. Issue-close evidence: closed without PR/commit evidence is flagged.
#  17. Escalated dispatch/run chain terminates as terminal=escalated (not parked)
#      — the fleet-ops#2367 drain (STOP-REASON hand-off is the terminal).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-completion-canary.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
[[ -x "$bin" ]] || fail "not executable: $bin"
python3 -m py_compile "$bin" || fail "py_compile failed"

scratch="$(mktemp -d -t completion-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/sysctl" "$scratch/open"
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
        unit=""
        want_value=0
        props=()
        for a in "$@"; do
          case "$a" in
            --property=*) props+=("${a#--property=}") ;;
            --value) want_value=1 ;;
            -*) ;;
            *) [ -z "$unit" ] && unit="$a" ;;
          esac
        done
        # Real systemd defaults: LoadState=not-found → Result=success (the
        # default), ActiveState=inactive, exit 0. A --collect unit that
        # unloaded looks exactly like this — the bug in fleet-ops#2100 was
        # that unit_status trusted that default Result=success.
        result="success"; active="inactive"; load="not-found"
        [ -f "$store/$unit.result" ] && result=$(cat "$store/$unit.result")
        [ -f "$store/$unit.active" ] && active=$(cat "$store/$unit.active")
        # LoadState: loaded if we have any state file for this unit
        if [ -f "$store/$unit.result" ] || [ -f "$store/$unit.active" ]; then
          load="loaded"
        fi
        if [ "$want_value" -eq 1 ]; then
          for p in "${props[@]}"; do
            case "$p" in
              Result) printf '%s\n' "$result" ;;
              ActiveState) printf '%s\n' "$active" ;;
              LoadState) printf '%s\n' "$load" ;;
              ExecMainStatus) printf '%s\n' "0" ;;
            esac
          done
        else
          printf 'Result=%s\nActiveState=%s\nLoadState=%s\n' "$result" "$active" "$load"
        fi
        # Real systemd: systemctl show always exits 0 (even for not-found
        # units). The old fake exited 1 for not-found, masking the #2100 bug.
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/systemctl"

# Fake journalctl for the dispatch plane (fleet-ops#1009). Mirrors the real
# journald options the canary uses: plain cat (tests 10-15), and the
# -g <pattern> / -n <count> pair journal_started passes (fleet-ops#2414).
cat >"$scratch/journalctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${SYSCTL_STORE:?}"
unit=""
grep_pat=""
last_n=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-g" ]; then grep_pat="$a"; prev=""; continue; fi
  if [ "$prev" = "-n" ]; then last_n="$a"; prev=""; continue; fi
  case "$a" in
    -g|-n) prev="$a" ;;
    -*) ;;
    *.service) unit="$a" ;;
  esac
done
[ -n "$unit" ] || exit 0
jf="$store/$unit.journal"
[ -f "$jf" ] || exit 0
if [ -n "$grep_pat" ]; then
  grep -E "$grep_pat" "$jf" | tail -n "${last_n:-1000000}"
else
  tail -n "${last_n:-1000000}" "$jf"
fi
exit 0
FAKE
chmod +x "$scratch/journalctl"

# Fake pi-systemd-run for the dispatch plane re-dispatch (fleet-ops#1009).
cat >"$scratch/pi-systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "pi-systemd-run: $*" >>"${REDISPATCH_LOG:?}"
exit 0
FAKE
chmod +x "$scratch/pi-systemd-run"

cat >"$scratch/dispatcher" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
log="${DISPATCH_LOG:?}"
if printf '%s\n' "$@" | grep -qx -- '--print-seat'; then
  echo "print-seat $*" >>"$log"
  excl=""
  i=0
  for a in "$@"; do
    i=$((i + 1))
    if [ "$a" = "--exclude" ]; then
      eval "excl=\${$i}"
      # next token after --exclude — handled below
    fi
  done
  # Walk argv for the value after --exclude
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--exclude" ]; then
      echo -e "minimax\tMiniMax-M3\tfallback-excluded"
      echo "print-seat-exclude=$a" >>"$log"
      exit 0
    fi
    prev="$a"
  done
  echo -e "devin\tglm-5-2\thealthy"
  exit 0
fi
echo "dispatch AMX_ALERT_1_LABEL_alertname=${AMX_ALERT_1_LABEL_alertname:-} AMX_STATUS=${AMX_STATUS:-} AMX_RECEIVER=${AMX_RECEIVER:-}" >>"$log"
exit 0
FAKE
chmod +x "$scratch/dispatcher"

run_bin() {
  set +e
  AGENT_STATE="$scratch/as" \
  FLEET_COMPLETION_STATE="$scratch/state" \
  FLEET_COMPLETION_ACTIONS_LOG="$scratch/actions.log" \
  FLEET_COMPLETION_PROM="$scratch/fleet-chains.prom" \
  FLEET_COMPLETION_ALERTS_JSON="$scratch/alerts.json" \
  FLEET_COMPLETION_DISPATCHER="$scratch/dispatcher" \
  FLEET_COMPLETION_SYSTEMCTL="$scratch/systemctl" \
  FLEET_COMPLETION_JOURNALCTL="$scratch/journalctl" \
  FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch/pi-systemd-run" \
  FLEET_DISPATCH_LEDGER="$scratch/dispatch-ledger.jsonl" \
  FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
  FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
  FLEET_COMPLETION_TRIAGE="$scratch/triage.md" \
  FLEET_COMPLETION_NOW="${1:?}" \
  SYSCTL_STORE="$scratch/sysctl" \
  DISPATCH_LOG="$scratch/dispatch.log" \
  REDISPATCH_LOG="$scratch/redispatch.log" \
  HOME="$scratch" \
    python3 "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

write_alerts() {
  python3 - "$scratch/alerts.json" <<'PY'
import json, sys
path = sys.argv[1]
alerts = json.loads(sys.stdin.read() or "[]")
json.dump({"status": "success", "data": {"alerts": alerts}}, open(path, "w"))
PY
}

# --- 1. empty world ----------------------------------------------------------
mkdir -p "$scratch/as" "$scratch/state"
: >"$scratch/actions.log"
: >"$scratch/dispatch.log"
write_alerts <<<'[]'
rc=$(run_bin "2026-08-27T15:00:00Z")
[[ "$rc" == "0" ]] || fail "empty world rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
  || fail "empty world must export fleet_chain_open=0 (absent() rail)"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "empty world must export fleet_chain_stalled=0"
grep -q 'fleet_chain_completion_timestamp_seconds ' "$scratch/fleet-chains.prom" \
  || fail "missing completion timestamp"
ok "empty world exports zeroed fleet_chain_* (absent-rail live)"

# --- 2. synthetic CanaryDrill stall -----------------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state" "$scratch/sysctl"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
# DISPATCH 90 min before NOW; unit is dead.
printf '%s\n' \
  '[2026-08-27T13:30:00Z] DISPATCH alertname=CanaryDrill unit=alert-repair-CanaryDrill-DRILL.service seat=devin/glm-5-2 reason=drill packet=/dev/null rc=0' \
  >"$scratch/actions.log"
echo "exit-code" >"$scratch/sysctl/alert-repair-CanaryDrill-DRILL.service.result"
echo "failed"    >"$scratch/sysctl/alert-repair-CanaryDrill-DRILL.service.active"
write_alerts <<<'[]'
rc=$(run_bin "2026-08-27T15:00:00Z")
[[ "$rc" == "0" ]] || fail "drill stall rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="run"} 1' "$scratch/fleet-chains.prom" \
  || fail "drill must stall at hop=run; prom=$(cat "$scratch/fleet-chains.prom")"
[[ -f "$scratch/STOP-REASON.json" ]] || fail "drill must write STOP-REASON"
python3 - "$scratch/STOP-REASON.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["reason"] == "alert-repair-stalled", d
assert d["detail"]["alertname"] == "CanaryDrill", d
assert d["detail"]["hop"] == "run", d
print("stop-reason-ok")
PY
grep -q 'REDISPATCH alertname=CanaryDrill' "$scratch/actions.log" \
  || fail "drill must append REDISPATCH line"
grep -q 'print-seat' "$scratch/dispatch.log" \
  || fail "drill must reuse --print-seat (got $(cat "$scratch/dispatch.log"))"
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "CanaryDrill must NOT invoke AMX redispatch (skip-list); log=$(cat "$scratch/dispatch.log")"
fi
grep -q 'UNREPAIRED-FAIL' "$scratch/triage.md" \
  || fail "drill must LOUD UNREPAIRED-FAIL"
ok "CanaryDrill stall: STOP-REASON + REDISPATCH + --print-seat, no AMX spawn"

# --- 3. happy path DISPATCH + RESOLVED --------------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
printf '%s\n' \
  '[2026-08-27T06:38:37Z] DISPATCH alertname=FleetMainRed unit=alert-repair-FleetMainRed-20260827T063836Z seat=commandcode/minimax/minimax-m3-free reason=healthy packet=/x rc=0' \
  '[2026-08-27T06:58:49Z] RESOLVED alertname=FleetMainRed repo=x root_cause=transient' \
  >"$scratch/actions.log"
write_alerts <<<'[]'
rc=$(run_bin "2026-08-27T15:00:00Z")
[[ "$rc" == "0" ]] || fail "happy path rc=$rc stderr=$(cat "$scratch/err.log")"
[[ -f "$scratch/state/chains.terminated.jsonl" ]] || fail "missing terminated ledger"
python3 - "$scratch/state/chains.terminated.jsonl" <<'PY' || exit 1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hit = [r for r in rows if r["alertname"] == "FleetMainRed"]
assert hit, rows
r = hit[0]
assert r["terminal"] == "green", r
assert r["cycle_seconds"] == 1212, r  # 06:58:49 - 06:38:37
print("cycle", r["cycle_seconds"])
PY
grep -q 'fleet_chain_cycle_seconds{alertname="FleetMainRed",terminal="green"} 1212' \
  "$scratch/fleet-chains.prom" \
  || fail "cycle gauge missing; prom=$(cat "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "happy path must not stall"
ok "FleetMainRed terminated-green cycle_seconds=1212"

# --- 4. dispatch stall on a real firing alert --------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-27T14:40:00Z",
   "labels":{"alertname":"SystemUnitFailed"}}
]}}, open(sys.argv[1],"w"))
PY
rc=$(run_bin "2026-08-27T15:00:00Z")  # 20 min after firing > 10 min clock
[[ "$rc" == "0" ]] || fail "dispatch stall rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="dispatch"} 1' "$scratch/fleet-chains.prom" \
  || fail "expected dispatch stall; prom=$(cat "$scratch/fleet-chains.prom")"
grep -q 'dispatch AMX_ALERT_1_LABEL_alertname=SystemUnitFailed' "$scratch/dispatch.log" \
  || fail "real dispatch stall must AMX-redispatch; log=$(cat "$scratch/dispatch.log")"
grep -q 'REDISPATCH alertname=SystemUnitFailed' "$scratch/actions.log" \
  || fail "missing REDISPATCH receipt"
ok "firing SystemUnitFailed past 10 min → AMX redispatch"

# --- 5. Watchdog ignored -----------------------------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-23T08:58:34Z",
   "labels":{"alertname":"Watchdog"}}
]}}, open(sys.argv[1],"w"))
PY
rc=$(run_bin "2026-08-27T15:00:00Z")
[[ "$rc" == "0" ]] || fail "watchdog rc=$rc"
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
  || fail "Watchdog must not open a chain"
ok "Watchdog firing is ignored"

# --- 5b. pending alerts are not dispatchable trips ---------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"pending","activeAt":"2026-08-27T13:47:04Z",
   "labels":{"alertname":"FleetCompletionCanaryAbsent"}},
  {"state":"pending","activeAt":"2026-08-27T13:40:26Z",
   "labels":{"alertname":"FleetMainRed"}}
]}}, open(sys.argv[1],"w"))
PY
rc=$(run_bin "2026-08-27T15:00:00Z")
[[ "$rc" == "0" ]] || fail "pending rc=$rc"
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
  || fail "pending must not open a dispatch chain"
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "pending must not AMX-redispatch; log=$(cat "$scratch/dispatch.log")"
fi
ok "pending alerts (for: still counting) are ignored"

# --- 5c. FleetSloSeatAvailSlowBurn firing is ignored (fleet-ops#2429) --------
# A WFR-input slow-burn SLO alert: the dispatcher skip-list means no DISPATCH
# is ever expected, so a firing-without-dispatch chain must NOT open (it
# would ladder: redispatch -> STOP-REASON -> escalate the senior conference
# for a measurement). Same SKIP_FIRING treatment as Watchdog.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-27T05:27:33Z",
   "labels":{"alertname":"FleetSloSeatAvailSlowBurn"}}
]}}, open(sys.argv[1],"w"))
PY
rc=$(run_bin "2026-08-27T15:00:00Z")  # ~9.5h after firing, far past all hop clocks
[[ "$rc" == "0" ]] || fail "seat-avail rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
  || fail "FleetSloSeatAvailSlowBurn must not open a chain; prom=$(cat "$scratch/fleet-chains.prom")"
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "FleetSloSeatAvailSlowBurn must not AMX-redispatch; log=$(cat "$scratch/dispatch.log")"
fi
[[ ! -f "$scratch/STOP-REASON.json" ]] \
  || fail "FleetSloSeatAvailSlowBurn must not write STOP-REASON"
ok "FleetSloSeatAvailSlowBurn firing is ignored (WFR-input slow-burn class)"

# --- 6. VERIFY resolved is terminal -----------------------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
printf '%s\n' \
  '[2026-08-27T04:49:22Z] DISPATCH alertname=SustainedLoadHigh unit=alert-repair-SustainedLoadHigh-20260827T044921Z seat=devin/glm-5-2 reason=fallback packet=/x rc=0' \
  '[2026-08-27T17:00:00Z] VERIFY alertname=SustainedLoadHigh resolved (load15=1.47)' \
  >"$scratch/actions.log"
write_alerts <<<'[]'
rc=$(run_bin "2026-08-27T18:00:00Z")
[[ "$rc" == "0" ]] || fail "verify-resolved rc=$rc stderr=$(cat "$scratch/err.log")"
python3 - "$scratch/state/chains.terminated.jsonl" <<'PY' || exit 1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hit = [r for r in rows if r["alertname"] == "SustainedLoadHigh"]
assert hit, rows
assert hit[0]["terminal"] == "green"
assert hit[0]["cycle_seconds"] == 43838, hit[0]  # 17:00:00 - 04:49:22
print("sustained cycle", hit[0]["cycle_seconds"])
PY
ok "VERIFY resolved terminates SustainedLoadHigh green"

# --- 7. unit-escalation observation, no overwrite ----------------------------
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/actions.log"
write_alerts <<<'[]'
python3 - "$scratch/STOP-REASON.json" <<'PY'
import json, sys
json.dump({
  "reason": "unit-failure",
  "detail": {"unit": "pi-issue@0509-1.service"},
  "timestamp": "2026-08-27T14:00:00Z",
  "source": "unit-escalation",
}, open(sys.argv[1], "w"))
PY
before=$(sha256sum "$scratch/STOP-REASON.json" | awk '{print $1}')
rc=$(run_bin "2026-08-27T15:00:00Z")  # 1h old, budget 24h
[[ "$rc" == "0" ]] || fail "ue observe rc=$rc"
after=$(sha256sum "$scratch/STOP-REASON.json" | awk '{print $1}')
[[ "$before" == "$after" ]] || fail "must not overwrite live unit-failure STOP-REASON"
grep -q 'fleet_chain_open{plane="unit-escalation",hop="trip"} 1' "$scratch/fleet-chains.prom" \
  || fail "ue open missing; prom=$(cat "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="unit-escalation",hop="trip"} 0' "$scratch/fleet-chains.prom" \
  || fail "1h-old unit-failure must not stall on 24h budget"
ok "unit-escalation open observed, STOP-REASON left alone, 24h clock honoured"

# --- 8. wiring ---------------------------------------------------------------
manifest="$repo_root/MANIFEST"
grep -F 'bin/fleet-completion-canary.py /home/nish/.local/libexec/fleet-completion-canary' "$manifest" >/dev/null \
  || fail "MANIFEST missing bin/fleet-completion-canary.py"
grep -F 'systemd/fleet-completion-canary.timer /home/nish/.config/systemd/user/fleet-completion-canary.timer' "$manifest" >/dev/null \
  || fail "MANIFEST missing timer"
timer="$repo_root/systemd/fleet-completion-canary.timer"
grep -q 'OnCalendar=' "$timer" || fail "timer missing OnCalendar"
grep -qi 'named reason' "$timer" || grep -qi 'hop clock' "$timer" \
  || fail "timer must carry a named reason (hop clocks / 15 min)"
grep -F 'fleet-completion-canary.test.sh' "$here/escalation-coverage-canary.test.sh" >/dev/null \
  || fail "must be nested from escalation-coverage-canary.test.sh (CI-listed)"
ok "MANIFEST + named-reason timer + nested CI wiring"

# --- 9. verify stall deadline → detector-red terminal (fleet-ops#1577/#1610) -
rm -rf "$scratch/state"; mkdir -p "$scratch/state"

# Fire BridgeSelfTest: the repair unit ALREADY SUCCEEDED but the alert is
# STILL firing — that is the verify-stall #1610 targets. classify sees
# hop=verify, stalled (unit_success + is_firing + verify_age past the clock).
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "BridgeSelfTest"},
   "activeAt": "2026-08-28T10:00:00Z"}
]}}, open(sys.argv[1], "w"))
PY

# DISPATCH + a unit result of success so classify sees hop=verify (not green).
now_ts="2026-08-28T12:05:00Z"
cat >"$scratch/actions.log" <<PYEND
[2026-08-28T10:02:00Z] DISPATCH alertname=BridgeSelfTest seat=someseat/SomeModel unit=alert-repair-BridgeSelfTest-20260828T100200Z
PYEND
# The dispatched alert-repair unit succeeded (moved to verify), but the alert
# has not left firing, so the chain stays open at verify and stalls.
printf '%s\n' "success" >"$scratch/sysctl/alert-repair-BridgeSelfTest-20260828T100200Z.result"
printf '%s\n' "inactive" >"$scratch/sysctl/alert-repair-BridgeSelfTest-20260828T100200Z.active"

# Seed a pre-existing laddered verify chain (no deadline marker).
mkdir -p "$scratch/state/open"
echo '{"age": 5000, "alertname": "BridgeSelfTest", "hop": "verify", "ladder": "stop-reason", "stall_count": 1}' >"$scratch/state/open/BridgeSelfTest.json"

# Tick 1: pre-existing drain sets verify_deadline_ts=now.
rc=$(run_bin "$now_ts")
[[ "$rc" == "0" ]] || fail "tick-1 drain rc=$rc"
state1=$(python3 -c "import json; print(json.dumps(json.load(open('$scratch/state/open/BridgeSelfTest.json')), sort_keys=True))")
echo "$state1" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'verify_deadline_ts' in d, d" \
  || fail "tick 1: must set verify_deadline_ts on pre-existing drained chain"

# Tick 2: deadline expired (tick1 set it to tick1's now, so tick2 is past).
rc=$(run_bin "2026-08-28T12:05:01Z")
[[ "$rc" == "0" ]] || fail "tick-2 deadline rc=$rc"

# The chain is no longer an OPEN verify chain — it is a cooldown marker
# (dead_until) on disk so a later tick does not re-open it. The glob below
# asserts every state file left in open/ carries dead_until.

# Must have a cooldown marker (dead_until).
mkdir -p "$scratch/state/open"  # just in case
(
  cd "$scratch/state/open"
  for f in *.json; do
    python3 -c "import json,sys; d=json.load(open('$f')); assert d.get('dead_until'), 'missing dead_until in '+str(d)"
  done
) || fail "cooldown state must have dead_until field"

# Ledger must have terminal=detector-red.
grep -q 'detector-red.*BridgeSelfTest' "$scratch/state/chains.terminated.jsonl" \
  || fail "ledger must contain terminal=detector-red for BridgeSelfTest"

# Verify metrics show 0 verify open/stalled.
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "fleet_chain_open verify must be 0 after deadline termination"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "fleet_chain_stalled verify must be 0 after deadline termination"

# Tick 3: cooldown active — chain must NOT be re-created.
rc=$(run_bin "2026-08-28T12:06:00Z")
[[ "$rc" == "0" ]] || fail "tick-3 cooldown rc=$rc"
# Verify is still 0 (no new chain).
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "verify open must stay 0 during cooldown"

ok "verify stall deadline → detector-red terminal + cooldown gate (fleet-ops#1577/#1610)"

# --- 9b. TWO concurrent verify-stall chains both drain (fleet-ops#1623) --
# #1623 is the "1.0 -> 2.0" re-fire of #1610: chain_stalled_total had TWO
# rows at hop=verify plane=alert-repair. This pins that exact twin shape:
# a fresh (never-laddered) verify stall, not the pre-existing-laddered drain
# path test 9 covers. Both must ladder on tick 1, then BOTH terminate as
# detector-red at the verify deadline so verify open/stalled return to 0.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"

# Two alertnames firing, both with a SUCCEEDED unit still firing -> verify-stall.
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "BridgeSelfTest"},
   "activeAt": "2026-08-28T10:00:00Z"},
  {"state": "firing", "labels": {"alertname": "VerifySink"},
   "activeAt": "2026-08-28T10:05:00Z"}
]}}, open(sys.argv[1], "w"))
PY

cat >"$scratch/actions.log" <<'PYEND'
[2026-08-28T10:02:00Z] DISPATCH alertname=BridgeSelfTest seat=a/Model unit=u-B-20260828T100200Z
[2026-08-28T10:07:00Z] DISPATCH alertname=VerifySink seat=a/Model unit=u-V-20260828T100700Z
PYEND
# Both repair units already SUCCEEDED; both alerts still firing -> verify-stall.
printf '%s\n' "success" >"$scratch/sysctl/u-B-20260828T100200Z.result"
printf '%s\n' "inactive" >"$scratch/sysctl/u-B-20260828T100200Z.active"
printf '%s\n' "success" >"$scratch/sysctl/u-V-20260828T100700Z.result"
printf '%s\n' "inactive" >"$scratch/sysctl/u-V-20260828T100700Z.active"

# Tick 1: both ladder (stop-reason) and set verify_deadline_ts.
rc=$(run_bin "2026-08-28T12:05:00Z")
[[ "$rc" == "0" ]] || fail "9b tick-1 rc=$rc stderr=$(cat "$scratch/err.log")"
for name in BridgeSelfTest VerifySink; do
  f="$scratch/state/open/$name.json"
  [[ -f "$f" ]] || fail "9b tick-1: missing open state for $name"
  python3 -c "import json,sys; d=json.load(open('$f')); \
    assert d.get('verify_deadline_ts'), d; assert d.get('hop')=='verify', d" \
    || fail "9b tick-1: $name must be laddered at verify with a deadline"
done
# The #1623 twin stall is visible: BOTH rows at hop=verify are stalled=2.
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 2' "$scratch/fleet-chains.prom" \
  || fail "9b tick-1: verify stalled must be 2 (twin #1623 shape), got: $(grep verify "$scratch/fleet-chains.prom")"

# Tick 2: now == deadline (12:05 + VERIFY_DEADLINE 60m) -> BOTH detector-red.
rc=$(run_bin "2026-08-28T13:05:00Z")
[[ "$rc" == "0" ]] || fail "9b tick-2 rc=$rc stderr=$(cat "$scratch/err.log")"

# Only cooldown markers remain in open/ (dead_until on each).
(
  cd "$scratch/state/open"
  for f in *.json; do
    python3 -c "import json,sys; d=json.load(open('$f')); \
      assert d.get('dead_until'), 'missing dead_until in '+str(d); \
      assert d.get('terminal')=='detector-red', d"
  done
) || fail "9b tick-2: both chains must be detector-red cooldown markers"

# Ledger: both closed detector-red.
grep -q 'BridgeSelfTest.*detector-red' "$scratch/state/chains.terminated.jsonl" \
  || fail "9b tick-2: BridgeSelfTest must be detector-red in ledger"
grep -q 'VerifySink.*detector-red' "$scratch/state/chains.terminated.jsonl" \
  || fail "9b tick-2: VerifySink must be detector-red in ledger"

# Both verify rows drained to 0. This is the issue's acceptance criterion:
# chain_stalled_total back to 0 with verify no longer holding either item.
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9b tick-2: fleet_chain_open verify must be 0, got: $(grep verify "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9b tick-2: fleet_chain_stalled verify must be 0, got: $(grep verify "$scratch/fleet-chains.prom")"

ok "two concurrent verify-stall chains both drain via deadline (fleet-ops#1623)"

# --- 9c. stale dispatch from prior green chain cleared on re-fire (fleet-ops#2100) --
# #2100 Bug A: FleetMainRed terminated green (start=00:16:09), then re-fired at
# 18:35:56. parse_actions still carried dispatch_ts=00:16:09 from the prior
# chain. classify's stale-resolve fallthrough did NOT clear it (resolved_ts was
# older than disp_ts), so the chain pinned to the dead unit at hop=verify with
# a huge age, cycling detector-red → cooldown → re-ladder forever. The fix: a
# dispatch can only belong to a trip firing at dispatch time; if the current
# fire started AFTER the dispatch and the unit is no longer running, the
# dispatch is stale → clear it → hop=dispatch → fresh worker.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal

# Prior chain: DISPATCH at 00:16:09, unit succeeded, alert left 9090 → green.
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-29T00:16:09Z] DISPATCH alertname=StaleDispatch seat=a/Model unit=u-SD-20260829T001609Z
PYEND
# The prior unit succeeded and --collect unloaded it (no state files = not-found).
# Seed a "Started" journal so unit_status's journal fallback sees it as success
# for the not-firing tick (proving the prior chain closes green).
printf 'Started u-SD-20260829T001609Z.service\n' >"$scratch/sysctl/u-SD-20260829T001609Z.journal"

# Tick 1: alert NOT firing, dispatch_ts=00:16:09, unit success → green terminal.
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": []}}, open(sys.argv[1], "w"))
PY
rc=$(run_bin "2026-08-29T00:32:44Z")
[[ "$rc" == "0" ]] || fail "9c tick-1 rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'StaleDispatch.*green' "$scratch/state/chains.terminated.jsonl" \
  || fail "9c tick-1: prior chain must terminate green, got: $(cat "$scratch/state/chains.terminated.jsonl")"

# Tick 2: alert RE-FIRED at 18:35:56. dispatch_ts is still 00:16:09 (stale).
# Before the fix: classify sees unit_success on the stale unit → hop=verify,
# age=67851s, stalled → ladders stop-reason, cycles forever.
# After the fix: disp_ts(00:16:09) < fire_start(18:35:56) and unit not running
# → disp_ts cleared → hop=dispatch → AMX redispatch for the fresh fire.
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "StaleDispatch"},
   "activeAt": "2026-08-29T18:35:56Z"}
]}}, open(sys.argv[1], "w"))
PY
rc=$(run_bin "2026-08-29T19:07:00Z")
[[ "$rc" == "0" ]] || fail "9c tick-2 rc=$rc stderr=$(cat "$scratch/err.log")"

# The chain must be at hop=dispatch (not verify), waiting for a fresh worker.
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 1' "$scratch/fleet-chains.prom" \
  || fail "9c tick-2: re-fire must be at hop=dispatch (stale disp cleared), got: $(grep -E 'hop="(dispatch|verify)"' "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9c tick-2: verify must be 0 (no stale unit pin), got: $(grep verify "$scratch/fleet-chains.prom")"

# The dispatcher must have been invoked for the re-fire (AMX redispatch).
grep -q "dispatch AMX_ALERT_1_LABEL_alertname=StaleDispatch" "$scratch/dispatch.log" \
  || fail "9c tick-2: dispatcher must be invoked for fresh dispatch, got: $(cat "$scratch/dispatch.log")"

ok "stale dispatch from prior green chain cleared on re-fire → hop=dispatch (fleet-ops#2100)"

# --- 9d. --collect failed unit not misclassified as verify success (fleet-ops#2100) --
# #2100 Bug B: FleetDeadCredentialSeats unit exited exit-code, but --collect
# unloaded it so systemctl show returned LoadState=not-found + Result=success
# (the default). unit_status returned ("success", "inactive"), classify saw
# unit_success → hop=verify, and the chain stalled at verify on a dead unit
# that actually FAILED. The fix: unit_status checks LoadState and falls back
# to the journal for not-found units (mirrors classify_dispatch #1295).
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal

# Current trip: alert firing, dispatched, unit FAILED and --collect unloaded.
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "FailedCollect"},
   "activeAt": "2026-08-29T17:20:34Z"}
]}}, open(sys.argv[1], "w"))
PY
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-29T17:25:44Z] DISPATCH alertname=FailedCollect seat=a/Model unit=u-FC-20260829T172544Z
PYEND
# No .result/.active files → LoadState=not-found, Result=success (default).
# Journal shows the real failure.
printf 'Main process exited, code=exited, status=1/FAILURE\nu-FC-20260829T172544Z.service: Failed with result exit-code.\n' \
  >"$scratch/sysctl/u-FC-20260829T172544Z.journal"

rc=$(run_bin "2026-08-29T19:07:00Z")
[[ "$rc" == "0" ]] || fail "9d rc=$rc stderr=$(cat "$scratch/err.log")"

# Before the fix: hop=verify (false success), stalled, ladder stop-reason.
# After the fix: unit_status sees LoadState=not-found + journal "Failed" →
# ("exit-code", "inactive") → not unit_success → hop=run → AMX redispatch.
grep -q 'fleet_chain_open{plane="alert-repair",hop="run"} 1' "$scratch/fleet-chains.prom" \
  || fail "9d: failed --collect unit must be hop=run (not verify), got: $(grep -E 'hop="(run|verify)"' "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9d: verify must be 0 (failed unit not misclassified as success), got: $(grep verify "$scratch/fleet-chains.prom")"

# The dispatcher must have been invoked (re-dispatch for the failed unit).
grep -q "dispatch AMX_ALERT_1_LABEL_alertname=FailedCollect" "$scratch/dispatch.log" \
  || fail "9d: dispatcher must re-dispatch the failed unit, got: $(cat "$scratch/dispatch.log")"

ok "--collect failed unit → hop=run via journal fallback, not verify false-success (fleet-ops#2100)"

# --- 9e. redispatch no-op at hop=dispatch escalates, not parks (fleet-ops#2247) --
# Bug: a dispatch/run redispatch returns rc=0 (the dispatcher spawned an async
# unit), and take_ladder parked the chain at ladder="redispatch" forever.
# Subsequent ticks returned "already" — no STOP-REASON, no senior-conference
# escalation — so FleetMainRed sat stuck through endless rc=0 redispatches
# that never turned main green. Fix: a STILL-stalled chain that was already
# redispatched fails loud (STOP-REASON) instead of returning "already".
# Two-tick repro: tick 1 redispatches (rc=0); tick 2 still firing -> escalate.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-30T02:25:56Z",
   "labels":{"alertname":"FleetMainRed"}}
]}}, open(sys.argv[1],"w"))
PY
# Tick 1: firing 20 min (02:25:56 -> 02:46:00) > 10 min CLOCK_DISPATCH, no
# DISPATCH -> hop=dispatch stalled -> redispatch rc=0 -> ladder="redispatch".
rc=$(run_bin "2026-08-30T02:46:00Z")
[[ "$rc" == "0" ]] || fail "9e tick-1 rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q "dispatch AMX_ALERT_1_LABEL_alertname=FleetMainRed" "$scratch/dispatch.log" \
  || fail "9e tick-1: dispatcher must be invoked for dispatch stall; log=$(cat "$scratch/dispatch.log")"
grep -q 'REDISPATCH alertname=FleetMainRed' "$scratch/actions.log" \
  || fail "9e tick-1: missing REDISPATCH receipt"
# Tick 1 must NOT have escalated yet (the redispatch gets a chance to run).
[[ -f "$scratch/STOP-REASON.json" ]] \
  && fail "9e tick-1: must not write STOP-REASON on first redispatch (give worker a chance)"
disp1=$(wc -l < "$scratch/dispatch.log")

# Tick 2: alert STILL firing (no DISPATCH line reached actions.log — the
# redispatched worker did not resolve the alert). hop=dispatch still stalled.
# Before the fix: take_ladder returned "already", no STOP-REASON, dispatcher
# NOT invoked again, chain stuck forever. After the fix: STOP-REASON written,
# senior-conference escalation, no second redispatch.
: >"$scratch/dispatch.log"   # reset to detect a (forbidden) second redispatch
rc=$(run_bin "2026-08-30T03:07:00Z")
[[ "$rc" == "0" ]] || fail "9e tick-2 rc=$rc stderr=$(cat "$scratch/err.log")"
[[ -f "$scratch/STOP-REASON.json" ]] \
  || fail "9e tick-2: redispatch no-op must write STOP-REASON (escalate, not park)"
python3 - "$scratch/STOP-REASON.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("reason") == "alert-repair-stalled", f"reason={d.get('reason')!r}"
assert d.get("detail", {}).get("alertname") == "FleetMainRed", d
PY
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "9e tick-2: must NOT redispatch again on a no-op (escalate instead); log=$(cat "$scratch/dispatch.log")"
fi
ok "redispatch no-op at hop=dispatch escalates via STOP-REASON, not parks (fleet-ops#2247)"

# --- 9f. redispatch no-op at hop=run escalates (fleet-ops#2247) ----------------
# Same class, hop=run: the redispatched unit died without resolving the alert.
# Seed a DISPATCH (as the real dispatcher writes to actions.log) with a dead
# unit old enough to stall at hop=run, plus prior ladder="redispatch" state.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-30T02:30:00Z] DISPATCH alertname=FleetMainRed seat=devin/glm-5-2 unit=alert-repair-FleetMainRed-20260830T0230Z reason=fallback packet=/x rc=0
PYEND
# Unit dead (no state files -> not-found -> not running, not success).
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-30T02:25:56Z",
   "labels":{"alertname":"FleetMainRed"}}
]}}, open(sys.argv[1],"w"))
PY
# Seed prior redispatch state (tick 1 already redispatched this chain).
mkdir -p "$scratch/state/open"
echo '{"alertname":"FleetMainRed","stall_count":1,"ladder":"redispatch","hop":"run"}' \
  >"$scratch/state/open/FleetMainRed.json"
# now=04:25:00 -> age since dispatch 02:30:00 = 6900s > 3600s CLOCK_RUN -> hop=run stalled.
rc=$(run_bin "2026-08-30T04:25:00Z")
[[ "$rc" == "0" ]] || fail "9f rc=$rc stderr=$(cat "$scratch/err.log")"
[[ -f "$scratch/STOP-REASON.json" ]] \
  || fail "9f: redispatch no-op at hop=run must write STOP-REASON (escalate, not park)"
python3 - "$scratch/STOP-REASON.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("reason") == "alert-repair-stalled", f"reason={d.get('reason')!r}"
assert d.get("detail", {}).get("hop") == "run", d
PY
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "9f: must NOT redispatch again on a no-op; log=$(cat "$scratch/dispatch.log")"
fi
ok "redispatch no-op at hop=run escalates via STOP-REASON, not parks (fleet-ops#2247)"

# --- 9g. escalated run chain terminates, does NOT park (fleet-ops#2367) ------
# This is the live incident shape: worker ran, delivered the designed
# non-zero EXIT CONTRACT verdict (unit failed while the alert still fires),
# the ladder reached STOP-REASON (senior conference owns it), and the chain
# sat PARKED at ladder=stop-reason exporting fleet_chain_stalled=1 forever.
# FleetChainStalled then fired for hours — a repair worker was dispatched for
# the rail, found the underlying alert unrepairable in-turn (genuine
# structural signal), exited non-zero (another failed unit), and nothing
# drained. Before the fix the parked chain never closed. After the fix the
# next stalled tick TERMINATES it as terminal=escalated (cooldown marker,
# excluded from open/stalled) — the same drain shape the verify-hop
# deadline close uses.
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"

# Alert still firing; a DISPATCH was made hours back; the unit FAILED and
# --collect unloaded it (journal shows the real failure).
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "FleetSloMainGreenSlowBurn"},
   "activeAt": "2026-08-30T05:27:33Z"}
]}}, open(sys.argv[1], "w"))
PY
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-30T07:00:11Z] DISPATCH alertname=FleetSloMainGreenSlowBurn seat=commandcode/poolside/laguna-s-2.1-free unit=u-SLO-20260830T070011Z reason=healthy packet=/x rc=0
PYEND
printf 'Main process exited, code=exited, status=1/FAILURE\nu-SLO-20260830T070011Z.service: Failed with result exit-code.\n' \
  >"$scratch/sysctl/u-SLO-20260830T070011Z.journal"

# Seed the parked chain exactly as the live incident left it.
mkdir -p "$scratch/state/open"
echo '{"age": 15000, "alertname": "FleetSloMainGreenSlowBurn", "hop": "run", "ladder": "stop-reason", "stall_count": 2}' \
  >"$scratch/state/open/FleetSloMainGreenSlowBurn.json"

# Tick 1 (well past CLOCK_RUN): the parked chain must TERMINATE.
rc=$(run_bin "2026-08-30T11:22:19Z")
[[ "$rc" == "0" ]] || fail "9g tick-1 rc=$rc stderr=$(cat "$scratch/err.log")"

# Ledger must carry terminal=escalated.
grep -q 'FleetSloMainGreenSlowBurn.*"terminal": "escalated"' "$scratch/state/chains.terminated.jsonl" \
  || fail "9g tick-1: ledger must contain terminal=escalated for FleetSloMainGreenSlowBurn; got: $(cat "$scratch/state/chains.terminated.jsonl")"

# State on disk must be the cooldown marker, not the parked chain.
(
  cd "$scratch/state/open"
  for f in *.json; do
    python3 -c "import json,sys; d=json.load(open('$f')); \
      assert d.get('dead_until'), 'missing dead_until in '+str(d); \
      assert d.get('terminal')=='escalated', d" \
      || fail "9g tick-1: parked chain must become an escalated cooldown marker"
  done
)

# The run hop must drain this tick (the issue's acceptance criterion).
grep -q 'fleet_chain_open{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "9g tick-1: run open must be 0 after escalated termination, got: $(grep run "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "9g tick-1: run stalled must be 0 after escalated termination, got: $(grep run "$scratch/fleet-chains.prom")"

# No dispatcher invocation (the escalation is terminal — no re-dispatch).
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
  fail "9g tick-1: escalated chain must NOT re-dispatch; log=$(cat "$scratch/dispatch.log")"
fi

# Tick 2 (cooldown active): the chain must NOT re-create.
rc=$(run_bin "2026-08-30T11:23:00Z")
[[ "$rc" == "0" ]] || fail "9g tick-2 rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "9g tick-2: run open must stay 0 during cooldown, got: $(grep run "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="run"} 0' "$scratch/fleet-chains.prom" \
  || fail "9g tick-2: run stalled must stay 0 during cooldown, got: $(grep run "$scratch/fleet-chains.prom")"

ok "escalated run chain terminates (terminal=escalated + cooldown), rail drains (fleet-ops#2367)"

# --- 9h. laddered verify chain re-open re-parks, does NOT re-ladder (fleet-ops#2397) --
# Live incident: FleetQueueSelfMaintenanceRatioHigh's repair unit exited
# non-zero (EXIT CONTRACT) but --collect unloaded it, so unit_status saw
# LoadState=not-found + a Started-only journal and misread it as SUCCESS →
# hop=verify. The verify stall laddered (STOP-REASON + REDISPATCH-log), then
# closed detector-red at the verify deadline. When that cooldown expired the
# SAME dispatch unit re-opened and RE-LADDERED (fresh STOP-REASON, fresh
# REDISPATCH), so the verify hop sat open past its cycle budget forever
# (re-ladder every cooldown, alive 13:07Z → 14:22Z → auditor hand-park).
# Fix: the terminal close persists the ladder marker + dispatch_unit; a
# re-open of the same unit re-parks (extends cooldown, stays drained, no
# new STOP-REASON, no REDISPATCH).
rm -rf "$scratch/state"; mkdir -p "$scratch/state"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal
: >"$scratch/dispatch.log"
rm -f "$scratch/STOP-REASON.json"

# Alert STILL firing; DISPATCH made long ago; unit --collect unloaded with a
# Started-only journal → unit_status journal fallback reads it as SUCCESS →
# classify = hop=verify stalled (the verify shape #1610 targets).
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "VerifyLoop"},
   "activeAt": "2026-08-30T11:10:27Z"}
]}}, open(sys.argv[1], "w"))
PY
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-30T11:10:27Z] DISPATCH alertname=VerifyLoop seat=a/Model unit=u-VL-20260830T111027Z
PYEND
printf 'Started u-VL-20260830T111027Z.service\n' >"$scratch/sysctl/u-VL-20260830T111027Z.service.journal"

# Seed the EXACT terminal marker the fixed close writes: ladder=stop-reason,
# terminal=detector-red, dead_until already EXPIRED, dispatch_unit == the
# current dispatch's unit (this is the re-open the old code re-laddered).
mkdir -p "$scratch/state/open"
echo '{"alertname":"VerifyLoop","hop":"verify","terminal":"detector-red","ladder":"stop-reason","stall_count":2,"dead_until":"2026-08-30T14:00:00Z","dispatch_unit":"u-VL-20260830T111027Z"}' \
  >"$scratch/state/open/VerifyLoop.json"

# Tick 1 (well past the expired cooldown): must RE-PARK, not re-ladder.
rc=$(run_bin "2026-08-30T16:00:00Z")
[[ "$rc" == "0" ]] || fail "9h tick-1 rc=$rc stderr=$(cat "$scratch/err.log")"

# No new REDISPATCH receipt (the ladder writes one each re-ladder).
if grep -q 'REDISPATCH alertname=VerifyLoop' "$scratch/actions.log" \
   || grep -q -i 'VerifyLoop' "$scratch/redispatch.log" 2>/dev/null; then
  fail "9h tick-1: re-open must NOT re-ladder/spawn, got: $(grep -i verifyloop "$scratch/actions.log" "$scratch/redispatch.log" 2>/dev/null)"
fi
# No new STOP-REASON write (the escalation was already handed to the senior
# conference on the original ladder — re-summoning is the bug).
[[ -f "$scratch/STOP-REASON.json" ]] \
  && fail "9h tick-1: re-open must NOT write a new STOP-REASON"
# The chain must be re-parked: dead_until slid forward, terminal marker intact.
python3 - "$scratch/state/open/VerifyLoop.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("dead_until") == "2026-08-30T17:00:00Z", d.get("dead_until")
assert d.get("terminal") == "detector-red", d
assert d.get("ladder") == "stop-reason", d
assert d.get("dispatch_unit") == "u-VL-20260830T111027Z", d
PY
# The rail must stay drained: verify open/stalled 0 (the parked chain is not
# an open/stalled chain on the re-open tick).
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9h tick-1: verify open must be 0 (re-parked), got: $(grep verify "$scratch/fleet-chains.prom")"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9h tick-1: verify stalled must be 0 (re-parked), got: $(grep verify "$scratch/fleet-chains.prom")"

# Tick 2 (within the new cooldown): still drained, no STOP-REASON.
rc=$(run_bin "2026-08-30T16:30:00Z")
[[ "$rc" == "0" ]] || fail "9h tick-2 rc=$rc stderr=$(cat "$scratch/err.log")"
[[ -f "$scratch/STOP-REASON.json" ]] \
  && fail "9h tick-2: cooldown must stay quiet (no new STOP-REASON)"
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9h tick-2: verify stalled must stay 0 during re-park"

# Tick 3: a FRESH dispatch unit for the same alertname must NOT be parked —
# the marker belongs to the old unit; the new dispatch opens a clean chain
# that takes the normal ladder (this is the incident's recovery path).
python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "VerifyLoop"},
   "activeAt": "2026-08-30T11:10:27Z"}
]}}, open(sys.argv[1], "w"))
PY
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-30T11:10:27Z] DISPATCH alertname=VerifyLoop seat=a/Model unit=u-VL-20260830T111027Z
[2026-08-30T17:00:00Z] DISPATCH alertname=VerifyLoop seat=b/Model2 unit=u-VL-20260830T170000Z
PYEND
printf 'Started u-VL-20260830T170000Z.service\n' >"$scratch/sysctl/u-VL-20260830T170000Z.service.journal"
rc=$(run_bin "2026-08-30T17:30:00Z")
[[ "$rc" == "0" ]] || fail "9h tick-3 rc=$rc stderr=$(cat "$scratch/err.log")"
# The new chain must be counted (not parked): verify open=1 with the fresh
# unit's dispatch.
python3 - "$scratch/state/open/VerifyLoop.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("dispatch_unit") == "u-VL-20260830T170000Z", d.get("dispatch_unit")
assert d.get("dead_until") in (None, ""), d
assert d.get("terminal") in (None, ""), d
PY
grep -q 'fleet_chain_open{plane="alert-repair",hop="verify"} 1' "$scratch/fleet-chains.prom" \
  || fail "9h tick-3: fresh dispatch must open verify=1, got: $(grep verify "$scratch/fleet-chains.prom")"

ok "laddered verify chain re-open re-parks, fresh dispatch re-opens (fleet-ops#2397)"

# --- 9i. LEGACY terminal marker WITHOUT dispatch_unit re-parks (fleet-ops#2397) --
# The live incident marker was auditor-hand-parked with NO dispatch_unit
# (FleetQueueSelfMaintenanceRatioHigh, dead_until=20:29:41Z, ladder=
# stop-reason, terminal=detector-red — written before the fix persisted the
# unit). When its cooldown expires the re-park guard must still fire (the
# `not existing.get("dispatch_unit")` branch): the escalation owns the chain;
# a unit-less legacy marker must NOT re-ladder just because it cannot name
# its own unit.
rm -rf "$scratch/state"; mkdir -p "$scratch/state/open"
rm -f "$scratch/sysctl"/*.result "$scratch/sysctl"/*.active "$scratch/sysctl"/*.journal
: >"$scratch/dispatch.log"
rm -f "$scratch/STOP-REASON.json"

python3 - "$scratch/alerts.json" <<'PY'
import json, sys
json.dump({"status": "success", "data": {"alerts": [
  {"state": "firing", "labels": {"alertname": "VerifyLoop2"},
   "activeAt": "2026-08-30T11:10:27Z"}
]}}, open(sys.argv[1], "w"))
PY
cat >"$scratch/actions.log" <<'PYEND'
[2026-08-30T11:10:27Z] DISPATCH alertname=VerifyLoop2 seat=a/Model unit=u-VL2-20260830T111027Z
PYEND
printf 'Started u-VL2-20260830T111027Z.service\n' >"$scratch/sysctl/u-VL2-20260830T111027Z.service.journal"

# Byte-accurate live shape: NO dispatch_unit, no stall_count beyond legacy
# marker content, expired dead_until.
echo '{"alertname":"VerifyLoop2","hop":"verify","terminal":"detector-red","ladder":"stop-reason","dead_until":"2026-08-30T14:00:00Z"}' \
  >"$scratch/state/open/VerifyLoop2.json"

rc=$(run_bin "2026-08-30T16:00:00Z")
[[ "$rc" == "0" ]] || fail "9i rc=$rc stderr=$(cat "$scratch/err.log")"
if grep -q 'REDISPATCH alertname=VerifyLoop2' "$scratch/actions.log" \
   || grep -q -i 'VerifyLoop2' "$scratch/redispatch.log" 2>/dev/null; then
  fail "9i: unit-less legacy marker must NOT re-ladder/spawn, got: $(grep -i verifyloop2 "$scratch/actions.log" "$scratch/redispatch.log" 2>/dev/null)"
fi
[[ -f "$scratch/STOP-REASON.json" ]] \
  && fail "9i: unit-less legacy marker must NOT write a new STOP-REASON"
python3 - "$scratch/state/open/VerifyLoop2.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("dead_until") == "2026-08-30T17:00:00Z", d.get("dead_until")
assert d.get("terminal") == "detector-red", d
assert d.get("ladder") == "stop-reason", d
assert d.get("dispatch_unit") == "u-VL2-20260830T111027Z", d  # unit backfilled
PY
grep -q 'fleet_chain_stalled{plane="alert-repair",hop="verify"} 0' "$scratch/fleet-chains.prom" \
  || fail "9i: verify stalled must be 0 (unit-less legacy marker), got: $(grep verify "$scratch/fleet-chains.prom")"

ok "unit-less legacy terminal marker re-parks, no re-ladder (fleet-ops#2397)"

# ============================================================================
# Dispatch plane (fleet-ops#1009)
# ============================================================================
# Helper: write one open dispatch-ledger entry to a given ledger path.
write_dispatch_entry() {
  local ledger="$1" id="$2" chain="$3" hop="$4" unit="$5" pkt="$6" retries="$7" ts="$8" deadline_ts="$9"
  python3 -c "
import json, sys
entry = {
    'id': sys.argv[1], 'chain_id': sys.argv[2], 'hop': int(sys.argv[3]),
    'ts': sys.argv[4], 'unit': sys.argv[5], 'packet_path': sys.argv[6],
    'provider': 'devin', 'model': 'glm-5-2',
    'deadline_min': 5, 'deadline_ts': sys.argv[7],
    'status': 'open', 'retries': int(sys.argv[8]),
}
print(json.dumps(entry))
" "$id" "$chain" "$hop" "$ts" "$unit" "$pkt" "$deadline_ts" "$retries" \
    >>"$ledger"
}

# --- 10. orphan past deadline, retries < 2 → re-dispatch -------------------
scratch2="$(mktemp -d -t dispatch-canary.XXXXXX)"
# Reuse the same fakes by symlinking.
ln -s "$scratch/systemctl" "$scratch2/systemctl"
ln -s "$scratch/journalctl" "$scratch2/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch2/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch2/dispatcher"
mkdir -p "$scratch2/sysctl" "$scratch2/as/dispatch-packets"

pkt10="$scratch2/as/dispatch-packets/synth-10.md"
echo "synthetic packet 10" > "$pkt10"
: > "$scratch2/dispatch-ledger.jsonl"
: > "$scratch2/redispatch.log"

write_dispatch_entry "$scratch2/dispatch-ledger.jsonl" "id-10" "chain-10" 0 "synth-10" "$pkt10" 0 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch2/as" \
FLEET_COMPLETION_STATE="$scratch2/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch2/actions.log" \
FLEET_COMPLETION_PROM="$scratch2/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch2/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch2/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch2/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch2/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch2/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch2/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch2/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch2/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch2/sysctl" \
DISPATCH_LOG="$scratch2/dispatch.log" \
REDISPATCH_LOG="$scratch2/redispatch.log" \
HOME="$scratch2" \
  python3 "$bin" >/dev/null 2>"$scratch2/err.log"
rc10=$?
set -e
[[ "$rc10" == "0" ]] || fail "dispatch test 10 rc=$rc10"

# Re-dispatch must have been called with --chain-id chain-10 --hop 1.
grep -q -- "--chain-id chain-10" "$scratch2/redispatch.log" \
  || fail "redispatch must pass --chain-id chain-10"
grep -q -- "--hop 1" "$scratch2/redispatch.log" \
  || fail "redispatch must pass --hop 1"
grep -q -- "--stdin $pkt10" "$scratch2/redispatch.log" \
  || fail "redispatch must re-issue the SAME packet file"

# Ledger must have a closing line with status=redispatched.
tail -1 "$scratch2/dispatch-ledger.jsonl" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert d['status']=='redispatched', d; assert d['new_unit']=='synth-10-r1', d" \
  || fail "ledger must close with status=redispatched and new_unit=synth-10-r1"

ok "dispatch plane: orphan past deadline → re-dispatch with chain-id/hop+1 (fleet-ops#1009)"

# --- 11. orphan past deadline, retries >= 2 → STOP-REASON ------------------
scratch3="$(mktemp -d -t dispatch-canary3.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch3/systemctl"
ln -s "$scratch/journalctl" "$scratch3/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch3/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch3/dispatcher"
mkdir -p "$scratch3/sysctl" "$scratch3/as/dispatch-packets"

pkt11="$scratch3/as/dispatch-packets/synth-11.md"
echo "synthetic packet 11" > "$pkt11"
: > "$scratch3/dispatch-ledger.jsonl"
: > "$scratch3/redispatch.log"

write_dispatch_entry "$scratch3/dispatch-ledger.jsonl" "id-11" "chain-11" 2 "synth-11" "$pkt11" 2 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch3/as" \
FLEET_COMPLETION_STATE="$scratch3/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch3/actions.log" \
FLEET_COMPLETION_PROM="$scratch3/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch3/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch3/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch3/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch3/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch3/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch3/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch3/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch3/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch3/sysctl" \
DISPATCH_LOG="$scratch3/dispatch.log" \
REDISPATCH_LOG="$scratch3/redispatch.log" \
HOME="$scratch3" \
  python3 "$bin" >/dev/null 2>"$scratch3/err.log"
rc11=$?
set -e
[[ "$rc11" == "0" ]] || fail "dispatch test 11 rc=$rc11"

# STOP-REASON must be dispatch-orphan.
python3 -c \
  "import json; d=json.load(open('$scratch3/STOP-REASON.json')); assert d['reason']=='dispatch-orphan', d; assert d['detail']['retries']==2, d" \
  || fail "STOP-REASON must be dispatch-orphan with retries=2"

# No re-dispatch must have happened.
[[ ! -s "$scratch3/redispatch.log" ]] \
  || fail "redispatch must NOT be called when retries >= 2"

# Ledger must have status=escalated.
tail -1 "$scratch3/dispatch-ledger.jsonl" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert d['status']=='escalated', d" \
  || fail "ledger must close with status=escalated"

ok "dispatch plane: retries >= 2 → STOP-REASON dispatch-orphan, no re-dispatch (fleet-ops#1009)"

# --- 12. completed-success (journal) → close green -------------------------
scratch4="$(mktemp -d -t dispatch-canary4.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch4/systemctl"
ln -s "$scratch/journalctl" "$scratch4/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch4/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch4/dispatcher"
mkdir -p "$scratch4/sysctl" "$scratch4/as/dispatch-packets"

pkt12="$scratch4/as/dispatch-packets/synth-12.md"
echo "synthetic packet 12" > "$pkt12"
: > "$scratch4/dispatch-ledger.jsonl"
: > "$scratch4/redispatch.log"

# No systemctl state files → LoadState=not-found. Journal says Succeeded.
echo "Succeeded" > "$scratch4/sysctl/synth-12.service.journal"

write_dispatch_entry "$scratch4/dispatch-ledger.jsonl" "id-12" "chain-12" 0 "synth-12" "$pkt12" 0 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch4/as" \
FLEET_COMPLETION_STATE="$scratch4/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch4/actions.log" \
FLEET_COMPLETION_PROM="$scratch4/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch4/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch4/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch4/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch4/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch4/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch4/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch4/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch4/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch4/sysctl" \
DISPATCH_LOG="$scratch4/dispatch.log" \
REDISPATCH_LOG="$scratch4/redispatch.log" \
HOME="$scratch4" \
  python3 "$bin" >/dev/null 2>"$scratch4/err.log"
rc12=$?
set -e
[[ "$rc12" == "0" ]] || fail "dispatch test 12 rc=$rc12"

# Ledger must have status=completed, verdict=success.
tail -1 "$scratch4/dispatch-ledger.jsonl" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert d['status']=='completed', d; assert d['verdict']=='success', d" \
  || fail "ledger must close with status=completed verdict=success"

# No re-dispatch.
[[ ! -s "$scratch4/redispatch.log" ]] \
  || fail "redispatch must NOT be called on completed-success"

ok "dispatch plane: completed-success (journal) → close green (fleet-ops#1009)"

# --- 13. in-flight (active) → leave open -----------------------------------
scratch5="$(mktemp -d -t dispatch-canary5.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch5/systemctl"
ln -s "$scratch/journalctl" "$scratch5/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch5/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch5/dispatcher"
mkdir -p "$scratch5/sysctl" "$scratch5/as/dispatch-packets"

pkt13="$scratch5/as/dispatch-packets/synth-13.md"
echo "synthetic packet 13" > "$pkt13"
: > "$scratch5/dispatch-ledger.jsonl"
: > "$scratch5/redispatch.log"

# Unit is active → LoadState=loaded, ActiveState=active.
echo "success" > "$scratch5/sysctl/synth-13.service.result"
echo "active" > "$scratch5/sysctl/synth-13.service.active"

write_dispatch_entry "$scratch5/dispatch-ledger.jsonl" "id-13" "chain-13" 0 "synth-13" "$pkt13" 0 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch5/as" \
FLEET_COMPLETION_STATE="$scratch5/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch5/actions.log" \
FLEET_COMPLETION_PROM="$scratch5/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch5/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch5/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch5/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch5/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch5/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch5/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch5/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch5/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch5/sysctl" \
DISPATCH_LOG="$scratch5/dispatch.log" \
REDISPATCH_LOG="$scratch5/redispatch.log" \
HOME="$scratch5" \
  python3 "$bin" >/dev/null 2>"$scratch5/err.log"
rc13=$?
set -e
[[ "$rc13" == "0" ]] || fail "dispatch test 13 rc=$rc13"

# Ledger must still be 1 line (left open).
lines13=$(wc -l < "$scratch5/dispatch-ledger.jsonl")
[[ "$lines13" == "1" ]] || fail "in-flight must leave ledger at 1 line, got $lines13"

# No re-dispatch.
[[ ! -s "$scratch5/redispatch.log" ]] \
  || fail "redispatch must NOT be called on in-flight"

# Metrics: dispatch open=1, stalled=0.
grep -q 'fleet_chain_open{plane="dispatch",hop="run"} 1' "$scratch5/fleet-chains.prom" \
  || fail "dispatch open must be 1 for in-flight"
grep -q 'fleet_chain_stalled{plane="dispatch",hop="run"} 0' "$scratch5/fleet-chains.prom" \
  || fail "dispatch stalled must be 0 for in-flight"

ok "dispatch plane: in-flight (active) → leave open (fleet-ops#1009)"

# --- 14. orphan before deadline → waiting ----------------------------------
scratch6="$(mktemp -d -t dispatch-canary6.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch6/systemctl"
ln -s "$scratch/journalctl" "$scratch6/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch6/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch6/dispatcher"
mkdir -p "$scratch6/sysctl" "$scratch6/as/dispatch-packets"

pkt14="$scratch6/as/dispatch-packets/synth-14.md"
echo "synthetic packet 14" > "$pkt14"
: > "$scratch6/dispatch-ledger.jsonl"
: > "$scratch6/redispatch.log"

# No state files → orphan. But deadline is in the FUTURE.
write_dispatch_entry "$scratch6/dispatch-ledger.jsonl" "id-14" "chain-14" 0 "synth-14" "$pkt14" 0 \
    "2026-08-29T00:58:00Z" "2026-08-29T01:03:00Z"

set +e
AGENT_STATE="$scratch6/as" \
FLEET_COMPLETION_STATE="$scratch6/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch6/actions.log" \
FLEET_COMPLETION_PROM="$scratch6/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch6/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch6/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch6/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch6/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch6/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch6/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch6/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch6/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch6/sysctl" \
DISPATCH_LOG="$scratch6/dispatch.log" \
REDISPATCH_LOG="$scratch6/redispatch.log" \
HOME="$scratch6" \
  python3 "$bin" >/dev/null 2>"$scratch6/err.log"
rc14=$?
set -e
[[ "$rc14" == "0" ]] || fail "dispatch test 14 rc=$rc14"

# Ledger must still be 1 line (waiting, not closed).
lines14=$(wc -l < "$scratch6/dispatch-ledger.jsonl")
[[ "$lines14" == "1" ]] || fail "waiting must leave ledger at 1 line, got $lines14"

# --- 15. --collect unit, journal has "Started" but no "Succeeded"/"Failed" -> completed-success (fleet-ops#1295) ----
scratch7="$(mktemp -d -t dispatch-canary7.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch7/systemctl"
ln -s "$scratch/journalctl" "$scratch7/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch7/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch7/dispatcher"
mkdir -p "$scratch7/sysctl" "$scratch7/as/dispatch-packets"

pkt15="$scratch7/as/dispatch-packets/synth-15.md"
echo "synthetic packet 15" > "$pkt15"
: > "$scratch7/dispatch-ledger.jsonl"
: > "$scratch7/redispatch.log"

# No state files -> LoadState=not-found (simulate a --collect unit that exited).
# Journal has "Started" but NO "Succeeded" and NO "Failed" -- the gap (fleet-ops#1295).
echo "Started synth-15.service - Synthetic test unit." > "$scratch7/sysctl/synth-15.service.journal"

write_dispatch_entry "$scratch7/dispatch-ledger.jsonl" "id-15" "chain-15" 0 "synth-15" "$pkt15" 0 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch7/as" \
FLEET_COMPLETION_STATE="$scratch7/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch7/actions.log" \
FLEET_COMPLETION_PROM="$scratch7/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch7/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch7/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch7/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch7/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch7/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch7/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch7/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch7/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch7/sysctl" \
DISPATCH_LOG="$scratch7/dispatch.log" \
REDISPATCH_LOG="$scratch7/redispatch.log" \
HOME="$scratch7" \
  python3 "$bin" >/dev/null 2>"$scratch7/err.log"
rc15=$?
set -e
[[ "$rc15" == "0" ]] || fail "dispatch test 15 rc=$rc15 stderr=$(cat "$scratch7/err.log")"

# Before the fix: the unit would be orphaned and left open (waiting past deadline
# -> re-dispatch or escalation). After the fix: journal_has_started detects the
# "Started" line and classifies as completed-success -> ledger closed, no re-dispatch.
tail -1 "$scratch7/dispatch-ledger.jsonl" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert d['status']=='completed', d; assert d['verdict']=='success', d" \
  || fail "ledger must close with status=completed verdict=success (not orphaned/re-dispatched); stderr=$(cat "$scratch7/err.log")"

# No re-dispatch must have happened (unit completed, not orphaned).
[[ ! -s "$scratch7/redispatch.log" ]] \
  || fail "redispatch must NOT be called on a completed --collect unit (fleet-ops#1295)"

# No STOP-REASON must have been written.
[[ ! -f "$scratch7/STOP-REASON.json" ]] \
  || fail "STOP-REASON must NOT be written for a completed unit"

# Metrics: dispatch open must be 0 (the only open dispatch entry was closed).
grep -q 'fleet_chain_open{plane="dispatch",hop="run"} 0' "$scratch7/fleet-chains.prom" \
  || fail "dispatch open must be 0 after closing the --collect success entry"

ok "dispatch plane: --collect unit with Started-only journal -> completed-success, not orphaned (fleet-ops#1295)"

# Cleanup dispatch-plane scratch dirs.
rm -rf "$scratch2" "$scratch3" "$scratch4" "$scratch5" "$scratch6" "$scratch7"

# --- 16. --collect unit, verbose journal hides "Started" past the -n 20 window -> completed-success (fleet-ops#2414) ----
# Live fleet-ops#2414: two alert-repair units (SystemUnitFailed, FleetSloMainGreenSlowBurn)
# dispatched at 15:37/15:38Z really ran to completion (journal shows
# PACKET-VERDICT class=worked + RESOLVED receipts) but their dispatch-ledger
# entries stayed open until the 90-min deadline. The unit journals were 24 lines
# and the systemd "Started" line is ALWAYS the first entry, so journal_text's
# -n 20 window hid it: journal_has_started returned False -> classified orphan ->
# re-dispatched the SAME packet at 17:22Z (duplicate repair work) ->
# fleet_chain_stalled{plane=dispatch,hop=run}=2.0 -> FleetChainStalled critical.
# The fix: journal_started greps the FULL journal for the exact start marker.
scratch16="$(mktemp -d -t dispatch-canary16.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch16/systemctl"
ln -s "$scratch/journalctl" "$scratch16/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch16/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch16/dispatcher"
mkdir -p "$scratch16/sysctl" "$scratch16/as/dispatch-packets"

pkt16="$scratch16/as/dispatch-packets/synth-16.md"
echo "synthetic packet 16" > "$pkt16"
: > "$scratch16/dispatch-ledger.jsonl"
: > "$scratch16/redispatch.log"

# No state files -> LoadState=not-found (--collect unit that exited). Journal has
# "Started" at line 1 followed by a verbose 24-line transcript and NO
# "Succeeded"/"Failed" summary (suppressed on --collect unload) — the exact
# live shape where -n 20 drops the start marker.
{
  echo "Started synth-16.service - Pi packet synth-16 (session-independent)."
  for i in $(seq 1 24); do
    echo "pi packet verbose transcript line $i"
  done
} > "$scratch16/sysctl/synth-16.service.journal"

write_dispatch_entry "$scratch16/dispatch-ledger.jsonl" "id-16" "chain-16" 0 "synth-16" "$pkt16" 0 \
    "2026-08-29T00:00:00Z" "2026-08-29T00:05:00Z"

set +e
AGENT_STATE="$scratch16/as" \
FLEET_COMPLETION_STATE="$scratch16/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch16/actions.log" \
FLEET_COMPLETION_PROM="$scratch16/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch16/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch16/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch16/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch16/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch16/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch16/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch16/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch16/triage.md" \
FLEET_COMPLETION_NOW="2026-08-29T01:00:00Z" \
SYSCTL_STORE="$scratch16/sysctl" \
DISPATCH_LOG="$scratch16/dispatch.log" \
REDISPATCH_LOG="$scratch16/redispatch.log" \
HOME="$scratch16" \
  python3 "$bin" >/dev/null 2>"$scratch16/err.log"
rc16=$?
set -e
[[ "$rc16" == "0" ]] || fail "dispatch test 16 rc=$rc16 stderr=$(cat "$scratch16/err.log")"

# Before the fix: the verbose journal hides "Started", the unit is orphaned and
# past deadline -> re-dispatch of the SAME packet. After the fix: journal_started
# finds the marker in the full journal -> completed-success, no re-dispatch.
tail -1 "$scratch16/dispatch-ledger.jsonl" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); assert d['status']=='completed', d; assert d['verdict']=='success', d" \
  || fail "ledger must close with status=completed verdict=success despite verbose journal (fleet-ops#2414); stderr=$(cat "$scratch16/err.log")"

# No re-dispatch must have happened (the unit completed; the packet is not stale).
[[ ! -s "$scratch16/redispatch.log" ]] \
  || fail "redispatch must NOT be called on a completed --collect unit with a verbose journal (fleet-ops#2414)"

# No STOP-REASON must have been written.
[[ ! -f "$scratch16/STOP-REASON.json" ]] \
  || fail "STOP-REASON must NOT be written for a completed unit"

# Metrics: dispatch stalled must be 0 (no orphan re-dispatch/escalation this tick).
grep -q 'fleet_chain_stalled{plane="dispatch",hop="run"} 0' "$scratch16/fleet-chains.prom" \
  || fail "dispatch stalled must be 0 (completed unit closed, not re-dispatched); got: $(grep -E 'dispatch.*stalled|stalled.*dispatch' "$scratch16/fleet-chains.prom")"

ok "dispatch plane: verbose --collect journal (Started hidden by -n 20) -> completed-success, no redispatch (fleet-ops#2414)"

rm -rf "$scratch16"


# ============================================================================
# Issue-close evidence check (fleet-ops#1527)
# ============================================================================
# Fake gh for issue evidence tests
cat >"$scratch/gh" <<'GHFAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  issue)
    subcmd="$1"; shift
    case "$subcmd" in
      list)
        # Parse args to find repo and flags
        repo=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        # Return mock closed issues
        if [[ "$repo" == "Nishfleet/fleet-ops" ]]; then
          cat <<'JSON'
[
  {"number": 1001, "title": "Issue with PR evidence", "closedAt": "2026-08-28T10:00:00Z", "closedByPullRequestsReferences": [{"number": 1002}]},
  {"number": 1003, "title": "Issue without evidence", "closedAt": "2026-08-28T11:00:00Z", "closedByPullRequestsReferences": []},
  {"number": 1004, "title": "Old issue outside lookback", "closedAt": "2026-08-20T10:00:00Z", "closedByPullRequestsReferences": []}
]
JSON
        elif [[ "$repo" == "Nishfleet/0509" ]]; then
          cat <<'JSON'
[
  {"number": 2001, "title": "0509 issue with PR", "closedAt": "2026-08-28T12:00:00Z", "closedByPullRequestsReferences": [{"number": 2002}]}
]
JSON
        else
          echo '[]'
        fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    # Mock commit search - return empty for issue 1003 (no commit evidence)
    # Return a commit for other issues if needed
    if [[ "$*" == *"1003"* ]]; then
      echo ''
    else
      echo 'abc123'
    fi
    ;;
  *) exit 1 ;;
esac
GHFAKE
chmod +x "$scratch/gh"

# Test 16: Issue evidence check - issues without PR/commit evidence are flagged
scratch16="$(mktemp -d -t evidence-test.XXXXXX)"
ln -s "$scratch/systemctl" "$scratch16/systemctl"
ln -s "$scratch/journalctl" "$scratch16/journalctl"
ln -s "$scratch/pi-systemd-run" "$scratch16/pi-systemd-run"
ln -s "$scratch/dispatcher" "$scratch16/dispatcher"
ln -s "$scratch/gh" "$scratch16/gh"
mkdir -p "$scratch16/sysctl" "$scratch16/as" "$scratch16/state"
: > "$scratch16/actions.log"
: > "$scratch16/dispatch.log"
write_alerts <<<'[]'

set +e
AGENT_STATE="$scratch16/as" \
FLEET_COMPLETION_STATE="$scratch16/state" \
FLEET_COMPLETION_ACTIONS_LOG="$scratch16/actions.log" \
FLEET_COMPLETION_PROM="$scratch16/fleet-chains.prom" \
FLEET_COMPLETION_ALERTS_JSON="$scratch16/alerts.json" \
FLEET_COMPLETION_DISPATCHER="$scratch16/dispatcher" \
FLEET_COMPLETION_SYSTEMCTL="$scratch16/systemctl" \
FLEET_COMPLETION_JOURNALCTL="$scratch16/journalctl" \
FLEET_COMPLETION_PI_SYSTEMD_RUN="$scratch16/pi-systemd-run" \
FLEET_DISPATCH_LEDGER="$scratch16/dispatch-ledger.jsonl" \
FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
FLEET_STOP_REASON="$scratch16/STOP-REASON.json" \
FLEET_COMPLETION_TRIAGE="$scratch16/triage.md" \
FLEET_COMPLETION_NOW="2026-08-28T13:00:00Z" \
FLEET_COMPLETION_ISSUE_EVIDENCE_LOOKBACK_HOURS="24" \
FLEET_COMPLETION_ISSUE_EVIDENCE_REPOS_FILE="$repo_root/config/intake-repos.json" \
SYSCTL_STORE="$scratch16/sysctl" \
DISPATCH_LOG="$scratch16/dispatch.log" \
REDISPATCH_LOG="$scratch16/redispatch.log" \
PATH="$scratch:$PATH" \
HOME="$scratch16" \
  python3 "$bin" >/dev/null 2>"$scratch16/err.log"
rc16=$?
set -e
[[ "$rc16" == "0" ]] || fail "evidence test 16 rc=$rc16 stderr=$(cat "$scratch16/err.log")"

# Check metrics: should have 1 issue without evidence (fleet-ops#1003)
grep -q 'fleet_issue_closed_without_evidence_total 1' "$scratch16/fleet-chains.prom" \
  || fail "evidence test 16: expected fleet_issue_closed_without_evidence_total 1, got: $(grep fleet_issue_closed_without_evidence_total "$scratch16/fleet-chains.prom")"
grep -q 'fleet_issue_closed_total 3' "$scratch16/fleet-chains.prom" \
  || fail "evidence test 16: expected fleet_issue_closed_total 3 (2 recent fleet-ops + 1 0509), got: $(grep fleet_issue_closed_total "$scratch16/fleet-chains.prom")"
grep -q 'fleet_issue_closed_without_evidence{repo="fleet-ops"} 1' "$scratch16/fleet-chains.prom" \
  || fail "evidence test 16: expected fleet-ops=1, got: $(grep 'fleet_issue_closed_without_evidence{repo=' "$scratch16/fleet-chains.prom")"

# Check LOUD was logged
grep -q 'ISSUE-CLOSE-NO-EVIDENCE' "$scratch16/triage.md" \
  || fail "evidence test 16: LOUD ISSUE-CLOSE-NO-EVIDENCE not in triage"

ok "issue evidence check: flags issues closed without PR/commit evidence (fleet-ops#1527)"

rm -rf "$scratch16"

echo "OK: fleet-completion-canary: stall ladder, green cycle, skip-list, ue observe, verify deadline, dispatch plane, --collect success, issue evidence"
