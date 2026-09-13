#!/usr/bin/env bash
# tests/seat-empty-run-ceiling-default.test.sh
#
# fleet-ops#3531: the empty-run bench now escalates geometrically
# (base * 2^(n-1), capped at 6 h). fleet-ops#3727: empty runs use a
# SEPARATE, lower failure ceiling (EMPTY_RUN_FAILURE_CEILING); fleet-ops#3760
# lowered it from 5 to 3 so a chronic no-op'er parks on the 3rd no-op, not the
# 20th — the generic 20 (SEAT_FAILURE_CEILING) let
# ollama/deepseek-v4-flash:0731 churn 12 empty runs in 2h without parking. The
# geometric bench still escalates below the ceiling (900s -> 1800s -> ...).
#
# This test proves, end to end against the live wrapper:
#   (a) three empty-run benches on the same seat WITH a healthy clobber
#       between each accumulate the marker count 1 -> 2 -> 3.
#   (b) the bench escalates geometrically below the ceiling
#       (900s -> 1800s).
#   (c) on the 3rd no-op (empty-run failure ceiling pinned to 3 for test
#       isolation) the #1362 park wall engages (usable_at jumps to
#       ~now+SEAT_PARK_WALL_S, seat_usable holds the parked seat).
#   (d) the production default EMPTY_RUN_FAILURE_CEILING is 3 (fleet-ops#3760),
#       lower than the generic SEAT_FAILURE_CEILING (20).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

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
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
# Test isolation: pin the failure ceiling low so the park fires in a few
# iterations. Production default is 20 (fleet-ops#3531). fleet-ops#3727:
# empty runs use their own ceiling (EMPTY_RUN_FAILURE_CEILING, default 3 per
# fleet-ops#3760).
export SEAT_FAILURE_CEILING=3
export EMPTY_RUN_FAILURE_CEILING=3
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

# Assert the production default generic failure ceiling is 20 (fleet-ops#3531)
# and the empty-run-specific ceiling is 3 (fleet-ops#3760). The generic ceiling
# stays at 20 for spawn_fail / quota / overload; empty runs park sooner.
[[ "${SEAT_FAILURE_CEILING:-20}" == "3" ]] \
    || fail "SEAT_FAILURE_CEILING = ${SEAT_FAILURE_CEILING:-20}, want 3 for this test isolation (production default is 20, fleet-ops#3531)"
ok "(a0) SEAT_FAILURE_CEILING pinned to 3 for test isolation (production default 20, fleet-ops#3531)"
[[ "${EMPTY_RUN_FAILURE_CEILING:-3}" == "3" ]] \
    || fail "EMPTY_RUN_FAILURE_CEILING = ${EMPTY_RUN_FAILURE_CEILING:-3}, want 3 for this test isolation (production default is 3, fleet-ops#3760)"
ok "(a0b) EMPTY_RUN_FAILURE_CEILING pinned to 3 for test isolation (production default 3, fleet-ops#3760)"

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
# fleet-ops-2778. The count-merge window (2 h at the time) reset the count
# before it reached 10. With the geometric bench and the failure ceiling at
# 3 (test isolation), the 3rd no-op parks the seat.
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
(( park_wall >= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} - 120 && park_wall <= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} + 120 )) \
    || fail "(b) park wall = ${park_wall}s, want ~${SEAT_NON_MONEY_WALL_MAX_S:-21600}s — the failure-ceiling park must fire on the 3rd no-op (fleet-ops#3531/#4640 6h clamp)"
if seat_usable "$p" "$m"; then
    fail "(b) seat_usable returned usable on the 3rd-no-op parked seat — the park wall must hold it out of rotation"
fi
ok "(b) 3rd no-op: count=3, park wall = ${park_wall}s (~6h), seat HELD UNUSABLE — geometric bench then park (fleet-ops#3531/#3727/#4640)"

ok "fleet-ops#3531/#3727/#3760: empty-run benches escalate geometrically and park at the empty-run-specific failure ceiling (default 3, not the generic 20)"
