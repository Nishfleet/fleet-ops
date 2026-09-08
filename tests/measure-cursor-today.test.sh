#!/usr/bin/env bash
# tests/measure-cursor-today.test.sh
#
# fleet-ops#4566: measure.sh's usd_24h line carries cursor_today traceable to
# Cursor's own GetCurrentPeriodUsage number (via the prepaid-util-canary's
# prepaid-spend/cursor.json api_bucket_used_usd), never a fabricated $0:
#   1. No cursor state -> cursor_today=UNAVAILABLE:no-cursor-state.
#   2. Fresh state, no 24h-old history -> UNAVAILABLE:cursor-history-warming
#      and cursor_api_cycle_usd carries the real cycle-to-date figure.
#   3. History with a sample >= 24h old -> cursor_today = the 24h delta.
#   4. Cycle reset inside the window -> UNAVAILABLE:cycle-reset-in-window.
#   5. The reconciliation command in measure.sh's comments references
#      GetCurrentPeriodUsage (a human can re-derive the number).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
measure="$repo_root/measure.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$measure" ]] || fail "measure.sh not found"
command -v jq >/dev/null 2>/dev/null || fail "jq required"

scratch="$(mktemp -d -t measure-cursor.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$scratch/state/prepaid-spend"

run_measure() {
    FLEET_SESSIONS_DIR="$scratch/empty-sessions" MEASURE_REPOS="" \
        bash "$measure" 2>/dev/null | grep -E '^usd_24h:'
}

mkdir -p "$scratch/empty-sessions"

usd_line() {
    local line
    line="$(run_measure)" || fail "no usd_24h line"
    printf '%s\n' "$line"
}

# 1. No cursor state.
line="$(usd_line)"
grep -q 'cursor_today=UNAVAILABLE:no-cursor-state' <<<"$line" \
    || fail "case 1: expected UNAVAILABLE:no-cursor-state, got: $line"

# 2. Fresh state, no history -> warming label; cycle figure is real.
now_s=$(date -u +%s)
cat > "$scratch/state/prepaid-spend/cursor.json" <<EOF
{"provider":"cursor","spend_usd":0.0,"pool_usd":0.0,"cycle_end_s":$((now_s + 1200000)),
 "included_exhausted":0,"api_bucket_used_usd":11.36,"api_bucket_remaining_usd":388.64,
 "api_bucket_limit_usd":400.0,"total_percent_used":69.35,"updated_s":$now_s,
 "observed_at":"now","source":"cursor-dashboard-getcurrentperiodusage"}
EOF
line="$(usd_line)"
grep -q 'cursor_today=UNAVAILABLE:cursor-history-warming' <<<"$line" \
    || fail "case 2: expected warming label, got: $line"
grep -q 'cursor_api_cycle_usd=11.36' <<<"$line" \
    || fail "case 2: cursor_api_cycle_usd must carry the real cycle-to-date figure, got: $line"
[[ -f "$scratch/state/prepaid-spend/cursor-history.jsonl" ]] \
    || fail "case 2: history file must be appended"
[[ "$(wc -l < "$scratch/state/prepaid-spend/cursor-history.jsonl")" -ge 1 ]] \
    || fail "case 2: history must have >=1 sample"

# 3. A >= 24h-old sample -> cursor_today = delta (11.36 - 5.00 = 6.36).
old_s=$((now_s - 25 * 3600))
cat > "$scratch/state/prepaid-spend/cursor-history.jsonl" <<EOF
{"updated_s":$old_s,"api_bucket_used_usd":5.0}
{"updated_s":$((now_s - 300 - 1)),"api_bucket_used_usd":11.0}
EOF
line="$(usd_line)"
grep -q 'cursor_today=6.3600' <<<"$line" \
    || fail "case 3: expected delta 6.3600, got: $line"

# 4. Cycle reset inside the window -> labeled, never a fake delta.
cat > "$scratch/state/prepaid-spend/cursor.json" <<EOF
{"provider":"cursor","spend_usd":0.0,"pool_usd":0.0,"cycle_end_s":$((now_s - 3600)),
 "included_exhausted":0,"api_bucket_used_usd":11.36,"api_bucket_remaining_usd":388.64,
 "api_bucket_limit_usd":400.0,"total_percent_used":69.35,"updated_s":$now_s,
 "observed_at":"now","source":"cursor-dashboard-getcurrentperiodusage"}
EOF
cat > "$scratch/state/prepaid-spend/cursor-history.jsonl" <<EOF
{"updated_s":$old_s,"api_bucket_used_usd":5.0}
EOF
line="$(usd_line)"
grep -q 'cursor_today=UNAVAILABLE:cycle-reset-in-window' <<<"$line" \
    || fail "case 4: expected cycle-reset label, got: $line"

# 5. Reconciliation command is documented in measure.sh.
grep -q 'GetCurrentPeriodUsage' "$measure" \
    || fail "case 5: measure.sh must document the GetCurrentPeriodUsage reconciliation command"
grep -q 'apiPercentUsed' "$measure" \
    || fail "case 5: measure.sh must document apiPercentUsed x limit reconciliation"

ok "measure-cursor-today: all 5 cases pass"
