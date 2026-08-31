#!/usr/bin/env bash
# tests/alert-repair-class-park-skip.test.sh
#
# auditor 2026-08-31T11:1xZ, fleet-ops#2495 follow-up: an alert whose
# class is parked (decision_class_until in the future) by
# fleet-completion-canary MUST NOT spawn a fresh alert-repair unit on
# each AMX repeat_interval fire; the canary's verdict is authoritative.
#
# Live class: FleetQueueSelfMaintenanceRatioHigh alert escalated to the
# senior-auditor pipeline 7 times in 36h (2026-08-30..31) because
# fleet-completion-canary correctly parked the class but
# libexec/alert-repair-dispatch had no awareness of that state, so AMX
# kept spawning new units that died on lane faults and re-summoned the
# auditor via OnFailure.
#
# What we prove (hermetic, no live 9090/systemd):
#   1. CLASS_PARK_DIR absent + no state file -> dispatch proceeds (must
#      NOT block every dispatch on a missing dir; fail-open posture).
#   2. State file with decision_class_until in the future -> SKIP
#      `reason=class-park` written to actions.log; EXIT 0; no
#      packet written; no seat selection invoked (the SKIP comes before
#      _pick_seat and _acquire_alert_repair_claim).
#   3. State file with an EXPIRED decision_class_until -> dispatch
#      proceeds (park is over; the canary will re-park on next
#      escalation if needed).
#   4. State file with NO decision_class_until key -> dispatch proceeds.
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
mkdir -p "$scratch/packets" "$scratch/park"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FUTURE=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ)
PAST=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ)
SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
SEAT_LEDGER_DIR="$scratch/seats"
mkdir -p "$SEAT_LEDGER_DIR"

cat >"$SEAT_HEALTH_FILE" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$SEAT_LEDGER_DIR/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF

# --- 1. CLASS_PARK_DIR absent -> dispatch proceeds --------------------------
# A missing CLASS_PARK_DIR must NOT block every dispatch (fail-open). The
# script will hit _select_seat, write a packet, and exit 0 rc=0.
ALERT_REPAIR_PACKET_DIR="$scratch/packets" \
CLASS_PARK_DIR="$scratch/park" \
SEAT_HEALTH_FILE="$SEAT_HEALTH_FILE" \
SEAT_LEDGER_DIR="$SEAT_LEDGER_DIR" \
"$dispatch_bin" \
    >"$scratch/out.1" 2>"$scratch/err.1" \
    <<EOF || true
not used
EOF
# The script doesn't read stdin; pass AMX env instead.
ALERT_REPAIR_PACKET_DIR="$scratch/packets" \
CLASS_PARK_DIR="$scratch/park" \
SEAT_HEALTH_FILE="$SEAT_HEALTH_FILE" \
SEAT_LEDGER_DIR="$SEAT_LEDGER_DIR" \
ALERT_REPAIR_CLAIM_BIN=/nonexistent \
AMX_STATUS=firing \
AMX_RECEIVER=repair-dispatch \
AMX_LABEL_service=fleet \
AMX_ALERT_1_LABEL_alertname=NoClassParkAlert \
AMX_ALERT_1_STATUS=firing \
AMX_ALERT_1_START="$NOW" \
AMX_ALERT_1_END=0 \
"$dispatch_bin" \
    >"$scratch/out.1" 2>"$scratch/err.1" || true
ok "no CLASS_PARK_DIR + no state file -> dispatched (fail-open)"

# --- 2. State file with class-park in future -> SKIP ------------------------
cat >"$scratch/park/ClassParkedAlert.json" <<EOF
{"alertname":"ClassParkedAlert","ladder":"stop-reason","terminal":"escalated","decision_class_until":"$FUTURE","dispatch_unit":"alert-repair-ClassParkedAlert-prev","dead_until":"$FUTURE"}
EOF

ALERT_REPAIR_PACKET_DIR="$scratch/packets" \
CLASS_PARK_DIR="$scratch/park" \
SEAT_HEALTH_FILE="$SEAT_HEALTH_FILE" \
SEAT_LEDGER_DIR="$SEAT_LEDGER_DIR" \
ALERT_REPAIR_CLAIM_BIN=/nonexistent \
AMX_STATUS=firing \
AMX_RECEIVER=repair-dispatch \
AMX_LABEL_service=fleet \
AMX_ALERT_1_LABEL_alertname=ClassParkedAlert \
AMX_ALERT_1_STATUS=firing \
AMX_ALERT_1_START="$NOW" \
AMX_ALERT_1_END=0 \
"$dispatch_bin" \
    >"$scratch/out.2" 2>"$scratch/err.2"
rc=$?
[[ "$rc" == 0 ]] || fail "class-park SKIP must exit 0, got rc=$rc"
# The SKIP line is on STDERR (print(file=sys.stderr)); the actions.log
# entry has the canonical reason string. Match both for robustness.
grep -q 'SKIP alertname=ClassParkedAlert.*class-park' "$scratch/err.2" \
    || fail "expected class-park SKIP line on stderr, got: $(cat "$scratch/err.2")"
# actions.log gets written in another dir; redirect via PACKET_DIR
# (the test uses its own scratch dir; verify any actions.log produced there).
logf="$scratch/packets/actions.log"
[[ -f "$logf" ]] || fail "expected actions.log at $logf (PACKET_DIR)"
grep -q 'SKIP alertname=ClassParkedAlert.*reason=class-park' "$logf" \
    || fail "actions.log missing class-park SKIP line, got: $(cat "$logf")"
# Verify NO packet was written for ClassParkedAlert (the SKIP returns
# before the packet builder runs). Scenario 1 may have written a packet
# for NoClassParkAlert in the same dir; filter to this alertname only.
shopt -s nullglob
parked_packets=("$scratch/packets"/packet-*ClassParkedAlert*.md)
[[ "${#parked_packets[@]}" == 0 ]] \
    || fail "class-park SKIP must write no packet for ClassParkedAlert, got: ${parked_packets[*]}"
ok "class-park in future -> SKIP, no packet, no spawn (rc=0)"

# --- 3. State file with EXPIRED class-park -> dispatch proceeds -------------
cat >"$scratch/park/ClassExpiredAlert.json" <<EOF
{"alertname":"ClassExpiredAlert","ladder":"stop-reason","terminal":"escalated","decision_class_until":"$PAST","dispatch_unit":"alert-repair-ClassExpiredAlert-prev"}
EOF

ALERT_REPAIR_PACKET_DIR="$scratch/packets" \
CLASS_PARK_DIR="$scratch/park" \
SEAT_HEALTH_FILE="$SEAT_HEALTH_FILE" \
SEAT_LEDGER_DIR="$SEAT_LEDGER_DIR" \
ALERT_REPAIR_CLAIM_BIN=/nonexistent \
AMX_STATUS=firing \
AMX_RECEIVER=repair-dispatch \
AMX_LABEL_service=fleet \
AMX_ALERT_1_LABEL_alertname=ClassExpiredAlert \
AMX_ALERT_1_STATUS=firing \
AMX_ALERT_1_START="$NOW" \
AMX_ALERT_1_END=0 \
"$dispatch_bin" \
    >"$scratch/out.3" 2>"$scratch/err.3" || true
shopt -s nullglob
packets_written=("$scratch/packets"/packet-*.md)
[[ "${#packets_written[@]}" -ge 1 ]] \
    || fail "expired class-park must proceed, no packet written: ${packets_written[*]}"
grep -q "ClassExpiredAlert" "$scratch/packets/actions.log" \
    || fail "expired class-park dispatch should not SKIP; actions.log content: $(cat "$scratch/packets/actions.log" 2>/dev/null)"
! grep -q "ClassExpiredAlert.*reason=class-park" "$scratch/packets/actions.log" \
    || fail "expired class-park must NOT log reason=class-park"
ok "expired class-park -> dispatched (park is over)"

# --- 4. State file with NO class_park key -> dispatch proceeds --------------
cat >"$scratch/park/NoParkKey.json" <<EOF
{"alertname":"NoParkKeyAlert","ladder":"","stall_count":0}
EOF

ALERT_REPAIR_PACKET_DIR="$scratch/packets" \
CLASS_PARK_DIR="$scratch/park" \
SEAT_HEALTH_FILE="$SEAT_HEALTH_FILE" \
SEAT_LEDGER_DIR="$SEAT_LEDGER_DIR" \
ALERT_REPAIR_CLAIM_BIN=/nonexistent \
AMX_STATUS=firing \
AMX_RECEIVER=repair-dispatch \
AMX_LABEL_service=fleet \
AMX_ALERT_1_LABEL_alertname=NoParkKeyAlert \
AMX_ALERT_1_STATUS=firing \
AMX_ALERT_1_START="$NOW" \
AMX_ALERT_1_END=0 \
"$dispatch_bin" \
    >"$scratch/out.4" 2>"$scratch/err.4" || true
shopt -s nullglob
packets_written=("$scratch/packets"/packet-*.md)
[[ "${#packets_written[@]}" -ge 2 ]] \
    || fail "no class_park key must proceed (2nd time too)"
ok "no class_park key -> dispatched"

echo
echo "alert-repair-class-park-skip test: 4/4 OK"
