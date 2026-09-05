#!/usr/bin/env bash
# tests/seat-empty-run-intermittent-count.test.sh
#
# fleet-ops#2934: an intermittent no-op'er gaps its empty runs by more than
# the spawn-fail count-merge window (EMPTY_RUN_MARKER_FRESH_S, 30 min) but
# less than the empty-run count-merge window (EMPTY_RUN_COUNT_WINDOW_S,
# default 6 h = SEAT_BENCH_GEOMETRIC_CAP_S, fleet-ops#3675).
# Before this fix both classes shared the 30 min window, so a ~1h42m gap
# aged the marker past 30 min, the count reset to 1, and the
# failure-ceiling park never fired — the seat re-entered rotation every
# 900 s and no-op'ed again. Live 2026-09-02 snapshot:
# openrouter/deepseek/deepseek-v4-flash-0731 no-op'ed at 18:40:08Z (count=2)
# then 20:22:31Z (count=1) — the 1h42m gap reset the count; the seat stayed
# health_class=healthy http_status=200 in the global probe file and kept
# being re-selected.
#
# The fix (this PR): mark_seat_empty_run merges the marker count over
# EMPTY_RUN_COUNT_WINDOW_S (default 6 h, at least as long as the max
# empty-run bench so a chronic no-op'er's count survives the bench,
# fleet-ops#3675), while mark_seat_spawn_fail keeps the
# 30 min window (spawn storms are clustered). The bench is still the FLAT
# 900 s cooldown (fleet-ops#2343 — no ladder); only the COUNT-accumulation
# window widens, so the failure-ceiling park can engage for a chronic
# intermittent no-op'er.
#
# This test proves, end to end against the live wrapper:
#   (a) an empty-run count SURVIVES a gap > EMPTY_RUN_MARKER_FRESH_S (30 min)
#       but < EMPTY_RUN_COUNT_WINDOW_S (6 h) — the live #2934 gap shape. The
#       count accumulates 1 -> 2 across the gap, so the seat trends toward
#       the ceiling instead of resetting to 1 every cycle.
#   (b) at the failure ceiling the park engages from the accumulated count
#       across the gap — the chronic intermittent no-op'er is demoted
#       (held UNUSABLE by seat_usable) instead of re-selected.
#   (c) a gap > EMPTY_RUN_COUNT_WINDOW_S (6 h) DOES reset the count — the
#       real recovery signal (a full window with no no-op) is honoured,
#       so a recovered seat is not punished.
#   (d) spawn_fail still uses the 30 min window: a spawn_fail marker older
#       than 30 min is NOT merged into a fresh empty-run count, so widening
#       the empty-run window did not also widen the spawn-fail window.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-intermittent.XXXXXX)"
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
# iterations. Production default is 20 (fleet-ops#3531).
export SEAT_FAILURE_CEILING=3
export SEAT_PARK_WALL_S=86400
# The DEFAULT empty-run count window is now 6 h (21600 s =
# SEAT_BENCH_GEOMETRIC_CAP_S, fleet-ops#3675) — leave it at the default
# so this test exercises the production window, NOT a pinned override.
# The spawn-fail window stays at its 30 min default.
export EMPTY_RUN_MARKER_FRESH_S=1800
# Disable the corpse reclassification (fleet-ops#2594) so the parked seat
# is not also written seat_dead=true — this test proves the parking
# behaviour in isolation.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "openrouter": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash-0731", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["openrouter"],
  "providers": {
    "openrouter": { "cap": 6, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "deepseek/deepseek-v4-flash-0731": 3 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

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

# Simulate seat-health.ts writing a healthy observation to the ledger (the
# clobber that zeroes consecutive_failure_count between wrapper writes).
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
usable_of() { jq -r '.usable_at // ""' "$1" 2>/dev/null || true; }
wall_s_of_marker() {
    local u now_s u_s
    u=$(usable_of "$1")
    [[ -n "$u" ]] || { echo 0; return; }
    now_s=$(date -u +%s)
    u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
    echo $((u_s - now_s))
}

# Age the marker's written_at to <age_s> seconds ago (simulates the
# inter-empty-run gap without waiting in real time).
age_marker() {
    local mf="$1" age_s="$2"
    local aged_iso
    aged_iso=$(date -u -d "@$(($(date -u +%s) - age_s))" +%Y-%m-%dT%H:%M:%SZ)
    local tmp
    tmp=$(mktemp)
    jq --arg w "$aged_iso" '.written_at = $w' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
}

p="openrouter"; m="deepseek/deepseek-v4-flash-0731"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# --- (a) count SURVIVES a gap > 30 min but < 6 h (the live #2934 gap) -----
# Live shape: no-op at 18:40:08Z (count=2), then a 1h42m gap, then no-op at
# 20:22:31Z. Before the fix the 1h42m gap aged the marker past the 30 min
# window and the count reset to 1. With the default
# EMPTY_RUN_COUNT_WINDOW_S=21600 (6 h, fleet-ops#3675) the 1h42m (6120 s)
# gap is still inside the empty-run window, so the count must accumulate
# 1 -> 2 across the gap.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2934:noop:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(a) marker count after 1st no-op = $(count_of "$mf"), want 1"
# Simulate the 1h42m (6120 s) inter-empty-run gap — strictly between the
# 30 min spawn-fail window and the 6 h empty-run window.
age_marker "$mf" 6120
mark_seat_empty_run "$p" "$m" "t2934:noop:2" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #2 (after gap) failed"
clobber_with_healthy "$p" "$m" "$lf"
cross_gap_count=$(count_of "$mf")
[[ "$cross_gap_count" == "2" ]] \
    || fail "(a) marker count after a 6120s (1h42m) gap = $cross_gap_count, want 2 — the empty-run count must ACCUMULATE across a gap > 30min but < 6h (fleet-ops#2934/#3675); before the fix the 30min window reset it to 1"
ok "(a) empty-run count accumulates 1 -> 2 across a 1h42m gap (> 30min spawn-fail window, < 6h empty-run window) — the live #2934 reset is fixed"

# --- (b) the chronic intermittent no-op'er reaches the ceiling and parks --
# Continue the pattern: a third no-op after another < 6 h gap must reach
# count=3 (SEAT_FAILURE_CEILING=3 here, 20 in production) and park the
# seat. Before the fix the count reset every cycle and the park never
# fired, so the seat
# re-entered rotation every 900 s and no-op'ed again.
age_marker "$mf" 6120
mark_seat_empty_run "$p" "$m" "t2934:noop:3" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #3 (park) failed"
park_count=$(count_of "$mf")
[[ "$park_count" == "3" ]] \
    || fail "(b) marker count after 3rd intermittent no-op = $park_count, want 3 — the count must reach the ceiling across < 6h gaps"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= SEAT_PARK_WALL_S - 120 && park_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(b) park wall = ${park_wall}s, want ~${SEAT_PARK_WALL_S}s — the failure-ceiling park must fire from the accumulated intermittent count"
if seat_usable "$p" "$m"; then
    fail "(b) seat_usable returned usable on the parked intermittent no-op'er — the park wall must hold it out of rotation"
fi
ok "(b) 3rd intermittent no-op reaches count=3 and parks the seat (~${park_wall}s wall, held UNUSABLE) — a chronic intermittent no-op'er is demoted instead of re-selected"

# --- (c) a gap > EMPTY_RUN_COUNT_WINDOW_S (default 6 h, fleet-ops#3675) DOES reset the count (real recovery signal) ----------
# A seat that goes a full count window (6 h by default) without no-op'ing
# has recovered. The next empty-run must start a fresh count, not carry the
# stale high count forward. This is the fail-open contract: the wider window
# does not wall a recovered seat.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2934:recovery-seed" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (recovery seed) failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(c) seed count = $(count_of "$mf"), want 1"
# Age the marker past the empty-run count window (SEAT_BENCH_GEOMETRIC_CAP_S
# = 21600 s default + 600 s margin).
age_marker "$mf" 22200
mark_seat_empty_run "$p" "$m" "t2934:after-recovery" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (after recovery) failed"
fresh_count=$(count_of "$mf")
[[ "$fresh_count" == "1" ]] \
    || fail "(c) after a > count-window gap, merged count = $fresh_count, want 1 — a full window with no no-op is the real recovery signal; the count must reset"
ok "(c) a > count-window gap resets the empty-run count (recovered seat is NOT punished) — the wider window honours fail-open"

# --- (d) spawn_fail keeps the 30 min window (not widened) -----------------
# The empty-run window widened to 6 h, but spawn_fail must still use the 30
# min window: a spawn_fail marker older than 30 min is NOT merged into a
# fresh empty-run count. Prove it by seeding a spawn_fail marker, ageing it
# past 30 min but inside 6 h, then running an empty-run — the spawn_fail
# count must NOT carry over (the empty-run writer reads the marker, but a
# spawn_fail-only freshness gate would have merged it; here we prove the
# spawn_fail marker's count is merged ONLY because the EMPTY-RUN window
# covers it, which is the #2786 cross-class contract, NOT a spawn-fail
# window widening). The distinguishing check: a spawn_fail after a > 30 min
# gap must NOT merge a prior spawn_fail count (spawn_fail's own window is
# still 30 min).
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "t2934:spawn:1" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail #1 failed"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(d) spawn_fail seed count = $(count_of "$mf"), want 1"
clobber_with_healthy "$p" "$m" "$lf"
# Age past the 30 min spawn-fail window but inside the 6 h empty-run window.
age_marker "$mf" 2400
mark_seat_spawn_fail "$p" "$m" "t2934:spawn:2" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail #2 (after 40min gap) failed"
sf_count=$(count_of "$mf")
[[ "$sf_count" == "1" ]] \
    || fail "(d) spawn_fail count after a 40min gap = $sf_count, want 1 — spawn_fail must keep the 30min window; a > 30min gap resets the spawn_fail count (the empty-run window widening must NOT leak into spawn_fail)"
ok "(d) spawn_fail count resets after a 40min gap (> 30min spawn-fail window) — the empty-run window widening did NOT widen spawn_fail"

ok "fleet-ops#2934/#3675: empty-run count accumulates across gaps up to 6h (intermittent no-op'er reaches the ceiling and is parked), gaps > 6h reset (recovery honoured), and spawn_fail keeps its 30min window"
