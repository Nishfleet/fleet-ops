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
#   2. Dispatcher stub: firing each name through the real dispatcher
#      with a mocked environment logs `SKIP reason=skip-list`, adds no
#      DISPATCH line, and spawns no worker (no pi-systemd-run).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

TREND_NAMES=(
  FleetSelfMaintenanceRegression
  FleetQualityChurnRegression
  FleetVerifiedMergeRegression
)

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

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

# --- 2. dispatcher stub: SKIP reason=skip-list, no DISPATCH, no spawn ------
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

echo "OK: fleet-ops#2528 trend regression skip-list lock passes"