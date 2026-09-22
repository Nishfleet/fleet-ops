#!/usr/bin/env bash
# fleet-ops#7902 / fleet-ops#366: prevention gate for the unescaped %s escape family.
# fleet-ops#7800: also pins the transient-retry shape of the intake-repair lane —
# a 429 lane fault must retry instead of leaving the unit `failed` and locked
# out, while a 402 money-wall stays a distinct (permanent) class.
# Asserts the systemd unit template contains exactly 2 `date +%%s` (escaped)
# and ZERO unescaped `date +%s` occurrences, plus the pi-issue@-family retry
# keys with a start-limit burst wide enough for a provider-cooldown window.
set -euo pipefail

SERVICE_FILE="systemd/pi-intake-repair@.service"

if [[ ! -f "$SERVICE_FILE" ]]; then
    echo "FAIL: $SERVICE_FILE not found" >&2
    exit 1
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Count escaped occurrences (what we want)
escaped_count=$(grep -cF 'date +%%s' "$SERVICE_FILE" || true)
if [[ "$escaped_count" -ne 2 ]]; then
    echo "FAIL: expected exactly 2 'date +%%s' lines, found $escaped_count" >&2
    grep -nF 'date +%%s' "$SERVICE_FILE" >&2
    exit 1
fi

# Count unescaped occurrences (what we forbid)
unescaped_lines=$(grep -nF 'date +%s' "$SERVICE_FILE" || true)
unescaped_count=$(echo "$unescaped_lines" | grep -c '.' || true)
if [[ -n "$unescaped_lines" && "$unescaped_count" -gt 0 ]]; then
    echo "FAIL: found $unescaped_count unescaped 'date +%s' occurrence(s):" >&2
    echo "$unescaped_lines" >&2
    exit 1
fi

echo "OK: $escaped_count escaped 'date +%%s' line(s), 0 unescaped 'date +%s'"

# ---------------------------------------------------------------------------
# fleet-ops#7800: transient-retry shape. A 429 is a lane fault (transient),
# not a permanent failure: the unit must retry it rather than go `failed` and
# lock the lane out through the next provider-cooldown window.
# ---------------------------------------------------------------------------

unit_value() {
    # Last assignment of KEY= in the unit file, trimmed. Empty if absent.
    grep -E "^$1=" "$SERVICE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

restart=$(unit_value Restart)
restart_sec=$(unit_value RestartSec)
interval=$(unit_value StartLimitIntervalSec)
burst=$(unit_value StartLimitBurst)

[[ "$restart" == "on-failure" ]] || \
    fail "Restart= is '$restart', want on-failure (a 429 lane fault must be retried)"
[[ "$restart_sec" =~ ^[0-9]+$ ]] || \
    fail "RestartSec= is '$restart_sec', want a plain integer of seconds"
(( restart_sec > 0 )) || fail "RestartSec=$restart_sec must be positive"
# pi-intake@.timer fires every 5 min; a retry must not lag a whole tick.
(( restart_sec <= 300 )) || \
    fail "RestartSec=${restart_sec}s is slower than the 5-min pi-intake@ tick"
[[ "$burst" =~ ^[0-9]+$ ]] || fail "StartLimitBurst= is '$burst', want a plain integer"
(( burst >= 3 )) || fail "StartLimitBurst=$burst is below the pi-issue@ family burst (3)"

# Parse the StartLimit interval (systemd time span) to seconds. Accept a bare
# integer of seconds or the units the fleet uses (s/min/h).
interval_s=""
case "$interval" in
    *h)   interval_s=$(( ${interval%h} * 3600 )) ;;
    *min) interval_s=$(( ${interval%min} * 60 )) ;;
    *s)   interval_s=$(( ${interval%s} )) ;;
    '')   fail "StartLimitIntervalSec= is empty" ;;
    *)    [[ "$interval" =~ ^[0-9]+$ ]] && interval_s=$interval ;;
esac
[[ -n "$interval_s" ]] || fail "cannot parse StartLimitIntervalSec='$interval'"
(( interval_s <= 3600 )) || \
    fail "StartLimitIntervalSec=$interval (${interval_s}s) exceeds 1h — the old 6h lockout is the bug"

# A full-cooldown window must never exhaust the burst: with a flat RestartSec
# cadence the burst has to cover the whole interval, so the lane stays
# startable through any cooldown shorter than that window.
(( burst * restart_sec >= interval_s )) || \
    fail "StartLimitBurst=$burst x RestartSec=${restart_sec}s < StartLimitIntervalSec=${interval_s}s: a full window would lock the lane out"

# 429 -> lane-fault (transient, retryable); 402 -> money-wall (permanent).
HELPER="lib/seat_fault.py"
[[ -f "$HELPER" ]] || fail "$HELPER not found"
lane_verdict=$(printf '%s\n' \
    '429: litellm.RateLimitError: Error code: 429 - throttling_error; No deployments available for selected model, Try again in 60 seconds' \
    | python3 "$HELPER" --ledger /nonexistent --unit pi-intake-repair@fleet-ops.service --decided lane-fault 2>/dev/null)
grep -q 'verdict=lane-fault' <<<"$lane_verdict" || \
    fail "a 429 exit did not classify as the transient lane-fault: $lane_verdict"
money_verdict=$(printf '%s\n' \
    'HTTP 402 quota_exhausted: credit balance depleted' \
    | python3 "$HELPER" --ledger /nonexistent --unit pi-intake-repair@fleet-ops.service --decided money-wall 2>/dev/null)
grep -q 'verdict=money-wall' <<<"$money_verdict" || \
    fail "a 402 exit did not classify as the permanent money-wall: $money_verdict"

echo "OK: retry shape Restart=$restart RestartSec=${restart_sec}s StartLimitIntervalSec=$interval StartLimitBurst=$burst; 429 -> lane-fault, 402 -> money-wall"
exit 0