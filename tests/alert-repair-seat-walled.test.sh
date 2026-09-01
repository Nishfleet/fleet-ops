#!/usr/bin/env bash
# tests/alert-repair-seat-walled.test.sh
#
# fleet-ops#1556: the alert-repair seat selection must exclude seats that
# are walled (per-seat ledger: usable_at in the future, seat_dead, hard-fail
# health class) and must re-select rather than park on a walled seat.
#
# Live class: the verify hop redispatched onto devin/glm-5-2 (rate_limited,
# usable_at in the future, consecutive_failure_count=20) because _pick_seat
# only checked WALLED_PROVIDERS, not the per-seat ledger. The chain parked
# on an unusable seat and FleetGhWebhookReceiverAbsent stayed firing for 3h.
#
# What we prove (hermetic, no live 9090/systemd):
#   1. A healthy, non-walled recorded seat is picked as "healthy".
#   2. A recorded seat that is walled per its ledger is skipped; a healthy
#      fallback seat is picked instead.
#   3. When every fallback seat is walled, the selection re-selects from the
#      per-seat ledger rather than parking on a walled seat.
#   4. When every seat is walled or excluded, --print-seat exits 2 (the
#      caller escalates instead of dispatching into a wall).
#   5. A held wrapper spawn-bench sibling (empty-run/spawn-fail marker,
#      fleet-ops#1512) walls a seat whose LEDGER says healthy — the verify
#      hop must refuse to re-seat onto a seat inside an empty-run cooldown
#      (fleet-ops#2672: openrouter/deepseek/deepseek-v4-flash-0731 picked as
#      "healthy" at 15:22:13Z while benched for a 0B-stdout no-op run).
#   6. An expired spawn-bench marker does NOT wall the seat (fail-open,
#      mirroring seat_usable's release at usable_at).
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
mkdir -p "$scratch/seats"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FUTURE=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# --- 1. healthy recorded seat is picked as "healthy" ------------------------
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/bai__deepseek-v4-flash.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat)
[[ "$out" == "bai	deepseek-v4-flash	healthy" ]] \
    || fail "healthy recorded seat must be picked as healthy, got: $out"
ok "healthy recorded seat picked as healthy"

# --- 2. recorded seat walled per ledger -> healthy fallback picked ----------
# Recorded seat is devin/glm-5-2 (healthy in pi-seat-health.json) but its
# per-seat ledger marks it rate_limited with usable_at in the future. The
# selection must skip it and pick the healthy fallback (minimax).
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"rate_limited","observed_at":"$NOW","usable_at":"$FUTURE","consecutive_failure_count":20}
EOF
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat)
[[ "$out" == "minimax	MiniMax-M3	fallback" ]] \
    || fail "walled recorded seat must be skipped for healthy fallback, got: $out"
ok "walled recorded seat skipped; healthy fallback picked"

# --- 3. all fallback seats walled -> re-select from ledger ------------------
# Both devin and minimax are walled. The selection must re-select from the
# per-seat ledger (bai/deepseek-v4-flash) rather than park on a walled seat.
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"quota_exhausted","observed_at":"$NOW","usable_at":"$FUTURE"}
EOF
cat >"$scratch/seats/bai__deepseek-v4-flash.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat)
[[ "$out" == "bai	deepseek-v4-flash	re-selected" ]] \
    || fail "must re-select from ledger when fallback seats are walled, got: $out"
ok "all fallback seats walled -> re-selected from ledger"

# --- 4. every seat walled or excluded -> exit 2 -----------------------------
set +e
SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
SEAT_LEDGER_DIR="$scratch/seats" \
"$dispatch_bin" --print-seat --exclude bai >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "--print-seat with all seats excluded must exit 2, got rc=$rc"
grep -q 'WALLED' "$scratch/err" \
    || fail "expected WALLED on stderr, got: $(cat "$scratch/err")"
ok "all seats walled/excluded -> exit 2 (escalate, don't dispatch into a wall)"

# --- 5. held spawn-bench sibling walls a ledger-healthy seat ----------------
# fleet-ops#2672: the wrapper's spawn-bench marker is clobber-proof; the
# seat-health extension re-writes the LEDGER to healthy on a 200 OK, so only
# the sibling carries the empty-run bench. The dispatcher must refuse seats
# inside an empty-run cooldown the same way seat_usable does — the 15:22:13Z
# verify-hop REDISPATCH picked openrouter/deepseek/deepseek-v4-flash-0731
# "reason=healthy" while its spawn-bench was held (0B stdout, provider no-op
# at 14:11:19Z).
rm -rf "$scratch/seats" && mkdir -p "$scratch/seats"
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"openrouter","model":"deepseek/deepseek-v4-flash-0731","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/openrouter__deepseek_deepseek-v4-flash-0731.json" <<EOF
{"provider":"openrouter","model":"deepseek/deepseek-v4-flash-0731","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
cat >"$scratch/seats/openrouter__deepseek_deepseek-v4-flash-0731.spawn-bench.json" <<EOF
{"provider":"openrouter","model":"deepseek/deepseek-v4-flash-0731","usable_at":"$FUTURE","reason":"empty_run","written_at":"$NOW"}
EOF
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat)
[[ "$out" == "devin	glm-5-2	fallback" ]] \
    || fail "ledger-healthy seat with held spawn-bench must be skipped for fallback, got: $out"
ok "held spawn-bench sibling walls a ledger-healthy seat (empty-run cooldown respected)"

# --- 6. expired spawn-bench marker does NOT wall the seat -------------------
# Fail-open once the bench window passes: seat_usable releases the seat at
# usable_at, and the dispatcher must match (an expired marker means the
# seat-health extension observed a healthy recovery after the bench).
PAST=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$scratch/seats/openrouter__deepseek_deepseek-v4-flash-0731.spawn-bench.json" <<EOF
{"provider":"openrouter","model":"deepseek/deepseek-v4-flash-0731","usable_at":"$PAST","reason":"empty_run","written_at":"$PAST"}
EOF
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat)
[[ "$out" == "openrouter	deepseek/deepseek-v4-flash-0731	healthy" ]] \
    || fail "expired spawn-bench marker must release the seat (fail-open), got: $out"
ok "expired spawn-bench marker releases the seat (fail-open)"
# --- 5. provider-overload wedge (fleet-ops#2661) ------------------------------
export ALERT_REPAIR_NO_SPAWN=1
# A provider with >=2 seats in overload_bench within the trailing 30 min is
# WEDGED (mid 503 storm) — the escalation lanes must NEVER land on it.
# The recorded healthy seat on a wedged provider is skipped; fallback + re-select
# also skip wedged providers. When every lane is wedged, --print-seat exits 2
# (escalate, don't dispatch into a storm)andthe real dispatch path refuses (SKIP).
rm -rf "$scratch/seats"; mkdir -p "$scratch/seats" "$scratch/packets5" "$scratch/park5"
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW"}
EOF
# bai: two seats in overload_bench, wall end recent (NOW-0s / FUTURE) -> wedged.
cat >"$scratch/seats/bai__deepseek-v4-flash.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"overload_bench","observed_at":"$NOW","bench_until":"$FUTURE"}
EOF
cat >"$scratch/seats/bai__bai-2.json" <<EOF
{"provider":"bai","model":"bai-2","health_class":"overload_bench","observed_at":"$NOW","bench_until":"$NOW"}
EOF
cat >"$scratch/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"rate_limited","observed_at":"$NOW","usable_at":"$FUTURE","consecutive_failure_count":20}
EOF
# Recorded seat (bai) is wedged -> must fall through to the healthy fallback.
set +e
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat 2>/dev/null)
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "wedged recorded seat: --print-seat must exit  0, got rc=$rc"
[[ "$out" == "minimax	MiniMax-M3	fallback" ]] \
    || fail "wedged recorded seat must be skipped for healthy fallback, got: $out"
ok "wedged recorded seat skipped; healthy fallback picked"
# All providers wedged -> --print-seat exit  2.
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"overload_bench","observed_at":"$NOW","bench_until":"$NOW"}
EOF
cat >"$scratch/seats/minimax__mmx-2.json" <<EOF
{"provider":"minimax","model":"mmx-2","health_class":"overload_bench","observed_at":"$NOW","bench_until":"$NOW"}
EOF
set +e
out=$(SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
      SEAT_LEDGER_DIR="$scratch/seats" "$dispatch_bin" --print-seat 2>"$scratch/err5")
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "all-wedged: --print-seat must exit  2, got rc=$rc"
grep -q 'WALLED' "$scratch/err5" || fail "all-wedged: expected WALLED on stderr, got: $(cat "$scratch/err5")"
ok "all lanes wedged -> --print-seat exit  2 (escalate, don't dispatch into a storm)"
# Real dispatch path:None -> SKIP reason=all-seats-wedged (no spawn).
# Uses the AMX env + ALERT_REPAIR_NO_SPAWN so no live unit fires.

ALERT_REPAIR_PACKET_DIR="$scratch/packets5" \
CLASS_PARK_DIR="$scratch/park5" \
SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
SEAT_LEDGER_DIR="$scratch/seats" \
ALERT_REPAIR_CLAIM_BIN=/nonexistent \
AMX_STATUS=firing \
AMX_RECEIVER=repair-dispatch \
AMX_LABEL_service=fleet \
AMX_ALERT_1_LABEL_alertname=WedgedStormAlert \
AMX_ALERT_1_STATUS=firing \
AMX_ALERT_1_START="$NOW" \
AMX_ALERT_1_END=0 \
"$dispatch_bin" >"$scratch/out5b" 2>"$scratch/err5b" || true
if [ -f "$scratch/packets5/actions.log" ]; then
    grep -q 'SKIP alertname=WedgedStormAlert.*all-seats-wedged' "$scratch/packets5/actions.log" \
        || fail "all-wedged: real dispatch must SKIP (reason=all-seats-wedged): $(cat "$scratch/packets5/actions.log")"
else
    fail "all-wedged: expected actions.log at $scratch/packets5/actions.log"
fi
ok "all-wedged: real dispatch path refuses(SKIP all-seats-wedged, no spawn)"
