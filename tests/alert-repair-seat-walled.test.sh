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
