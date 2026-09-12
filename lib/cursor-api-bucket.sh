#!/usr/bin/env bash
# cursor-api-bucket.sh — Cursor Ultra included-API-bucket spend figure
# (fleet-ops#4566 / #4621).
#
# Sourced by measure.sh, bin/fleet-prepaid-util-canary, and lib/litellm-seat.sh
# so the judge-facing `usd_today` / `cursor_today` number is the trailing-24h
# delta of Cursor's own GetCurrentPeriodUsage included-API bucket — never the
# token-derived 0.000000 that cursor-cli sessions write (no usage tokens, no
# cost card). Cycle-to-date is a separate field (cursor_api_cycle_usd); it is
# NOT usd_today.
#
# Also runnable:
#   bash lib/cursor-api-bucket.sh           # print cursor_today figure
#   bash lib/cursor-api-bucket.sh --cycle   # print cycle-to-date
#   bash lib/cursor-api-bucket.sh --help
#
# Environment:
#   PI_PACKET_STATE          prepaid-spend/ + prepaid-usage/ root
#   FLEET_PREPAID_SPEND_DIR  override prepaid-spend dir (canary test seam)
#   CURSOR_TODAY_MIN_H       min history age in hours (default 24)
#
# Reconciliation (one command, credential never printed):
#   token=$(jq -r .accessToken ~/.config/cursor/auth.json)
#   curl -s -X POST -H "Authorization: Bearer $token" \
#     -H 'Content-Type: application/json' -d '{}' \
#     https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage \
#     | jq '.planUsage | {apiPercentUsed, limit}'
#   apiPercentUsed x (limit/100) = api_bucket_used_usd = cursor_api_cycle_usd.

cursor_api_bucket_dir() {
    local state_dir
    state_dir="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
    printf '%s' "${FLEET_PREPAID_SPEND_DIR:-$state_dir/prepaid-spend}"
}

# Cycle-to-date included-API-bucket spend, or UNAVAILABLE:<why>.
cursor_api_cycle_usd() {
    local state_json v
    state_json="$(cursor_api_bucket_dir)/cursor.json"
    [[ -f "$state_json" ]] || { echo "UNAVAILABLE:no-cursor-state"; return 0; }
    v=$(jq -r '.api_bucket_used_usd // empty' "$state_json" 2>/dev/null || true)
    [[ -n "$v" ]] || { echo "UNAVAILABLE:no-api-bucket-field"; return 0; }
    printf '%s\n' "$v"
}

# Trailing-24h delta of the cycle-to-date figure, or UNAVAILABLE:<why>.
# Never prints a fabricated 0.000000: a missing / warming / reset window is
# a label, not a number. Appends one history sample per call (deduped at 300s).
cursor_today_figure() {
    local spend_dir hist now_s latest_usd latest_s line ts used base_ts base_usd last_ts
    local state_json min_age_s cycle_end_s
    spend_dir="$(cursor_api_bucket_dir)"
    hist="$spend_dir/cursor-history.jsonl"
    state_json="$spend_dir/cursor.json"
    [[ -f "$state_json" ]] || { echo "UNAVAILABLE:no-cursor-state"; return 0; }
    latest_usd=$(jq -r '.api_bucket_used_usd // empty' "$state_json" 2>/dev/null || true)
    latest_s=$(jq -r '.updated_s // empty' "$state_json" 2>/dev/null || true)
    [[ -n "$latest_usd" && -n "$latest_s" ]] || { echo "UNAVAILABLE:no-api-bucket-field"; return 0; }
    now_s=$(date -u +%s)
    mkdir -p "$spend_dir" 2>/dev/null || true
    last_ts=0
    [[ -f "$hist" ]] && last_ts=$(tail -n 1 "$hist" 2>/dev/null | jq -r '.updated_s // 0' 2>/dev/null || echo 0)
    if (( now_s - last_ts >= 300 )); then
        printf '{"updated_s":%s,"api_bucket_used_usd":%s}\n' "$latest_s" "$latest_usd" >> "$hist" 2>/dev/null || true
    fi
    min_age_s=$(( ${CURSOR_TODAY_MIN_H:-24} * 3600 ))
    base_ts=""; base_usd=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        ts=$(printf '%s' "$line" | jq -r '.updated_s // 0' 2>/dev/null || echo 0)
        used=$(printf '%s' "$line" | jq -r '.api_bucket_used_usd // 0' 2>/dev/null || echo 0)
        if (( now_s - ts >= min_age_s )); then base_ts=$ts; base_usd=$used; fi
    done < "$hist"
    if [[ -z "$base_ts" ]]; then
        echo "UNAVAILABLE:cursor-history-warming"
        return 0
    fi
    cycle_end_s=$(jq -r '.cycle_end_s // 0' "$state_json" 2>/dev/null || echo 0)
    if (( cycle_end_s > 0 && base_ts < cycle_end_s && now_s >= cycle_end_s )); then
        echo "UNAVAILABLE:cycle-reset-in-window"
        return 0
    fi
    awk -v n="$latest_usd" -v b="$base_usd" 'BEGIN{d=n-b; printf "%.4f", (d<0)?0:d}'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
cursor-api-bucket.sh — Cursor Ultra included-API-bucket spend figure

Usage:
  bash lib/cursor-api-bucket.sh           print trailing-24h delta (or UNAVAILABLE:<why>)
  bash lib/cursor-api-bucket.sh --cycle   print cycle-to-date api_bucket_used_usd
  bash lib/cursor-api-bucket.sh --help

Sourced by measure.sh, bin/fleet-prepaid-util-canary, and the retired routing lib.
The figure is Cursor GetCurrentPeriodUsage planUsage.apiPercentUsed x (limit/100),
written by fleet-prepaid-util-canary into prepaid-spend/cursor.json. Token-derived
usd_today for cursor is structurally 0 and must not be reported as fact
(fleet-ops#4621).
EOF
            exit 0
            ;;
        --cycle)
            cursor_api_cycle_usd
            ;;
        *)
            cursor_today_figure
            echo
            ;;
    esac
fi
