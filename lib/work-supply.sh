# shellcheck shell=bash
# lib/work-supply.sh
#
# Shared hours-of-work math for the 24h/12h drain trigger (fleet-ops#540,
# ledger 2026-08-26 work supply rev). Sourced by fleet-work-supply-canary
# and fleet-heartbeat-low-water-mark. Never executed directly.
#
# Remaining hours = ceil(ready / drain_per_hour) at the measured close
# rate over WINDOW_H (default 6). A window with zero closes falls back
# to 1 issue/hour (the old count-as-hours proxy) so a stall does not
# look like an infinite buffer. Ready=0 is famine (0 hours).
#
# action:
#   hours <  GOHAM_H (12) -> go-ham
#   hours >= REST_H  (24) -> rest
#   else                  -> generate

WORK_SUPPLY_WINDOW_H="${FLEET_WORK_SUPPLY_WINDOW_H:-6}"
WORK_SUPPLY_GOHAM_H="${FLEET_WORK_SUPPLY_GOHAM_H:-12}"
WORK_SUPPLY_REST_H="${FLEET_WORK_SUPPLY_REST_H:-24}"

# work_supply_hours <ready> <closed_in_window> [window_h]
# Integer ceiling hours of remaining work.
work_supply_hours() {
    local ready="$1" closed="$2" window="${3:-$WORK_SUPPLY_WINDOW_H}"
    case "$ready" in
        ''|*[!0-9]*) printf '0\n'; return 0 ;;
    esac
    case "$closed" in
        ''|*[!0-9]*) closed=0 ;;
    esac
    case "$window" in
        ''|*[!0-9]*) window=6 ;;
    esac
    if [ "$window" -le 0 ]; then
        window=6
    fi
    if [ "$ready" -eq 0 ]; then
        printf '0\n'
        return 0
    fi
    if [ "$closed" -eq 0 ]; then
        printf '%s\n' "$ready"
        return 0
    fi
    printf '%s\n' $(( (ready * window + closed - 1) / closed ))
}

# work_supply_action <hours> [goham_h] [rest_h]
work_supply_action() {
    local hours="$1"
    local goham="${2:-$WORK_SUPPLY_GOHAM_H}"
    local rest="${3:-$WORK_SUPPLY_REST_H}"
    case "$hours" in
        ''|*[!0-9]*) hours=0 ;;
    esac
    case "$goham" in
        ''|*[!0-9]*) goham=12 ;;
    esac
    case "$rest" in
        ''|*[!0-9]*) rest=24 ;;
    esac
    if [ "$hours" -lt "$goham" ]; then
        printf 'go-ham\n'
    elif [ "$hours" -ge "$rest" ]; then
        printf 'rest\n'
    else
        printf 'generate\n'
    fi
}

# work_supply_closed_in_window <json> <window_h> [now_epoch]
# Count objects whose closedAt is within window_h hours of now.
work_supply_closed_in_window() {
    local json="$1" window_h="$2" now_s="${3:-}"
    local cutoff ts s n=0
    case "$window_h" in
        ''|*[!0-9]*) window_h=6 ;;
    esac
    if [ -z "$now_s" ]; then
        now_s=$(date -u +%s)
    fi
    cutoff=$((now_s - window_h * 3600))
    while IFS= read -r ts || [ -n "$ts" ]; do
        [ -n "$ts" ] || continue
        s=$(date -u -d "$ts" +%s 2>/dev/null || echo "")
        case "$s" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$s" -ge "$cutoff" ]; then
            n=$((n + 1))
        fi
    done < <(printf '%s\n' "$json" | jq -r '.[].closedAt // empty' 2>/dev/null || true)
    printf '%s\n' "$n"
}
