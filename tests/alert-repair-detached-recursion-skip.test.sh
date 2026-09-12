#!/usr/bin/env bash
# tests/alert-repair-detached-recursion-skip.test.sh
#
# fleet-ops#4266 follow-up: DetachedJobDied repair-artifact recursion guard. A failed
# alert-repair-DetachedJobDied-<ts> unit writes a fleet_detached_job_died
# metric, which fires a fresh DetachedJobDied alert, which dispatches a fresh
# repair unit, which fails, and so on. Each new unit has a unique name, so
# Alertmanager's repeat/6h throttle does not stop it. This test proves the
# dispatcher clears and skips:
#   - unit names starting with alert-repair-
#   - the synthetic test-unit
#   - any DetachedJobDied with an empty cmdline (unlaunchable)
# while still dispatching a real detached job like pi-fleetops-pr4422-rebase.
#
# Hermetic: no live 9090, no real systemd, no real dead-man textfile, no
# real journalctl/gh — the fleet-ops#5142 deliverable pre-flight seams
# (JOURNALCTL_BIN, GH, FLEET_DISPATCH_LEDGER/AGENT_STATE, PI_SYSTEMD_RUN_BIN)
# all point into scratch.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

scratch="$(mktemp -d -t alert-repair-recursion.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/packets" "$scratch/seats" "$scratch/mock-bin" \
         "$scratch/agent-state"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Healthy fake seat so _pick_seat has something to offer the real alert.
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF

# Mock deadman: records --clear invocations and otherwise does nothing.
MOCK_DEADMAN="$scratch/mock-bin/pi-detached-deadman"
cat >"$MOCK_DEADMAN" <<'MOCK'
#!/usr/bin/env bash
echo "deadman $*" >> "${MOCK_DEADMAN_LOG:?}"
exit 0
MOCK
chmod +x "$MOCK_DEADMAN"

# Mock claim helper: always proceeds so the test can reach the spawn/no-spawn path.
MOCK_CLAIM="$scratch/mock-bin/alert-repair-claim"
cat >"$MOCK_CLAIM" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$MOCK_CLAIM"

# Mock journalctl (JOURNALCTL_BIN seam): records argv, prints nothing — no
# `died:` line ever matches, so the pre-flight's journal leg returns ''.
MOCK_JOURNALCTL="$scratch/mock-bin/journalctl"
cat >"$MOCK_JOURNALCTL" <<'MOCK'
#!/usr/bin/env bash
echo "journalctl $*" >> "${MOCK_JOURNAL_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$MOCK_JOURNALCTL"

# Mock gh (GH seam): records argv and exits 1. Fail-closed stub — if the
# pre-flight ever reaches it, gh failing must still leave the dispatch
# fail-open (which is exactly what the NO-SPAWN assertions check). With an
# empty AGENT_STATE there is no dispatch-ledger.jsonl, so the ledger leg
# finds nothing and gh is never reached anyway.
MOCK_GH="$scratch/mock-bin/gh"
cat >"$MOCK_GH" <<'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "${MOCK_GH_LOG:-/dev/null}"
exit 1
MOCK
chmod +x "$MOCK_GH"

# Mock spawn helper (PI_SYSTEMD_RUN_BIN seam): records argv and exits 0.
# ALERT_REPAIR_NO_SPAWN already suppresses the spawn path; the seam still
# points into scratch so a real pi-systemd-run is unreachable.
MOCK_SPAWN="$scratch/mock-bin/pi-systemd-run"
cat >"$MOCK_SPAWN" <<'MOCK'
#!/usr/bin/env bash
echo "pi-systemd-run $*" >> "${MOCK_SPAWN_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$MOCK_SPAWN"

# Base environment for every dispatch.
export PACKET_DIR="$scratch/packets"
export ALERT_REPAIR_PACKET_DIR="$scratch/packets"
export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
export SEAT_LEDGER_DIR="$scratch/seats"
export ALERT_REPAIR_CLAIM_BIN="$MOCK_CLAIM"
export PI_DEADMAN_BIN="$MOCK_DEADMAN"
export PI_DEADMAN_TEXTFILE="$scratch/fleet-detached.prom"
export JOURNALCTL_BIN="$MOCK_JOURNALCTL"
export GH="$MOCK_GH"
export PI_SYSTEMD_RUN_BIN="$MOCK_SPAWN"
export AGENT_STATE="$scratch/agent-state"
export FLEET_DISPATCH_LEDGER="$scratch/agent-state/dispatch-ledger.jsonl"
export ALERT_REPAIR_NO_SPAWN=1
export MOCK_DEADMAN_LOG="$scratch/mock-deadman.log"
export MOCK_JOURNAL_LOG="$scratch/mock-journal.log"
export MOCK_GH_LOG="$scratch/mock-gh.log"
export MOCK_SPAWN_LOG="$scratch/mock-spawn.log"
export AMX_STATUS=firing
export AMX_RECEIVER=repair-dispatch
export AMX_LABEL_service=fleet

run_dispatch() {
    (
        export PACKET_DIR="$scratch/packets"
        export ALERT_REPAIR_PACKET_DIR="$scratch/packets"
        export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
        export SEAT_LEDGER_DIR="$scratch/seats"
        export ALERT_REPAIR_CLAIM_BIN="$MOCK_CLAIM"
        export PI_DEADMAN_BIN="$MOCK_DEADMAN"
        export PI_DEADMAN_TEXTFILE="$scratch/fleet-detached.prom"
        export JOURNALCTL_BIN="$MOCK_JOURNALCTL"
        export GH="$MOCK_GH"
        export PI_SYSTEMD_RUN_BIN="$MOCK_SPAWN"
        export AGENT_STATE="$scratch/agent-state"
        export FLEET_DISPATCH_LEDGER="$scratch/agent-state/dispatch-ledger.jsonl"
        export ALERT_REPAIR_NO_SPAWN=1
        export MOCK_DEADMAN_LOG="$scratch/mock-deadman.log"
        export MOCK_JOURNAL_LOG="$scratch/mock-journal.log"
        export MOCK_GH_LOG="$scratch/mock-gh.log"
        export MOCK_SPAWN_LOG="$scratch/mock-spawn.log"
        export AMX_STATUS=firing
        export AMX_RECEIVER=repair-dispatch
        export AMX_LABEL_service=fleet
        for e in "$@"; do
            export "$e"
        done
        "$dispatch_bin" >"$scratch/out" 2>"$scratch/err"
    )
    rc=$?
    return $rc
}

# Test 1: alert-repair-DetachedJobDied artifact is skipped and cleared.
: >"$scratch/packets/actions.log"
: >"$scratch/mock-deadman.log"
run_dispatch \
    'AMX_ALERT_1_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_1_LABEL_unit=alert-repair-DetachedJobDied-20260909T170216Z' \
    'AMX_ALERT_1_LABEL_cmdline=pi --print --provider devin --model glm-5-2' \
    'AMX_ALERT_1_LABEL_deliverable=0' \
    'AMX_ALERT_1_LABEL_deadline=60' \
    'AMX_ALERT_1_STATUS=firing'
rc=$?
[[ "$rc" == 0 ]] || fail "artifact alert dispatch must exit 0, got rc=$rc"
grep -q 'SKIP alertname=DetachedJobDied.*alert-repair-DetachedJobDied-20260909T170216Z.*reason=repair-artifact-cleared' "$scratch/packets/actions.log" \
    || fail "artifact must log SKIP; actions.log=$(cat "$scratch/packets/actions.log" 2>/dev/null)"
grep -q 'deadman --clear alert-repair-DetachedJobDied-20260909T170216Z' "$scratch/mock-deadman.log" \
    || fail "deadman --clear must be called for artifact; log=$(cat "$scratch/mock-deadman.log" 2>/dev/null)"
! grep -q '\] DISPATCH ' "$scratch/packets/actions.log" \
    || fail "artifact must not produce a DISPATCH line"
! grep -q '\] NO-SPAWN ' "$scratch/packets/actions.log" \
    || fail "artifact must not reach the no-spawn path"
ok 'alert-repair-DetachedJobDied artifact: SKIP, --clear called, no dispatch'

# Test 2: test-unit with empty cmdline is skipped and cleared.
: >"$scratch/packets/actions.log"
: >"$scratch/mock-deadman.log"
run_dispatch \
    'AMX_ALERT_1_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_1_LABEL_unit=test-unit' \
    'AMX_ALERT_1_LABEL_cmdline=' \
    'AMX_ALERT_1_LABEL_deliverable=0' \
    'AMX_ALERT_1_LABEL_deadline=' \
    'AMX_ALERT_1_STATUS=firing'
rc=$?
[[ "$rc" == 0 ]] || fail "test-unit dispatch must exit 0, got rc=$rc"
grep -q 'SKIP alertname=DetachedJobDied.*unit=test-unit.*reason=repair-artifact-cleared' "$scratch/packets/actions.log" \
    || fail "test-unit must log SKIP; actions.log=$(cat "$scratch/packets/actions.log" 2>/dev/null)"
grep -q 'deadman --clear test-unit' "$scratch/mock-deadman.log" \
    || fail "deadman --clear must be called for test-unit; log=$(cat "$scratch/mock-deadman.log" 2>/dev/null)"
! grep -q '\] DISPATCH ' "$scratch/packets/actions.log" \
    || fail "test-unit must not produce a DISPATCH line"
ok 'test-unit: SKIP, --clear called, no dispatch'

# Test 3: a real detached job (pi-fleetops-pr4422-rebase) still dispatches (no-spawn).
: >"$scratch/packets/actions.log"
: >"$scratch/mock-deadman.log"
run_dispatch \
    'AMX_ALERT_1_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_1_LABEL_unit=pi-fleetops-pr4422-rebase' \
    'AMX_ALERT_1_LABEL_cmdline=pi --print --provider cline --model z-ai/glm-5.3-flash' \
    'AMX_ALERT_1_LABEL_deliverable=0' \
    'AMX_ALERT_1_LABEL_deadline=90' \
    'AMX_ALERT_1_STATUS=firing'
rc=$?
[[ "$rc" == 0 ]] || fail "real detached job dispatch must exit 0, got rc=$rc"
! grep -q 'reason=repair-artifact-cleared' "$scratch/packets/actions.log" \
    || fail "real detached job must not be classified as artifact"
! grep -q 'deadman --clear' "$scratch/mock-deadman.log" \
    || fail "real detached job must not trigger a dead-man clear"
grep -q '\] NO-SPAWN ' "$scratch/packets/actions.log" \
    || fail "real detached job must reach the no-spawn path; actions.log=$(cat "$scratch/packets/actions.log" 2>/dev/null)"
ok 'real detached job: NO-SPAWN path, no artifact clear'

# Test 4: mixed group (real + two artifacts) only dispatches the real one.
: >"$scratch/packets/actions.log"
: >"$scratch/mock-deadman.log"
run_dispatch \
    'AMX_ALERT_1_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_1_LABEL_unit=alert-repair-DetachedJobDied-20260909T170216Z' \
    'AMX_ALERT_1_LABEL_cmdline=pi --print --provider devin --model glm-5-2' \
    'AMX_ALERT_1_LABEL_deliverable=0' \
    'AMX_ALERT_1_LABEL_deadline=60' \
    'AMX_ALERT_1_STATUS=firing' \
    'AMX_ALERT_2_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_2_LABEL_unit=pi-fleetops-pr4422-rebase' \
    'AMX_ALERT_2_LABEL_cmdline=pi --print --provider cline --model z-ai/glm-5.3-flash' \
    'AMX_ALERT_2_LABEL_deliverable=0' \
    'AMX_ALERT_2_LABEL_deadline=90' \
    'AMX_ALERT_2_STATUS=firing' \
    'AMX_ALERT_3_LABEL_alertname=DetachedJobDied' \
    'AMX_ALERT_3_LABEL_unit=test-unit' \
    'AMX_ALERT_3_LABEL_cmdline=' \
    'AMX_ALERT_3_LABEL_deliverable=0' \
    'AMX_ALERT_3_LABEL_deadline=' \
    'AMX_ALERT_3_STATUS=firing'
rc=$?
[[ "$rc" == 0 ]] || fail "mixed dispatch must exit 0, got rc=$rc"
# Two artifact clears.
grep -c 'reason=repair-artifact-cleared' "$scratch/packets/actions.log" | grep -q '^2$' \
    || fail "mixed group must log exactly two artifact clears; actions.log=$(cat "$scratch/packets/actions.log" 2>/dev/null)"
grep -c 'deadman --clear' "$scratch/mock-deadman.log" | grep -q '^2$' \
    || fail "mixed group must call deadman --clear exactly twice; log=$(cat "$scratch/mock-deadman.log" 2>/dev/null)"
# Packet should only list the real unit.
grep -q 'unit=pi-fleetops-pr4422-rebase' "$scratch/packets"/*.md \
    || fail "packet must mention the real unit; packets=$(ls "$scratch/packets")"
! grep -q 'unit=alert-repair-DetachedJobDied-20260909T170216Z' "$scratch/packets"/*.md \
    || fail "packet must not list the artifact unit"
! grep -q 'unit=test-unit' "$scratch/packets"/*.md \
    || fail "packet must not list test-unit"
ok 'mixed group: two artifacts skipped/cleared, only real unit in packet'

ok 'fleet-ops#4266 recursion guard passes'
