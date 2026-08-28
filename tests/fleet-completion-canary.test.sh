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
#   6. VERIFY ... resolved counts as terminal-green.
#   7. Unit-escalation STOP-REASON within 24h budget → open, not stalled,
#      and this canary does not overwrite it.
#   8. MANIFEST + timer named-reason + nested from coverage canary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-completion-canary"

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
        for a in "$@"; do
          case "$a" in
            --property=*) ;;
            --value) ;;
            *) [ -z "$unit" ] && unit="$a" ;;
          esac
        done
        result="missing"; active="inactive"
        [ -f "$store/$unit.result" ] && result=$(cat "$store/$unit.result")
        [ -f "$store/$unit.active" ] && active=$(cat "$store/$unit.active")
        printf 'Result=%s\nActiveState=%s\n' "$result" "$active"
        if [ ! -f "$store/$unit.result" ] && [ ! -f "$store/$unit.active" ]; then
          exit 1
        fi
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/systemctl"

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
  FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
  FLEET_COMPLETION_TRIAGE="$scratch/triage.md" \
  FLEET_COMPLETION_NOW="${1:?}" \
  SYSCTL_STORE="$scratch/sysctl" \
  DISPATCH_LOG="$scratch/dispatch.log" \
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
grep -F 'bin/fleet-completion-canary /home/nish/.local/libexec/fleet-completion-canary' "$manifest" >/dev/null \
  || fail "MANIFEST missing bin/fleet-completion-canary"
grep -F 'systemd/fleet-completion-canary.timer /home/nish/.config/systemd/user/fleet-completion-canary.timer' "$manifest" >/dev/null \
  || fail "MANIFEST missing timer"
timer="$repo_root/systemd/fleet-completion-canary.timer"
grep -q 'OnCalendar=' "$timer" || fail "timer missing OnCalendar"
grep -qi 'named reason' "$timer" || grep -qi 'hop clock' "$timer" \
  || fail "timer must carry a named reason (hop clocks / 15 min)"
grep -F 'fleet-completion-canary.test.sh' "$here/escalation-coverage-canary.test.sh" >/dev/null \
  || fail "must be nested from escalation-coverage-canary.test.sh (CI-listed)"
ok "MANIFEST + named-reason timer + nested CI wiring"

# --- 9. verify stall deadline → detector-red terminal (fleet-ops#1610) -----
rm -rf "$scratch/state"; mkdir -p "$scratch/state"

# Fire BridgeSelfTest (resolved alert) + leave it firing.
# A chain at verify gets stalled, laddered, and hits the deadline.
write_alerts <<'JSON'
[
  {"labels":{"alertname":"BridgeSelfTest"},"activeAt":"2026-08-28T10:00:00Z"}
]
JSON

# Write a DISPATCH + resolved unit entry so classify sees hop=verify.
now_ts="2026-08-28T12:05:00Z"
cat >"$scratch/actions.log" <<PYEND
[2026-08-28T10:02:00Z] DISPATCH alertname=BridgeSelfTest seat=someseat/SomeModel unit=alert-repair-BridgeSelfTest-20260828T100200Z
[2026-08-28T11:30:00Z] RESOLVED alertname=BridgeSelfTest
PYEND

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

# Chain must not be in open/.
[[ -f "$scratch/state/open/BridgeSelfTest.json" ]] \
  && fail "chain must be removed from open on deadline expiry"

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

ok "verify stall deadline → detector-red terminal + cooldown gate (fleet-ops#1610)"

echo "OK: fleet-completion-canary: stall ladder, green cycle, skip-list, ue observe, verify deadline"
