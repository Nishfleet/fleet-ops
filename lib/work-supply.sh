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

# work_supply_claimed_in_window <repo> [window_h]
# Count `claimed+spawned` lines in the pi-intake@<repo>.service journal within
# window_h hours. The intake journal is the true drain signal for the fleet:
# an agent-ready issue stays OPEN for hours after it is claimed until its PR
# merges, so the closed-in-window proxy is 0 even at a ~16/h spawn rate. The
# journal's claimed+spawned count is that drain (fleet-ops#4450).
# Overridable via WORK_SUPPLY_CLAIMED_COUNT (tests + offline fixtures). 0 on
# any journal read failure (empty result is the caller's "no fallback" cue).
work_supply_claimed_in_window() {
    local repo="$1" window="${2:-$WORK_SUPPLY_WINDOW_H}" n
    if [[ -n "${WORK_SUPPLY_CLAIMED_COUNT:-}" ]]; then
        printf '%s\n' "$WORK_SUPPLY_CLAIMED_COUNT"
        return 0
    fi
    case "$window" in
        ''|*[!0-9]*) window=6 ;;
    esac
    [ "$window" -le 0 ] && window=6
    n=$(journalctl --user -u "pi-intake@${repo}.service" \
        --since "${window} hours ago" --no-pager 2>/dev/null \
        | grep -Fc 'claimed+spawned' 2>/dev/null || true)
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s\n' "$n"
}

# Globals set by work_supply_hours so callers can log the drain source and the
# fractional runway (`ready / drain_per_hour`) without duplicating the math.
#   WORK_SUPPLY_DRAIN_SOURCE = fetch | intake-journal | fallback
#   WORK_SUPPLY_RUNWAY_H      = ready / drain_per_hour (1 decimal)
: "${WORK_SUPPLY_DRAIN_SOURCE:=fallback}"
: "${WORK_SUPPLY_RUNWAY_H:=}"

# work_supply_hours <ready> <closed_in_window> [window_h] [repo]
# Integer ceiling hours of remaining work at the measured drain rate
# (= ceil ready / drain_per_hour, the drain being closed/window).
#
# Drain of record (fleet-ops#4450):
#   - closed_in_window > 0   -> closed/window rate      (source=fetch)
#   - else repo supplied and the pi-intake@<repo> journal shows
#       claimed+spawned      -> claims/window rate      (source=intake-journal)
#   - else                    -> the old 1/h count-as-hours proxy
#                                (source=fallback)
# Sets WORK_SUPPLY_DRAIN_SOURCE and WORK_SUPPLY_RUNWAY_H for the caller's log.
work_supply_hours() {
    local ready="$1" closed="$2" window="${3:-$WORK_SUPPLY_WINDOW_H}" repo="${4:-}"
    local claimed=0 denom=0
    WORK_SUPPLY_DRAIN_SOURCE=fallback
    WORK_SUPPLY_RUNWAY_H=""
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
        WORK_SUPPLY_RUNWAY_H="0.0"
        printf '0\n'
        return 0
    fi
    if [ "$closed" -gt 0 ]; then
        denom=$closed
        WORK_SUPPLY_DRAIN_SOURCE=fetch
    elif [ -n "$repo" ]; then
        claimed=$(work_supply_claimed_in_window "$repo" "$window")
        if [ "$claimed" -gt 0 ]; then
            denom=$claimed
            WORK_SUPPLY_DRAIN_SOURCE=intake-journal
        fi
    fi
    if [ "$denom" -lt 1 ]; then
        # No measurable drain (no closes in window, no journal, or repo not
        # given by a caller that predates the fallback). Keep the 1/h proxy.
        WORK_SUPPLY_DRAIN_SOURCE=fallback
        WORK_SUPPLY_RUNWAY_H="$ready"
        printf '%s\n' "$ready"
        return 0
    fi
    # Fractional runway for the log: ready / (denom/window) = ready*window/denom.
    WORK_SUPPLY_RUNWAY_H=$(awk -v r="$ready" -v d="$denom" -v w="$window" \
        'BEGIN{printf "%.1f", r*w/d}')
    printf '%s\n' $(( (ready * window + denom - 1) / denom ))
}

# work_supply_label_budget <repo>
# Per-run scout label_budget from the drain rate (fleet-ops#4450 item 3).
# For PRODUCT repos only: max(8, ceil(drain_per_hour * 4)), capped at 40.
# Control-plane / non-product repos (fleet-ops) stay at the floor 8 so the
# fleet's self-maintenance share can only fall, never rise. Fail-closed:
# an unknown product status or unmeasurable drain resolves to the 8 floor.
work_supply_label_budget() {
    local repo="$1" drain budget
    local cap=40 floor=8 mult=4
    # repo_is_product is defined in lib/litellm-seat.sh (sourced by pi-scout-run
    # and the intake tick). When it is absent (standalone work-supply use)
    # fail closed to the floor so a non-product budget is never inflated.
    if ! declare -F repo_is_product >/dev/null 2>&1; then
        printf '%s\n' "$floor"
        return 0
    fi
    if ! repo_is_product "$repo"; then
        printf '%s\n' "$floor"
        return 0
    fi
    drain=$(work_supply_drain_per_hour "$repo" 2>/dev/null || printf '%s\n' "$floor")
    case "$drain" in
        ''|*[!0-9.]*) drain=$floor ;;
    esac
    budget=$(awk -v d="$drain" -v m="$mult" \
        'BEGIN{s=int(d*m); if(s<d*m)s++; if(s<0)s=0; print s}')
    case "$budget" in
        ''|*[!0-9]*) budget=$floor ;;
    esac
    # Floor: even an unmeasured/zero drain (1/h) yields max(8, ceil(1*4)) = 8.
    [ "$budget" -lt "$floor" ] && budget=$floor
    if [ "$budget" -gt "$cap" ]; then budget=$cap; fi
    printf '%s\n' "$budget"
}

# work_supply_drain_per_hour <repo> [window_h]
# Measured drain rate (issues/hour) over the window: closed-in-window rate
# first, then the intake-journal claims/hour, then a 1/h floor. Prints the
# decimal rate. Sets WORK_SUPPLY_DRAIN_SOURCE. Used by the label_budget
# derivation; the runway decision math lives in work_supply_hours.
work_supply_drain_per_hour() {
    local repo="$1" window="${2:-$WORK_SUPPLY_WINDOW_H}" closed claimed denom
    case "$window" in
        ''|*[!0-9]*) window=6 ;;
    esac
    [ "$window" -le 0 ] && window=6
    # closed-in-window needs the closed JSON; fall back to journal claims when
    # we cannot measure closes cheaply here (callers that already hold closed
    # should use work_supply_hours with repo, which is the runway decision).
    if [[ -n "${WORK_SUPPLY_CLOSED_COUNT:-}" ]]; then
        closed="$WORK_SUPPLY_CLOSED_COUNT"
    else
        closed=0
    fi
    if [ "$closed" -gt 0 ]; then
        WORK_SUPPLY_DRAIN_SOURCE=fetch
        awk -v d="$closed" -v w="$window" 'BEGIN{printf "%.4f", d/w}'
        return 0
    fi
    claimed=$(work_supply_claimed_in_window "$repo" "$window")
    if [ "$claimed" -gt 0 ]; then
        WORK_SUPPLY_DRAIN_SOURCE=intake-journal
        awk -v d="$claimed" -v w="$window" 'BEGIN{printf "%.4f", d/w}'
        return 0
    fi
    WORK_SUPPLY_DRAIN_SOURCE=fallback
    printf '1\n'
    return 0
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
