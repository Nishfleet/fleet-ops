#!/usr/bin/env bash
# tests/alert-repair-wfr-trend-skip.test.sh
#
# fleet-ops#2528: lock the three WFR-input TREND regression alerts
# (FleetSelfMaintenanceRegression, FleetQualityChurnRegression,
# FleetVerifiedMergeRegression) into the repair skip rails so a firing
# 24h-delta trend can never spawn a repair worker or escalate a canary
# chain. The alerts still fire in Alertmanager and feed the scoreboard;
# the repair rail just cannot weaponize them (the seat-burn loop PR #2441
# closed for FleetSloSeatAvailSlowBurn — fleet-ops#2429).
#
# Offline (no live Prom/Alertmanager). Hosted by
# tests/ci-standards-audit.test.sh so it runs in P14 without a
# workflow-file edit.
#
# Proves:
#   1. The three names are in libexec/alert-repair-dispatch SKIP_SET
#      (each exactly once — the issue's `grep -c == 3` termination gate).
#   2. The three names are in bin/fleet-completion-canary.py SKIP_FIRING
#      (each exactly once).
#   3. Dispatcher stub: firing each name through the real dispatcher
#      with a mocked environment logs `SKIP reason=skip-list`, adds no
#      DISPATCH line, and spawns no worker (no pi-systemd-run).
#   4. Canary stub (fleet-completion-canary 5c shape): a firing trend
#      alert opens no chain, triggers no AMX redispatch, and writes no
#      STOP-REASON — the canary must not ladder a WFR-input trend delta.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"
canary_bin="$repo_root/bin/fleet-completion-canary.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

TREND_NAMES=(
  FleetSelfMaintenanceRegression
  FleetQualityChurnRegression
  FleetVerifiedMergeRegression
)

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
[[ -x "$canary_bin" ]]  || fail "not executable: $canary_bin"
python3 -m py_compile "$dispatch_bin" "$canary_bin" || fail "py_compile failed"

scratch="$(mktemp -d -t alert-repair-wfr-trend.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. dispatcher SKIP_SET contains all three names, each exactly once ---
python3 - "$dispatch_bin" <<'PY' || fail "dispatcher SKIP_SET shape failed"
from pathlib import Path
import ast, re, sys

names = ["FleetSelfMaintenanceRegression", "FleetQualityChurnRegression",
         "FleetVerifiedMergeRegression"]
src = Path(sys.argv[1]).read_text()
m = re.search(r"SKIP_SET = (\{.*?\})", src, re.S)
assert m, "SKIP_SET not found in alert-repair-dispatch"
skip = ast.literal_eval(m.group(1))
for n in names:
    assert n in skip, f"{n} missing from SKIP_SET: {skip}"
for n in names:
    assert src.count(n) == 1, f"{n} must appear exactly once (termination grep -c == 3), got {src.count(n)}"
print("OK: dispatcher SKIP_SET has all three WFR-input trend regressions (one occurrence each)")
PY

# --- 2. canary SKIP_FIRING contains all three names, each exactly once ---
python3 - "$canary_bin" <<'PY' || fail "canary SKIP_FIRING shape failed"
from pathlib import Path
import ast, re, sys

names = ["FleetSelfMaintenanceRegression", "FleetQualityChurnRegression",
         "FleetVerifiedMergeRegression"]
src = Path(sys.argv[1]).read_text()
m = re.search(r"SKIP_FIRING = (\{.*?\})", src, re.S)
assert m, "SKIP_FIRING not found in fleet-completion-canary.py"
skip = ast.literal_eval(m.group(1))
for n in names:
    assert n in skip, f"{n} missing from SKIP_FIRING: {skip}"
for n in names:
    assert src.count(n) == 1, f"{n} must appear exactly once, got {src.count(n)}"
print("OK: canary SKIP_FIRING has all three WFR-input trend regressions (one occurrence each)")
PY

# --- 3. dispatcher stub: SKIP reason=skip-list, no DISPATCH, no spawn ------
# Same shape as tests/alert-repair-claim-mutex.test.sh fire_skip
# (FleetSloSeatAvailSlowBurn, fleet-ops#2429): firing the alert through the
# real dispatcher with a mocked pi-systemd-run PATH must log SKIP, add no
# DISPATCH line, and never invoke the worker spawner.
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

fire_skip() {
    local name="$1"
    AMX_ALERT_1_LABEL_alertname="$name" \
    AMX_ALERT_1_LABEL_severity="warning" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_LABEL_repo="fleet-ops" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin:$PATH" \
    HOME="$scratch" \
    "$dispatch_bin" \
        >"$scratch/dispatch-$name.out" 2>"$scratch/dispatch-$name.err"
}

for name in "${TREND_NAMES[@]}"; do
    : >"$PACKET_DIR/actions.log"
    : >"$MOCK_LOG"
    fire_skip "$name"; skip_rc=$?
    [[ "$skip_rc" == 0 ]] \
        || fail "$name dispatch must exit 0, got rc=$skip_rc (stderr: $(cat "$scratch/dispatch-$name.err"))"
    grep -q "SKIP alertname=$name.*reason=skip-list" "$PACKET_DIR/actions.log" \
        || fail "$name must log SKIP reason=skip-list; actions.log: $(cat "$PACKET_DIR/actions.log")"
    disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
    [[ "$disps" == "0" ]] \
        || fail "$name must not add a DISPATCH line, got $disps: $(cat "$PACKET_DIR/actions.log")"
    spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
    [[ "$spawns" == "0" ]] \
        || fail "$name must not spawn a worker, mock invoked $spawns times: $(cat "$MOCK_LOG")"
    ok "$name: dispatcher SKIP reason=skip-list, no DISPATCH, no spawn"
done

# --- 4. canary stub: firing trend opens no chain, no redispatch, no STOP-REASON
# Same shape as tests/fleet-completion-canary.test.sh section 5c
# (FleetSloSeatAvailSlowBurn, fleet-ops#2429): a WFR-input alert in
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

run_canary() {
  local now="$1"
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
  FLEET_COMPLETION_NOW="$now" \
  FLEET_COMPLETION_ISSUE_EVIDENCE_REPOS_FILE="$scratch/intake-repos.json" \
  SYSCTL_STORE="$scratch/sysctl" \
  DISPATCH_LOG="$scratch/dispatch.log" \
  REDISPATCH_LOG="$scratch/redispatch.log" \
  HOME="$scratch" \
    python3 "$canary_bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

for name in "${TREND_NAMES[@]}"; do
    rm -rf "$scratch/state"; mkdir -p "$scratch/state"
    : >"$scratch/dispatch.log"
    : >"$scratch/actions.log"
    rm -f "$scratch/STOP-REASON.json"
    python3 - "$scratch/alerts.json" "$name" <<'PY'
import json, sys
name = sys.argv[2]
json.dump({"status":"success","data":{"alerts":[
  {"state":"firing","activeAt":"2026-08-27T05:27:33Z",
   "labels":{"alertname": name}}
]}}, open(sys.argv[1],"w"))
PY
    rc=$(run_canary "2026-08-27T15:00:00Z")  # ~9.5h after firing, past all hop clocks
    [[ "$rc" == "0" ]] || fail "$name canary rc=$rc stderr=$(cat "$scratch/err.log")"
    grep -q 'fleet_chain_open{plane="alert-repair",hop="dispatch"} 0' "$scratch/fleet-chains.prom" \
        || fail "$name must not open a chain; prom=$(cat "$scratch/fleet-chains.prom")"
    if grep -q '^dispatch AMX' "$scratch/dispatch.log"; then
        fail "$name must not AMX-redispatch; log=$(cat "$scratch/dispatch.log")"
    fi
    [[ ! -f "$scratch/STOP-REASON.json" ]] \
        || fail "$name must not write STOP-REASON"
    ok "$name: canary opens no chain, no AMX redispatch, no STOP-REASON"
done

echo "OK: fleet-ops#2528 trend regression skip-list lock passes"