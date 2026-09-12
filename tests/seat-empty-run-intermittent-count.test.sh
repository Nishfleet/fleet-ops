#!/usr/bin/env bash
# tests/seat-empty-run-intermittent-count.test.sh
#
# fleet-ops#2934: an intermittent no-op'er gaps its empty runs by more than
# the spawn-fail count-merge window (EMPTY_RUN_MARKER_FRESH_S, 30 min) but
# less than the empty-run count-merge window (EMPTY_RUN_COUNT_WINDOW_S,
# default 24 h = SEAT_PARK_WALL_S, fleet-ops#3666).
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
# EMPTY_RUN_COUNT_WINDOW_S (default 24 h = the park wall, so a chronic
# no-op'er's count survives the full failure-ceiling park, fleet-ops#3666),
# while mark_seat_spawn_fail keeps the
# 30 min window (spawn storms are clustered). The bench is still the FLAT
# 900 s cooldown (fleet-ops#2343 — no ladder); only the COUNT-accumulation
# window widens, so the failure-ceiling park can engage for a chronic
# intermittent no-op'er.
#
# This test proves, end to end against the live wrapper:
#   (a) an empty-run count SURVIVES a gap > EMPTY_RUN_MARKER_FRESH_S (30 min)
#       but < EMPTY_RUN_COUNT_WINDOW_S (24 h) — the live #2934 gap shape. The
#       count accumulates 1 -> 2 across the gap, so the seat trends toward
#       the ceiling instead of resetting to 1 every cycle.
#   (b) at the failure ceiling the park engages from the accumulated count
#       across the gap — the chronic intermittent no-op'er is demoted
#       (held UNUSABLE by seat_usable) instead of re-selected.
#   (c) a gap > EMPTY_RUN_COUNT_WINDOW_S (24 h) DOES reset the count — the
#       real recovery signal (a full park wall with no no-op) is honoured,
#       so a recovered seat is not punished.
#   (d) spawn_fail still uses the 30 min window: a spawn_fail marker older
#       than 30 min is NOT merged into a fresh spawn_fail count, so widening
#       the empty-run window did not also widen the spawn-fail window.
#   (e) empty_run -> spawn_fail cross-class: the count survives a > 30min gap
#       (fleet-ops#3749/#3849 — spawn-fail writer uses the empty-run window for
#       an empty_run marker so the cross-class count is not destroyed).
#   (f) spawn_fail -> spawn_fail still resets after > 30min (no leak from (e)).
#   (g) spawn_fail -> empty_run cross-class: a stale (>30min) spawn_fail marker
#       does NOT inflate a fresh empty-run count (fleet-ops#3749 symmetric —
#       empty-run writer uses the spawn-fail window for a spawn_fail marker).
#   (h) empty_run -> empty_run still uses 24h (class-aware fix did NOT narrow
#       the same-class empty_run window).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

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
export EMPTY_RUN_FAILURE_CEILING=3  # fleet-ops#3727: empty-run park uses its own ceiling
export SEAT_PARK_WALL_S=86400
# The DEFAULT empty-run count window is now 24 h (86400 s =
# SEAT_PARK_WALL_S, fleet-ops#3666) — leave it at the default
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

# --- (a) count SURVIVES a gap > 30 min but < 24 h (the live #2934 gap) ----
# Live shape: no-op at 18:40:08Z (count=2), then a 1h42m gap, then no-op at
# 20:22:31Z. Before the fix the 1h42m gap aged the marker past the 30 min
# window and the count reset to 1. With the default
# EMPTY_RUN_COUNT_WINDOW_S=86400 (24 h = SEAT_PARK_WALL_S, fleet-ops#3666) the
# 1h42m (6120 s) gap is still inside the empty-run window, so the count must
# accumulate 1 -> 2 across the gap.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2934:noop:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(a) marker count after 1st no-op = $(count_of "$mf"), want 1"
# Simulate the 1h42m (6120 s) inter-empty-run gap — strictly between the
# 30 min spawn-fail window and the 24 h empty-run window.
age_marker "$mf" 6120
mark_seat_empty_run "$p" "$m" "t2934:noop:2" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #2 (after gap) failed"
clobber_with_healthy "$p" "$m" "$lf"
cross_gap_count=$(count_of "$mf")
[[ "$cross_gap_count" == "2" ]] \
    || fail "(a) marker count after a 6120s (1h42m) gap = $cross_gap_count, want 2 — the empty-run count must ACCUMULATE across a gap > 30min but < 24h (fleet-ops#2934/#3675/#3666); before the fix the 30min window reset it to 1"
ok "(a) empty-run count accumulates 1 -> 2 across a 1h42m gap (> 30min spawn-fail window, < 24h empty-run window) — the live #2934 reset is fixed"

# --- (b) the chronic intermittent no-op'er reaches the ceiling and parks --
# Continue the pattern: a third no-op after another < 24 h gap must reach
# count=3 (SEAT_FAILURE_CEILING=3 here, 20 in production) and park the
# seat. Before the fix the count reset every cycle and the park never
# fired, so the seat
# re-entered rotation every 900 s and no-op'ed again.
age_marker "$mf" 6120
mark_seat_empty_run "$p" "$m" "t2934:noop:3" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #3 (park) failed"
park_count=$(count_of "$mf")
[[ "$park_count" == "3" ]] \
    || fail "(b) marker count after 3rd intermittent no-op = $park_count, want 3 — the count must reach the ceiling across < 24h gaps"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} - 120 && park_wall <= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} + 120 )) \
    || fail "(b) park wall = ${park_wall}s, want ~${SEAT_NON_MONEY_WALL_MAX_S:-21600}s — the failure-ceiling park must fire from the accumulated intermittent count (#4640 6h clamp)"
if seat_usable "$p" "$m"; then
    fail "(b) seat_usable returned usable on the parked intermittent no-op'er — the park wall must hold it out of rotation"
fi
ok "(b) 3rd intermittent no-op reaches count=3 and parks the seat (~${park_wall}s wall, held UNUSABLE) — a chronic intermittent no-op'er is demoted instead of re-selected"

# --- (c) a gap > EMPTY_RUN_COUNT_WINDOW_S (default 24 h = SEAT_PARK_WALL_S, fleet-ops#3666) DOES reset the count (real recovery signal) ----------
# A seat that goes a full count window (24 h by default — the park wall,
# fleet-ops#3666) without no-op'ing has recovered. The next empty-run must
# start a fresh count, not carry the stale high count forward. This is the
# fail-open contract: the wider window does not wall a recovered seat.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2934:recovery-seed" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (recovery seed) failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(c) seed count = $(count_of "$mf"), want 1"
# Age the marker past the empty-run count window (SEAT_PARK_WALL_S = 86400 s
# default + 600 s margin).
age_marker "$mf" 87000
mark_seat_empty_run "$p" "$m" "t2934:after-recovery" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (after recovery) failed"
fresh_count=$(count_of "$mf")
[[ "$fresh_count" == "1" ]] \
    || fail "(c) after a > count-window gap, merged count = $fresh_count, want 1 — a full window with no no-op is the real recovery signal; the count must reset"
ok "(c) a > count-window gap resets the empty-run count (recovered seat is NOT punished) — the wider window honours fail-open"

# --- (d) spawn_fail keeps the 30 min window (not widened) -----------------
# The empty-run window widened to 24 h, but spawn_fail must still use the 30
# min window: a spawn_fail marker older than 30 min is NOT merged into a
# fresh empty-run count. Prove it by seeding a spawn_fail marker, ageing it
# past 30 min but inside 24 h, then running an empty-run — the spawn_fail
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
# Age past the 30 min spawn-fail window but inside the 24 h empty-run window.
age_marker "$mf" 2400
mark_seat_spawn_fail "$p" "$m" "t2934:spawn:2" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail #2 (after 40min gap) failed"
sf_count=$(count_of "$mf")
[[ "$sf_count" == "1" ]] \
    || fail "(d) spawn_fail count after a 40min gap = $sf_count, want 1 — spawn_fail must keep the 30min window; a > 30min gap resets the spawn_fail count (the empty-run window widening must NOT leak into spawn_fail)"
ok "(d) spawn_fail count resets after a 40min gap (> 30min spawn-fail window) — the empty-run window widening did NOT widen spawn_fail"

# --- (e) empty_run -> spawn_fail cross-class: count survives a > 30min gap --
# fleet-ops#3749: the marker is a SINGLE file shared by mark_seat_empty_run
# and mark_seat_spawn_fail. Before the fix, mark_seat_spawn_fail used the
# 30 min spawn-fail window for ALL markers, including markers written by
# mark_seat_empty_run. A spawn-fail >30 min after an empty-run treated the
# empty-run marker as stale, reset the count to 1, and overwrote the file —
# destroying the empty-run count. Live: ollama/deepseek-v4-flash:0731
# reached count=5/backoff=14400s at 22:49Z, a spawn-fail ~37 min later
# reset the count to 1, and the next empty-run merged from the clobbered
# marker + ledger to count=4 — the count went BACKWARDS.
# The fix: mark_seat_spawn_fail uses the marker's failure_mode to select
# the freshness window. An empty_run marker uses EMPTY_RUN_COUNT_WINDOW_S
# (24 h); a spawn_fail marker uses EMPTY_RUN_MARKER_FRESH_S (30 min).
# This test proves: an empty-run count SURVIVES a > 30 min gap into a
# spawn-fail (the count accumulates 1 -> 2 across the gap), and the
# subsequent spawn-fail does NOT reset to 1.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t3749:noop:1" >/dev/null 2>&1 \
    || fail "(e) mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(e) empty-run seed count = $(count_of "$mf"), want 1"
# Age past the 30 min spawn-fail window but inside the 24 h empty-run window.
# This is the live #3749 gap shape: 37 min between the empty-run at 22:49Z
# and the spawn-fail at ~23:26Z.
age_marker "$mf" 2220  # 37 min
mark_seat_spawn_fail "$p" "$m" "t3749:spawn:after-gap" >/dev/null 2>&1 \
    || fail "(e) mark_seat_spawn_fail (after 37min gap) failed"
cross_sf_count=$(count_of "$mf")
[[ "$cross_sf_count" == "2" ]] \
    || fail "(e) spawn_fail count after a 37min gap from an empty-run marker = $cross_sf_count, want 2 — the empty-run count must ACCUMULATE across the cross-class gap (fleet-ops#3749); before the fix the 30min spawn-fail window reset it to 1"
ok "(e) empty_run -> spawn_fail: count accumulates 1 -> 2 across a 37min gap (> 30min spawn-fail window, < 24h empty-run window) — the cross-class count is NOT destroyed by the spawn-fail writer's 30min window"

# --- (f) spawn_fail -> spawn_fail still resets after > 30min (no leak) ------
# Prove the class-aware fix did NOT widen the spawn_fail -> spawn_fail window.
# A spawn_fail marker older than 30 min must still reset on the next
# spawn_fail (spawn storms are clustered). This re-checks (d) but with the
# class-aware code path active, so the failure_mode read + window selection
# cannot accidentally widen the same-class case.
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "t3749:spawn:1" >/dev/null 2>&1 \
    || fail "(f) mark_seat_spawn_fail #1 failed"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(f) spawn_fail seed count = $(count_of "$mf"), want 1"
clobber_with_healthy "$p" "$m" "$lf"
age_marker "$mf" 2400  # 40 min — past 30 min spawn-fail window
mark_seat_spawn_fail "$p" "$m" "t3749:spawn:2" >/dev/null 2>&1 \
    || fail "(f) mark_seat_spawn_fail #2 (after 40min gap) failed"
sf2_count=$(count_of "$mf")
[[ "$sf2_count" == "1" ]] \
    || fail "(f) spawn_fail -> spawn_fail count after a 40min gap = $sf2_count, want 1 — the class-aware fix must NOT widen the same-class spawn_fail window; spawn storms are clustered and > 30min resets"
ok "(f) spawn_fail -> spawn_fail still resets after a 40min gap — the class-aware fix did NOT leak the empty-run window into same-class spawn_fail"

# --- (g) spawn_fail -> empty_run cross-class: stale spawn_fail does NOT inflate --
# fleet-ops#3749 (symmetric completion): #3849 made mark_seat_spawn_fail
# class-aware (an empty_run marker uses the 24h window, a spawn_fail marker
# uses the 30min window). The symmetric gap: mark_seat_empty_run used the 24h
# EMPTY_RUN_COUNT_WINDOW_S for ALL markers, including spawn_fail markers. A
# spawn_fail marker older than the 30min spawn-fail window but inside 24h was
# merged into a fresh empty-run count, inflating it — the very inflation the
# comment block warns against ("a 24h spawn-fail window would let a long-ago
# spawn_fail inflate a fresh empty-run count"). spawn storms are clustered
# (30min): a spawn_fail older than 30min is stale, the spawn problem is over,
# and a fresh empty-run is a separate fault. The fix: mark_seat_empty_run now
# reads the marker's failure_mode and selects the window — an empty_run marker
# uses EMPTY_RUN_COUNT_WINDOW_S (24h); a spawn_fail marker uses
# EMPTY_RUN_MARKER_FRESH_S (30min). This test proves: a spawn_fail marker
# aged past 30min (but inside 24h) is NOT merged into a fresh empty-run count
# (the count resets to 1, not 2), with the ledger clobbered to healthy/count=0
# by seat-health.ts between the two faults (the production recovery signal).
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "t3749:spawn:1" >/dev/null 2>&1 \
    || fail "(g) mark_seat_spawn_fail #1 failed"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(g) spawn_fail seed count = $(count_of "$mf"), want 1"
# seat-health.ts clobbers the ledger to healthy/count=0 between the two faults
# (the production recovery signal — a 200 observation after the bench expired).
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$lf")" == "0" ]] \
    || fail "(g) ledger not clobbered to 0: $(count_of "$lf")"
# Age the spawn_fail marker past the 30min spawn-fail window but inside the 24h
# empty-run window. This is the inflation gap: before the symmetric fix the
# empty-run writer used 24h for the spawn_fail marker and merged count=1.
age_marker "$mf" 2400  # 40 min — past 30min spawn-fail window, inside 24h
mark_seat_empty_run "$p" "$m" "t3749:noop:after-stale-spawn" >/dev/null 2>&1 \
    || fail "(g) mark_seat_empty_run (after stale spawn_fail) failed"
stale_sf_count=$(count_of "$mf")
[[ "$stale_sf_count" == "1" ]] \
    || fail "(g) empty-run count after a stale (>30min) spawn_fail marker = $stale_sf_count, want 1 — a spawn_fail older than the 30min spawn-fail window must NOT inflate a fresh empty-run count (fleet-ops#3749 symmetric); before the fix the 24h window merged it to 2"
ok "(g) spawn_fail -> empty_run: a stale (>30min) spawn_fail marker does NOT inflate a fresh empty-run count (resets to 1, not 2) — the symmetric class-aware fix narrows the spawn_fail -> empty_run cross-class case to the 30min spawn-fail window"

# --- (h) empty_run -> empty_run still uses 24h (class-aware fix did NOT narrow) -
# Prove the class-aware fix in mark_seat_empty_run did NOT narrow the same-class
# empty_run -> empty_run window. An empty_run marker aged past 30min but inside
# 24h must STILL merge (the #2934 intermittent contract). This re-checks (a) but
# with the class-aware code path active, so the failure_mode read + window
# selection cannot accidentally narrow the same-class empty_run case.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t3749:noop:h1" >/dev/null 2>&1 \
    || fail "(h) mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
age_marker "$mf" 6120  # 1h42m — past 30min, inside 24h (the live #2934 gap)
mark_seat_empty_run "$p" "$m" "t3749:noop:h2" >/dev/null 2>&1 \
    || fail "(h) mark_seat_empty_run #2 (after 1h42m gap) failed"
ee_count=$(count_of "$mf")
[[ "$ee_count" == "2" ]] \
    || fail "(h) empty_run -> empty_run count after a 1h42m gap = $ee_count, want 2 — the class-aware fix must NOT narrow the same-class empty_run window; the 24h intermittent contract still holds"
ok "(h) empty_run -> empty_run still accumulates across a 1h42m gap — the class-aware fix did NOT narrow the same-class empty_run window"

ok "fleet-ops#2934/#3675/#3666/#3749: empty-run count accumulates across gaps up to 24h (intermittent no-op'er reaches the ceiling and is parked, and the park persists across the 24h boundary), gaps > 24h reset (recovery honoured), spawn_fail keeps its 30min same-class window, empty_run -> spawn_fail cross-class count survives a > 30min gap (#3849), and spawn_fail -> empty_run cross-class does NOT inflate from a stale (>30min) spawn_fail (#3749 symmetric)"
