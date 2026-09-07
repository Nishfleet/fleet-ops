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
#   2. Dispatcher stub: firing the alert through the real dispatcher with a
#      mocked environment logs `SKIP reason=skip-list`, adds no DISPATCH
#      line, and spawns no worker (no pi-systemd-run).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"
name="FleetEscalationStorm"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

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

# --- 2. dispatcher stub: SKIP reason=skip-list, no DISPATCH, no spawn ------
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

echo "OK: fleet-ops#3376 FleetEscalationStorm skip-list lock passes"
