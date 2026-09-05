#!/usr/bin/env bash
# tests/alert-repair-fleet-escalation-storm-skip.test.sh
#
# fleet-ops#3376: lock FleetEscalationStorm into the repair skip rails.
# fleet_escalations_24h is a 24h rolling count / trend gauge; a repair worker
# cannot clear it because the count ages out rather than being fixable. Without
# the skip, Alertmanager's 6h repeat dispatched a fresh worker every cycle
# (20h continuous firing, 964 counted escalations, terminal=escalated at
# 10881s in 2026-09-04). Those repair dispatches could not outrun the 24h
# window and instead added verify-stall noise. Repair is mechanism-impossible
# (the source is in the exporter code and/or a genuine underlying seat fault,
# not a runtime knob).
#
# Offline (no live Prom/Alertmanager). Hosted by
# tests/ci-standards-audit.test.sh so it runs in P14 without a
# workflow-file edit.
#
# Proves:
#   1. The name is in libexec/alert-repair-dispatch SKIP_SET exactly once.
#   2. The name is in bin/fleet-completion-canary.py SKIP_FIRING exactly once.
#   3. Dispatcher stub: firing the alert through the real dispatcher with a
#      mocked environment logs `SKIP reason=skip-list`, adds no DISPATCH
#      line, and spawns no worker (no pi-systemd-run).
#   4. Canary stub: a firing FleetEscalationStorm opens no chain, triggers no AMX
#      redispatch, and writes no STOP-REASON — the canary must not ladder a
#      non-dispatchable alert.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"
canary_bin="$repo_root/bin/fleet-completion-canary.py"
name="FleetEscalationStorm"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
[[ -x "$canary_bin" ]]  || fail "not executable: $canary_bin"
python3 -m py_compile "$dispatch_bin" "$canary_bin" || fail "py_compile failed"

scratch="$(mktemp -d -t alert-repair-fleet-escalation-storm.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. dispatcher SKIP_SET contains the name exactly once -----------------
# The literal must carry the name once and only once. Comments elsewhere
# in the file (e.g. a later history note that names the alert) do not
# count against this — we count occurrences INSIDE the SKIP_SET literal,
# not in the whole file.
python3 - "$dispatch_bin" "$name" <<'PY' || fail "dispatcher SKIP_SET shape failed"
import ast, re, sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
m = re.search(r"SKIP_SET = (\{.*?\})", src, re.S)
assert m, "SKIP_SET not found in alert-repair-dispatch"
skip = ast.literal_eval(m.group(1))
assert name in skip, f"{name} missing from SKIP_SET: {skip}"
in_literal = m.group(1).count(f'"{name}"')
assert in_literal == 1, f"{name} must appear exactly once inside SKIP_SET literal, got {in_literal}"
print(f"OK: dispatcher SKIP_SET contains {name} (one occurrence in literal)")
PY

# --- 2. canary SKIP_FIRING contains the name exactly once ------------------
python3 - "$canary_bin" "$name" <<'PY' || fail "canary SKIP_FIRING shape failed"
import ast, re, sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
m = re.search(r"SKIP_FIRING = (\{.*?\})", src, re.S)
assert m, "SKIP_FIRING not found in fleet-completion-canary.py"
skip = ast.literal_eval(m.group(1))
assert name in skip, f"{name} missing from SKIP_FIRING: {skip}"
in_literal = m.group(1).count(f'"{name}"')
assert in_literal == 1, f"{name} must appear exactly once inside SKIP_FIRING literal, got {in_literal}"
print(f"OK: canary SKIP_FIRING contains {name} (one occurrence in literal)")
PY

# --- 3. dispatcher stub: SKIP reason=skip-list, no DISPATCH, no spawn ------
# Same shape as tests/alert-repair-wfr-trend-skip.test.sh / the
# FleetSloSeatAvailSlowBurn fire_skip (tests/alert-repair-claim-mutex.test.sh,
# fleet-ops#2429): firing the alert through the real dispatcher with a mocked
# pi-systemd-run PATH must log SKIP, add no DISPATCH line, and never invoke
# the worker spawner.
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export PACKET_DIR="$scratch/agent-state/alert-repair"
mkdir -p "$PACKET_DIR"

mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mock-pi-systemd-run args=$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
export MOCK_LOG="$scratch/mock-pi-systemd-run.log"

: >"$PACKET_DIR/actions.log"
: >"$MOCK_LOG"
AMX_ALERT_1_LABEL_alertname="$name" \
AMX_ALERT_1_LABEL_severity="warning" \
AMX_ALERT_1_LABEL_service="fleet" \
AMX_LABEL_repo="fleet-ops" \
AMX_STATUS="firing" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin:$PATH" \
HOME="$scratch" \
"$dispatch_bin" \
    >"$scratch/dispatch.out" 2>"$scratch/dispatch.err"
dispatch_rc=$?
[[ "$dispatch_rc" == 0 ]] \
    || fail "$name dispatch must exit 0, got rc=$dispatch_rc (stderr: $(cat "$scratch/dispatch.err"))"
grep -q "SKIP alertname=$name.*reason=skip-list" "$PACKET_DIR/actions.log" \
    || fail "$name must log SKIP reason=skip-list; actions.log: $(cat "$PACKET_DIR/actions.log")"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] \
    || fail "$name must not add a DISPATCH line, got $disps: $(cat "$PACKET_DIR/actions.log")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "$name must not spawn a worker, mock invoked $spawns times: $(cat "$MOCK_LOG")"
ok "$name: dispatcher SKIP reason=skip-list, no DISPATCH, no spawn"

# --- 4. canary stub: firing FleetEscalationStorm opens no chain, no STOP-REASON -------
# Same shape as tests/alert-repair-wfr-trend-skip.test.sh section 4
# (FleetSloSeatAvailSlowBurn shape, fleet-ops#2429): an alert in
# SKIP_FIRING must not ladder — no chain, no AMX redispatch, no STOP-REASON.
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
        unit=""; want_value=0; props=()
        for a in "$@"; do
          case "$a" in
            --property=*) props+=("${a#--property=}") ;;
            --value) want_value=1 ;;
            -*) ;;
            *) [ -z "$unit" ] && unit="$a" ;;
          esac
        done
        result="success"; active="inactive"; load="not-found"
        [ -f "$store/$unit.result" ] && result=$(cat "$store/$unit.result")
        [ -f "$store/$unit.active" ] && active=$(cat "$store/$unit.active")
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
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/systemctl"

cat >"$scratch/journalctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${SYSCTL_STORE:?}"
unit=""; grep_pat=""; last_n=""; prev=""
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
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--exclude" ]; then
      echo -e "minimax\tMiniMax-M3\tfallback-excluded"
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

# Hermetic issue-evidence: an enrolled-repos file with no repos means the
# canary never shells out to `gh issue list` during the tick.
cat >"$scratch/intake-repos.json" <<'JSON'
{"repos": []}
JSON

python3 - "$scratch/alerts.json" "$name" <<'PY'
import json, sys
name = sys.argv[2]
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-09-04T20:30:15Z",
   "labels":{"alertname": name}}
]}}, open(sys.argv[1],"w"))
PY

rm -rf "$scratch/state"; mkdir -p "$scratch/state"
: >"$scratch/dispatch.log"
: >"$scratch/actions.log"
rm -f "$scratch/STOP-REASON.json"
rc=0
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
FLEET_COMPLETION_NOW="2026-09-05T00:30:00Z" \
FLEET_COMPLETION_ISSUE_EVIDENCE_REPOS_FILE="$scratch/intake-repos.json" \
SYSCTL_STORE="$scratch/sysctl" \
DISPATCH_LOG="$scratch/dispatch.log" \
REDISPATCH_LOG="$scratch/redispatch.log" \
HOME="$scratch" \
  python3 "$canary_bin" >/dev/null 2>"$scratch/err.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "$name canary rc=$rc stderr=$(cat "$scratch/err.log")"
grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
    || fail "$name must not open a chain; prom=$(cat "$scratch/fleet-chains.prom")"
if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
    fail "$name must not AMX-redispatch; log=$(cat "$scratch/dispatch.log")"
fi
[[ ! -f "$scratch/STOP-REASON.json" ]] \
    || fail "$name must not write STOP-REASON"
ok "$name: canary opens no chain, no AMX redispatch, no STOP-REASON"

echo "OK: fleet-ops#3376 FleetEscalationStorm skip-list lock passes"
