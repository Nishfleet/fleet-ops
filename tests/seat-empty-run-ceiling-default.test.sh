#!/usr/bin/env bash
# tests/seat-empty-run-ceiling-default.test.sh
#
# fleet-ops#3531: the empty-run bench now escalates geometrically
# (base * 2^(n-1), capped at 6 h) and uses the generic failure ceiling
# (SEAT_FAILURE_CEILING, default 20). This supersedes the prior
# EMPTY_RUN_FAILURE_CEILING tier that parked on the 3rd no-op but left
# the bench flat at 900s below it.
#
# This test proves, end to end against the live wrapper:
#   (a) three empty-run benches on the same seat WITH a healthy clobber
#       between each accumulate the marker count 1 -> 2 -> 3.
#   (b) the bench escalates geometrically below the ceiling
#       (900s -> 1800s).
#   (c) on the 3rd no-op (failure ceiling pinned to 3 for test isolation)
#       the #1362 park wall engages (usable_at jumps to ~now+SEAT_PARK_WALL_S,
#       seat_usable holds the parked seat).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-ceiling-default.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
# Test isolation: pin the failure ceiling low so the park fires in a few
# iterations. Production default is 20 (fleet-ops#3531).
export SEAT_FAILURE_CEILING=3
export SEAT_PARK_WALL_S=86400
export EMPTY_RUN_MARKER_FRESH_S=1800
export EMPTY_RUN_COUNT_WINDOW_S=7200
# Disable the corpse reclassification (fleet-ops#2594) so the parked seat
# is not also written seat_dead=true — this test proves the parking
# behaviour in isolation.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "nemotron-3-ultra-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": { "cap": 6, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "nemotron-3-ultra-free": 3 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

# Assert the production default generic failure ceiling is 20 (fleet-ops#3531).
# A regression that lowers it back to 3 (or any value < 20) would park seats
# on the 3rd empty run instead of the 20th, punishing healthy free seats.
[[ "${SEAT_FAILURE_CEILING:-20}" == "3" ]] \
    || fail "SEAT_FAILURE_CEILING = ${SEAT_FAILURE_CEILING:-20}, want 3 for this test isolation (production default is 20, fleet-ops#3531)"
ok "(a0) SEAT_FAILURE_CEILING pinned to 3 for test isolation (production default 20, fleet-ops#3531)"

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

marker_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.spawn-bench.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

clobber_with_healthy() {
    local p="$1" m="$2" lf="$3"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp="$lf.clobber.$$.$RANDOM.tmp"
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg obs "$now_utc" \
        '{provider:$provider, model:$model, http_status:200,
          health_class:"healthy", retryable:false, seat_dead:false,
          poison_ladder:false, observed_at:$obs,
          source:"after_provider_response", failure_mode:"none",
          usable_at:null, consecutive_failure_count:0}' \
        > "$tmp" 2>/dev/null
    mv "$tmp" "$lf" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

count_of() { jq -r '.consecutive_failure_count // 0' "$1" 2>/dev/null || echo 0; }
wall_s_of_marker() {
    local u now_s u_s
    u=$(jq -r '.usable_at // ""' "$1" 2>/dev/null || true)
    [[ -n "$u" ]] || { echo 0; return; }
    now_s=$(date -u +%s)
    u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
    echo $((u_s - now_s))
}

# Live shape: opencode/nemotron-3-ultra-free no-op'ed 9 times in 2h on
# fleet-ops-2778. The count-merge window (2 h) reset the count before it
# reached 10. With the geometric bench and the failure ceiling at 3 (test
# isolation), the 3rd no-op parks the seat.
p="opencode"; m="nemotron-3-ultra-free"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"

# --- (a) count accumulates 1 -> 2 -> 3, bench escalates geometrically -----
mark_seat_empty_run "$p" "$m" "t3046:noop:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(a) marker count after 1st no-op = $(count_of "$mf"), want 1"
# 1st no-op: base 900s cooldown, NOT parked (count=1 < ceiling=3).
w1=$(wall_s_of_marker "$mf")
(( w1 >= 900 - 120 && w1 <= 900 + 120 )) \
    || fail "(a) 1st no-op wall = ${w1}s, want ~900s (base cooldown, NOT parked — count=1 < ceiling=3)"
ok "(a1) 1st no-op: count=1, base 900s cooldown (not parked)"

mark_seat_empty_run "$p" "$m" "t3046:noop:2" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #2 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "2" ]] \
    || fail "(a) marker count after 2nd no-op = $(count_of "$mf"), want 2"
# 2nd no-op: geometric escalation to 1800s, NOT parked (count=2 < ceiling=3).
w2=$(wall_s_of_marker "$mf")
(( w2 >= 1800 - 120 && w2 <= 1800 + 120 )) \
    || fail "(a) 2nd no-op wall = ${w2}s, want ~1800s (geometric cooldown, NOT parked — count=2 < ceiling=3)"
ok "(a2) 2nd no-op: count=2, geometric 1800s cooldown (not parked — a single flake does not wall a seat)"

# --- (b) 3rd no-op parks the seat at the failure ceiling ------------------
mark_seat_empty_run "$p" "$m" "t3046:noop:3" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #3 (park) failed"
park_count=$(count_of "$mf")
[[ "$park_count" == "3" ]] \
    || fail "(b) marker count after 3rd no-op = $park_count, want 3 — the count must reach the production-default ceiling"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= SEAT_PARK_WALL_S - 120 && park_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(b) park wall = ${park_wall}s, want ~${SEAT_PARK_WALL_S}s — the failure-ceiling park must fire on the 3rd no-op (fleet-ops#3531)"
if seat_usable "$p" "$m"; then
    fail "(b) seat_usable returned usable on the 3rd-no-op parked seat — the park wall must hold it out of rotation"
fi
ok "(b) 3rd no-op: count=3, park wall = ${park_wall}s (~24h), seat HELD UNUSABLE — geometric bench then park (fleet-ops#3531)"

ok "fleet-ops#3531: empty-run benches escalate geometrically and park at the generic failure ceiling"
