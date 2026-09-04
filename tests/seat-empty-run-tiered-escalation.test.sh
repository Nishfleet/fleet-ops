#!/usr/bin/env bash
# tests/seat-empty-run-tiered-escalation.test.sh
#
# fleet-ops#3077: the flat 900s empty-run cooldown (fleet-ops#2343) let a
# chronic no-op'er re-enter rotation every 900s and burn the queue. Live
# 2026-09-03 snapshot: opencode/nemotron-3-ultra-free produced 12 empty runs
# in 2h on fleet-ops#2913, consecutive_failure_count=5 with flat 900s, the
# seat re-released immediately. The #2343 design deliberately removed the
# count ladder (900->1800->3600->7200 from count=1) because it churned
# HEALTHY seats (3 intermittent no-ops in 2h got benched 1h). The fix
# (this PR): TIERED escalation ABOVE a threshold only — counts at or below
# EMPTY_RUN_ESCALATION_THRESHOLD (default 4) stay flat at 900s (the #2343
# concern is preserved for healthy/intermittent seats), counts above the
# threshold escalate (doubling per count-over-threshold, capped at
# EMPTY_RUN_ESCALATION_CAP_S, default 3600s = 1h), and the failure-ceiling
# park (24h) still fires at EMPTY_RUN_FAILURE_CEILING (default 10).
#
# This test proves, end to end against the live wrapper:
#   (a) counts at/below the threshold get the FLAT 900s bench — a healthy
#       seat with 1-4 intermittent no-ops is unaffected (the #2343 contract).
#   (b) counts above the threshold ESCALATE: count=5 gets 1800s (30 min),
#       count=6 gets 3600s (1h cap), count=7+ holds at the cap.
#   (c) at the failure ceiling the 24h park fires (unchanged) — the
#       escalation does not bypass the park.
#   (d) the escalation is FAIR: a healthy clobber between empty runs does
#       not reset the count (the marker carries it forward, fleet-ops#2627),
#       so the escalation engages from the accumulated count, not from 1.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-tiered.XXXXXX)"
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
# Use PRODUCTION defaults for the escalation knobs so this test exercises
# the real behaviour, not a pinned override. The ceiling is pinned high
# (999) so the park does NOT fire mid-test — we are testing the escalation
# steps, not the park (the park is covered by clobber-park + intermittent
# tests). The park is exercised separately in (c) with a pinned ceiling.
export EMPTY_RUN_BACKOFF_S=900
export EMPTY_RUN_ESCALATION_THRESHOLD=4
export EMPTY_RUN_ESCALATION_CAP_S=3600
export EMPTY_RUN_FAILURE_CEILING=999
export SEAT_PARK_WALL_S=86400
export EMPTY_RUN_MARKER_FRESH_S=1800
export EMPTY_RUN_COUNT_WINDOW_S=7200
# Disable the corpse reclassification so the parked seat is not also
# written seat_dead=true — this test proves the escalation in isolation.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "nemotron-3-ultra-free", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 128000 }
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
    "opencode": { "cap": 3, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "nemotron-3-ultra-free": 3 } }
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

# Echo the backoff_s field from the clobber-proof spawn-bench marker (the
# bench seconds the wrapper wrote for this empty-run cycle). The ledger gets
# clobbered by seat-health.ts between wrapper writes, so the marker is the
# durable authority for the backoff (fleet-ops#1512/#2627).
backoff_s_of() { jq -r '.backoff_s // 0' "$1" 2>/dev/null || echo 0; }

p="opencode"; m="nemotron-3-ultra-free"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# --- (a) counts at/below threshold get FLAT 900s (#2343 preserved) --------
# A healthy seat with 1-4 intermittent no-ops in a 2h window must get the
# flat 900s bench — the #2343 contract. The escalation must NOT engage at
# or below EMPTY_RUN_ESCALATION_THRESHOLD=4.
rm -f "$lf" "$mf"
for i in 1 2 3 4; do
    mark_seat_empty_run "$p" "$m" "t3077:noop:$i" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run #$i failed"
    clobber_with_healthy "$p" "$m" "$lf"
    cnt=$(count_of "$mf")
    bo=$(backoff_s_of "$mf")
    [[ "$cnt" == "$i" ]] \
        || fail "(a) count at step $i = $cnt, want $i"
    [[ "$bo" == "900" ]] \
        || fail "(a) backoff at count=$i = ${bo}s, want 900 (flat — #2343 preserved at/below threshold=$EMPTY_RUN_ESCALATION_THRESHOLD)"
done
ok "(a) counts 1-4 get flat 900s bench — healthy/intermittent seats unaffected (the #2343 contract preserved)"

# --- (b) counts above threshold ESCALATE ----------------------------------
# count=5 (first above threshold=4): 900 * 2^1 = 1800s (30 min)
# count=6: 900 * 2^2 = 3600s (1h — cap)
# count=7: 3600s (cap held)
# The chronic no-op'er gets progressively longer benches instead of flat 900s.
for expected in "5:1800" "6:3600" "7:3600"; do
    cnt_want="${expected%%:*}"
    bo_want="${expected##*:}"
    mark_seat_empty_run "$p" "$m" "t3077:noop:$cnt_want" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run count=$cnt_want failed"
    clobber_with_healthy "$p" "$m" "$lf"
    cnt=$(count_of "$mf")
    bo=$(backoff_s_of "$mf")
    [[ "$cnt" == "$cnt_want" ]] \
        || fail "(b) count = $cnt, want $cnt_want"
    [[ "$bo" == "$bo_want" ]] \
        || fail "(b) backoff at count=$cnt_want = ${bo}s, want ${bo_want}s (escalated above threshold=$EMPTY_RUN_ESCALATION_THRESHOLD)"
done
ok "(b) counts 5-7 escalate: 1800s, 3600s, 3600s (cap held) — chronic no-op'er gets longer benches"

# --- (c) at the failure ceiling the 24h park fires (unchanged) -------------
# The escalation does not bypass the failure-ceiling park. Pin the ceiling
# low (8) so the park fires at count=8 — the backoff must jump to
# SEAT_PARK_WALL_S (86400s = 24h), not stay at the escalation cap.
export EMPTY_RUN_FAILURE_CEILING=8
mark_seat_empty_run "$p" "$m" "t3077:noop:8:park" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #8 (park) failed"
park_count=$(count_of "$mf")
park_bo=$(backoff_s_of "$mf")
[[ "$park_count" == "8" ]] \
    || fail "(c) park count = $park_count, want 8"
[[ "$park_bo" == "86400" ]] \
    || fail "(c) park backoff = ${park_bo}s, want 86400 (24h park at ceiling=$EMPTY_RUN_FAILURE_CEILING — escalation must not bypass the park)"
if seat_usable "$p" "$m"; then
    fail "(c) seat_usable returned usable on the parked seat — the 24h park wall must hold it out of rotation"
fi
ok "(c) count=8 hits the failure ceiling and parks for 86400s (24h) — the escalation does not bypass the park"

# --- (d) escalation engages from the ACCUMULATED count (marker-carried) ---
# A healthy clobber between empty runs does not reset the count (the marker
# carries it forward, fleet-ops#2627). So the escalation engages from the
# accumulated count, not from 1 each cycle. Prove it: seed count=4 (flat),
# clobber, then one more no-op must escalate to 1800s (count=5) — not reset
# to 900s (count=1).
rm -f "$lf" "$mf"
export EMPTY_RUN_FAILURE_CEILING=999
for i in 1 2 3 4; do
    mark_seat_empty_run "$p" "$m" "t3077:accum:$i" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run (accum seed) #$i failed"
    clobber_with_healthy "$p" "$m" "$lf"
done
seed_cnt=$(count_of "$mf")
[[ "$seed_cnt" == "4" ]] \
    || fail "(d) seed count = $seed_cnt, want 4"
seed_bo=$(backoff_s_of "$mf")
[[ "$seed_bo" == "900" ]] \
    || fail "(d) seed backoff = ${seed_bo}s, want 900 (flat at threshold)"
# One more no-op after a healthy clobber — must escalate from the accumulated
# count=5, not reset to count=1.
mark_seat_empty_run "$p" "$m" "t3077:accum:5" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (accum escalate) failed"
accum_cnt=$(count_of "$mf")
accum_bo=$(backoff_s_of "$mf")
[[ "$accum_cnt" == "5" ]] \
    || fail "(d) accumulated count after clobber = $accum_cnt, want 5 — the marker must carry the count forward across the healthy clobber (#2627)"
[[ "$accum_bo" == "1800" ]] \
    || fail "(d) accumulated backoff = ${accum_bo}s, want 1800 (escalated from accumulated count=5, not reset to 900)"
ok "(d) escalation engages from the accumulated count across a healthy clobber — the marker carries the count forward (#2627), so the chronic no-op'er escalates instead of resetting"

ok "fleet-ops#3077: empty-run backoff escalates above threshold=4 (1800s@5, 3600s@6+), stays flat 900s at/below (the #2343 contract preserved), and the 24h failure-ceiling park still fires"
