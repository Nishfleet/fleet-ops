#!/usr/bin/env bash
# tests/fleet-gap-closure-conference-senior-seat.test.sh
#
# fleet-ops#4211 (gap-audit conference dissent, senior, cycle 4):
# find_senior_seat, the live path in lib/litellm-seat.sh, emits the senior seat as
# provider<TAB>model. bin/fleet-gap-closure-conference used to parse that
# seat on '/', so BOTH SENIOR_PROVIDER and SENIOR_MODEL became the whole
# tab-separated string and the conference seat was unresolvable — the senior
# auditor preflight refused it (no health data) and dissented. This test
# locks the seat split so the senior auditor always lands on a real,
# preflight-usable cursor/cursor-grok-4.6-high provider+model.
#
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# Mirrors bin/fleet-gap-closure-conference: split on TAB (find_senior_seat live
# output) first, then fall back to '/' (config seats are slash-shaped).
seat_split() {
    local p m
    if [[ "$1" == *$'\t'* ]]; then
        p="${1%%$'\t'*}"
        m="${1#*$'\t'}"
    else
        p="${1%%/*}"
        m="${1#*/}"
    fi
    [ -n "$p" ] || p=cursor
    [ -n "$m" ] || m=cursor-grok-4.6-high
    printf '%s|%s\n' "$p" "$m"
}

# 1. TAB-shaped seat (what find_senior_seat emits) -> real provider+model
out="$(seat_split "$(printf 'cursor\tcursor-grok-4.6-high')")"
p="${out%%|*}"; m="${out#*|}"
if [[ "$p" == cursor && "$m" == cursor-grok-4.6-high \
      && "$p" != *$'\t'* && "$m" != *$'\t'* ]]; then
    ok "TAB-shaped senior seat splits to cursor / cursor-grok-4.6-high (real seat)"
else
    fail "TAB seat mis-split: got '$out'"
fi

# 2. slash-shaped seat (config senior_seats_in_order) -> real provider+model
out="$(seat_split 'cursor/cursor-grok-4.6-high')"
p="${out%%|*}"; m="${out#*|}"
if [[ "$p" == cursor && "$m" == cursor-grok-4.6-high ]]; then
    ok "slash-shaped senior seat splits to cursor / cursor-grok-4.6-high"
else
    fail "slash seat mis-split: got '$out'"
fi

# 3. the invented double-seat (both halves = whole tabbed string) must never
#    surface: every resolution is a real provider+model with no leftover tab.
for probe in 'cursor/cursor-grok-4.6-high' "$(printf 'cursor\tcursor-grok-4.6-high')"; do
    out="$(seat_split "$probe")"
    p="${out%%|*}"; m="${out#*|}"
    if [[ "$p" == cursor && "$m" == cursor-grok-4.6-high && "$m" != *$'\t'* ]]; then
        ok "no invented seat for '$probe' (resolved $p / $m)"
    else
        fail "invented seat surfaced for '$probe': '$out'"
    fi
done

echo "OK: fleet-gap-closure-conference-senior-seat.test.sh: senior seat split resolves fleet-ops#4211"
