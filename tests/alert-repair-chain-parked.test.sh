#!/usr/bin/env bash
# tests/alert-repair-chain-parked.test.sh
#
# fleet-ops#2429: the alert-repair dispatcher must NOT spawn a fresh worker
# for an alert whose chain the completion-canary has already PARKED.
#
# Live class: FleetSloSeatAvailSlowBurn fired 2026-08-30T05:27Z and its chart
# parked the chain (terminal=escalated -> auditor-resolved, sliding
# dead_until, "no re-dispatch" note) once the repair declared the seat-
# availability SLO below target with a date-gate recovery (minimax/straitly
# 402 quota resets 2026-08-31). But AlertManager re-sends a firing alert on
# every repeat_interval (6h) and each repeat hit this dispatcher, spawning a
# fresh worker into the SAME unrepairable alert at 07:00/11:57/17:57 — each
# failing, exiting non-zero, and re-escalating to the senior conference.
# The chain "ran and failed to clear it" because it never got a legal
# terminal: the parked marker was invisible to the dispatcher.
#
# Fix: the dispatcher latches on the canary's parked-chain marker (a
# per-alertname file in the canary's open/ dir carrying a `terminal` marker
# and a `dead_until` sliding cooldown). A parked chain is the canary's
# machine-readable mechanism-impossible / structural / date-gate declaration
# — the senior conference owns the alert, and no further repair is dispatched
# until it resolves on its own clock. The canary drops the marker when the
# alert leaves 9090 (green close), so a later NEW incident dispatches normally.
#
# What we prove (hermetic, no live 9090/systemd; a real claim stub + mocked
# pi-systemd-run):
#   1. A parked chain (terminal + future dead_until) -> SKIP reason=chain-parked,
#      exit 0, no claim branch taken, no worker spawned.
#   2. A legacy parked marker (terminal, no dead_until) -> also skipped.
#   3. A parked marker whose dead_until has EXPIRED -> not skipped (a real
#      repeat may proceed; the canary re-parks on the same firing otherwise).
#   4. No state file -> not skipped; the dispatcher proceeds to the claim
#      mutex (canonical SKIPPED-CLAIMED path), proving the latch does not
#      starve a genuine new incident.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export XDG_RUNTIME_DIR="$scratch/run"
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export CHAIN_STATE_DIR="$scratch/canary-open"
export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
mkdir -p "$ALERT_REPAIR_PACKET_DIR" "$CHAIN_STATE_DIR" "$XDG_RUNTIME_DIR"

# A recorded-seat file is only consulted during spawn; the stored-skip path
# below returns before seat selection, so a minimal healthy seat suffices.
cat >"$SEAT_HEALTH_FILE" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"2099-01-01T00:00:00Z"}
EOF

# Record claim-bin invocations, but never actually run against origin. The
# parked-skip path must not reach the claim bin at all.
claim_log="$scratch/claim-invocations.log"
claim_stub="$scratch/alert-repair-claim-stub"
cat >"$claim_stub" <<EOF
#!/usr/bin/env bash
echo "claim invoked: \$*" >> "$claim_log"
# exit 1 = "already claimed": the canonical no-spawn skip. Used by the
# negative cases below so the dispatcher returns SKIPPED-CLAIMED (0) without
# ever spawning a worker.
exit 1
EOF
chmod +x "$claim_stub"
export ALERT_REPAIR_CLAIM_BIN="$claim_stub"

# Mock pi-systemd-run: must never be invoked in any scenario here.
mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
echo "pi-systemd-run invoked: $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
export MOCK_LOG="$scratch/mock-pi-systemd-run.log"
export PATH="$mock_bin:$PATH"

FUTURE=$(date -u -d "+2 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
PAST=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# fire_dispatch runs one full webhook dispatch for a given alertname.
fire_dispatch() {
    local alertname="$1"
    AMX_ALERT_1_LABEL_alertname="$alertname" \
    AMX_ALERT_1_LABEL_repo="fleet-ops" \
    AMX_ALERT_1_LABEL_severity="warning" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_LABEL_repo="fleet-ops" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    HOME="$scratch" \
    "$dispatch_bin" \
        >"$scratch/dispatch.out" 2>"$scratch/dispatch.err"
}

chain_parked_lines() {
    grep -c 'reason=chain-parked' "$ALERT_REPAIR_PACKET_DIR/actions.log" || true
}

# --- 1. parked chain (terminal + future dead_until) -> SKIP chain-parked ----
cat >"$CHAIN_STATE_DIR/FleetSloSeatAvailSlowBurn.json" <<EOF
{"alertname":"FleetSloSeatAvailSlowBurn","hop":"run","terminal":"auditor-resolved","dead_until":"$FUTURE","ladder":"stop-reason","stall_count":9}
EOF
fire_dispatch "FleetSloSeatAvailSlowBurn"
[[ "$(chain_parked_lines)" == "1" ]] \
    || fail "parked chain must log exactly one chain-parked SKIP, got: $(cat "$ALERT_REPAIR_PACKET_DIR/actions.log")"
[[ ! -s "$claim_log" ]] \
    || fail "parked chain must not reach the claim mutex, claim stub was invoked: $(cat "$claim_log")"
[[ ! -s "$MOCK_LOG" ]] \
    || fail "parked chain must not spawn a worker, pi-systemd-run invoked: $(cat "$MOCK_LOG")"
ok "parked chain (terminal + future dead_until) skipped, no claim, no spawn"

# --- 2. legacy parked marker (terminal, no dead_until) -> also skipped ------
rm -f "$CHAIN_STATE_DIR/FleetSloSeatAvailSlowBurn.json"
cat >"$CHAIN_STATE_DIR/FleetQueueSelfMaintenanceRatioHigh.json" <<EOF
{"alertname":"FleetQueueSelfMaintenanceRatioHigh","terminal":"detector-red","ladder":"stop-reason"}
EOF
fire_dispatch "FleetQueueSelfMaintenanceRatioHigh"
[[ "$(chain_parked_lines)" == "2" ]] \
    || fail "legacy parked marker (no dead_until) must also be skipped, got: $(cat "$ALERT_REPAIR_PACKET_DIR/actions.log")"
[[ ! -s "$claim_log" ]] \
    || fail "legacy parked marker must not reach the claim mutex"
ok "legacy parked marker (terminal, no dead_until) skipped"

# --- 3. parked marker whose dead_until has EXPIRED -> not skipped ------------
rm -f "$CHAIN_STATE_DIR/FleetQueueSelfMaintenanceRatioHigh.json"
cat >"$CHAIN_STATE_DIR/FleetScoutStale.json" <<EOF
{"alertname":"FleetScoutStale","hop":"verify","terminal":"detector-red","dead_until":"$PAST","ladder":"stop-reason"}
EOF
fire_dispatch "FleetScoutStale"
[[ "$(chain_parked_lines)" == "2" ]] \
    || fail "expired dead_until must NOT be treated as a parked skip, got: $(cat "$ALERT_REPAIR_PACKET_DIR/actions.log")"
[[ -s "$claim_log" ]] \
    || fail "expired dead_until must proceed to the claim mutex"
ok "expired dead_until not treated as parked (proceeds to claim)"

# --- 4. no state file -> not skipped, proceeds to claim (SKIPPED-CLAIMED) ----
rm -f "$CHAIN_STATE_DIR/FleetScoutStale.json"
: >"$claim_log"
fire_dispatch "FleetUndersaturated"
[[ "$(chain_parked_lines)" == "2" ]] \
    || fail "no state file must not count as a parked skip"
grep -q 'SKIPPED-CLAIMED' "$ALERT_REPAIR_PACKET_DIR/actions.log" \
    || fail "no state file must proceed to the canonical SKIPPED-CLAIMED path, got: $(cat "$ALERT_REPAIR_PACKET_DIR/actions.log")"
ok "no state file: dispatcher proceeds to claim mutex (no starvation)"

echo
echo "ALL ALERT-REPAIR CHAIN-PARKED TESTS PASSED"
