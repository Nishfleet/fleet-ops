#!/usr/bin/env bash
# tests/seat-empty-run-clobber-park.test.sh
#
# fleet-ops#2627: empty-run count must ACCUMULATE across healthy ledger clobbers
# and the failure-ceiling park must engage for a CHRONIC no-op'er.
#
# Root cause (2026-09-01 live): opencode/nemotron-3-ultra-free and
# openrouter/deepseek/deepseek-v4-flash-0731 each no-op'ed 5+ times in 2h
# with EVERY ledger write showing consecutive_failure_count=1 — because
# seat-health.ts writes a healthy observation (health_class=healthy,
# count=0) to the ledger on a later 200 OK, the wrapper's
# mark_seat_empty_run started each cycle from count=0 instead of the
# accumulated count. The flat 900s cooldown never escalated (fleet-ops#2343
# holds that for healthy seats), and the #1362 failure-ceiling park
# (SEAT_FAILURE_CEILING=20) never fired because the clobbered ledger stayed
# at count=1 every cycle. Net: 18 empty runs in 2h on healthy-reporting seats.
#
# The fix (this PR): the wrapper-side spawn-bench marker (fleet-ops#1512 —
# written ONLY by the wrapper, never by seat-health.ts, so it survives the
# clobber) NOW also carries consecutive_failure_count and failure_mode. On
# every mark_seat_empty_run call, the writer:
#   (1) reads the same-class (empty_run) marker FIRST — only if it is
#       RECENT (within EMPTY_RUN_MARKER_FRESH_S, default 30 min),
#   (2) then reads the (clobberable) ledger,
#   (3) takes the max as the prior count,
#   (4) writes merged_count+1 to BOTH the ledger and the marker.
# A stale marker means seat-health.ts produced a healthy observation after
# the bench expired (the recovery signal) — fall through to the ledger and
# start a fresh count. The chronic-no-op park uses the same generic failure
# ceiling (SEAT_FAILURE_CEILING, default 20) and the bench now escalates
# geometrically so a free-lane no-op'er is held out of rotation within a
# few cycles, not flat 900s every cycle (fleet-ops#3531).
#
# This test proves, end to end against the live wrapper:
#   (a) three empty-run benches on the same seat WITH a healthy clobber
#       between each accumulate the marker count 1 -> 2 -> 3 while the
#       ledger stays clobbered at count=0. The marker is the durable count.
#   (b) at the failure ceiling (SEAT_FAILURE_CEILING=3 here for test
#       isolation) the #1362 park wall engages (usable_at jumps to
#       ~now+SEAT_PARK_WALL_S, the marker carries the count that fed the
#       park, seat_usable holds the parked seat), so a chronic no-op'er
#       stops entering rotation.
#   (c) a STALE same-class marker (older than EMPTY_RUN_MARKER_FRESH_S)
#       falls back to the (clobbered) ledger and starts a fresh count —
#       the recovery signal: a healthy observation after the bench expired
#       does NOT punish a recovered seat.
#   (d) a DIFFERENT-CLASS marker (spawn_fail) DOES merge into the
#       empty-run count (fleet-ops#2786): the spawn-bench marker is a
#       SINGLE file per seat shared by both writers, so cross-class
#       accumulation is the only way the failure-ceiling park ever fires
#       for a seat that alternates between empty_run and spawn_fail. The
#       live nemotron-3-ultra-free seat produced 10 empty runs over 3 days
#       with every marker showing count=1 because a spawn_fail marker sat
#       between empty runs and the same-class check skipped it.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-spawn-bench-clobber.test.sh
# (clobber_with_healthy helper, scratch HOME) so the test is self-contained.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-clobber-park.XXXXXX)"
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
# Test isolation: pin the failure ceiling low so we can prove the park
# fires in a few iterations. Production default is 20 (fleet-ops#3531).
export SEAT_FAILURE_CEILING=3
export SEAT_PARK_WALL_S=86400
export EMPTY_RUN_MARKER_FRESH_S=1800
# fleet-ops#2934: the empty-run count-merge window is its own knob now
# (EMPTY_RUN_COUNT_WINDOW_S, default 2 h), separate from the spawn-fail
# window (EMPTY_RUN_MARKER_FRESH_S). Pin it to the same 1800 s here so the
# existing staleness assertion in (c) — which ages the marker past
# EMPTY_RUN_MARKER_FRESH_S — still proves the reset. The #2934 fix's own
# test (seat-empty-run-intermittent-count.test.sh) exercises the wider
# default window.
export EMPTY_RUN_COUNT_WINDOW_S=1800
# Disable the corpse reclassification (fleet-ops#2594) so the parked seat
# is not also written seat_dead=true by mark_seat_empty_run at the higher
# SEAT_DEAD_CONSECUTIVE_THRESHOLD — this test proves the parking behaviour
# in isolation. The corpse path is covered by tests/seat-quota-corpse.test.sh.
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

# Simulate seat-health.ts writing a healthy observation to the ledger. This
# is exactly what the extension's writeSeatLedgerEntry does on a 200 OK
# after_provider_response: health_class flips to "healthy", count to 0,
# usable_at to null. This is the CLOBBER that previously zeroed the
# consecutive_failure_count between wrapper writes.
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

# --- (a) the empty_run count accumulates across clobbers -------------------
# Openrouter deepseek was the live no-op'er on 2026-09-01: 5+ empty runs in
# 2h, every ledger write showing count=1 (clobber reset). The marker must
# accumulate 1 -> 2 -> 3 with the ledger staying at count=0 across all 3
# clobbers.
p="openrouter"; m="deepseek/deepseek-v4-flash-0731"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"

# Make sure clobber_with_healthy produces a seed marker first so the next
# mark_seat_empty_run sees no marker (proves the seed-from-zero path).
mark_seat_empty_run "$p" "$m" "t2627:noop:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "marker count after 1st empty-run + clobber = $(count_of "$mf"), want 1 — count must survive the healthy clobber"
ok "(a1) marker count after 1st no-op + clobber = 1 (count survives the clobber)"

mark_seat_empty_run "$p" "$m" "t2627:noop:2" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #2 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "2" ]] \
    || fail "marker count after 2nd empty-run + clobber = $(count_of "$mf"), want 2 — count must ACCUMULATE across clobbers (fleet-ops#2627)"
ok "(a2) marker count after 2nd no-op + clobber = 2 (count ACCUMULATES across healthy clobbers — busts the live 'count=1 every time' reset pattern)"

mark_seat_empty_run "$p" "$m" "t2627:noop:3" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #3 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "3" ]] \
    || fail "marker count after 3rd empty-run + clobber = $(count_of "$mf"), want 3"
# The ledger must stay clobbered healthy/0 throughout — that is what makes
# the marker carry the only durable count.
ledger_clobbered=$(jq -r '.consecutive_failure_count // 0' "$lf" 2>/dev/null || echo 0)
[[ "$ledger_clobbered" == "0" ]] \
    || fail "ledger count = $ledger_clobbered, want 0 — the clobber must have zeroed it for the test to prove the marker carry"
ok "(a3) marker count=3 while clobbered ledger count=0 — THE MARKER IS THE DURABLE COUNT"

# --- (b) at the failure ceiling, the long-wall park engages ----------------
# The #1362 park must fire from the ACCUMULATED marker count (3) on the
# 3rd no-op (SEAT_FAILURE_CEILING=3 for test isolation), not from the
# clobbered ledger (count=0). The marker's usable_at must jump to
# ~now+SEAT_PARK_WALL_S and seat_usable must hold the parked seat.
w=$(wall_s_of_marker "$mf")
(( w >= SEAT_PARK_WALL_S - 120 && w <= SEAT_PARK_WALL_S + 120 )) \
    || fail "empty-run park wall = ${w}s, want ~${SEAT_PARK_WALL_S}s — the park must fire from the ACCUMULATED marker count at SEAT_FAILURE_CEILING=3"
ok "(b1) empty-run park wall = ${w}s (~24h) — the #1362 park fires from the accumulated marker count across clobbers (fleet-ops#2627)"

if seat_usable "$p" "$m"; then
    fail "(b2) seat_usable returned usable on the parked empty-run seat — park wall must hold across the marker"
fi
ok "(b2) parked empty-run seat is HELD UNUSABLE by seat_usable — chronic no-op'er out of rotation"

# --- (c) a STALE same-class marker falls back to the (clobbered) ledger ---
# The recovery signal: a healthy observation after the bench expired means
# the seat produced output again. The next empty-run must NOT keep the
# stale high count — it must merge from the clobbered ledger (count=0) and
# start fresh. EMPTY_RUN_COUNT_WINDOW_S bounds this for the empty-run path
# (fleet-ops#2934 — pinned to 1800 s here to match the spawn-fail window);
# we simulate staleness by editing the marker's written_at to well past the
# freshness window.
rm -f "$lf"
stale_iso=$(date -u -d "@$(($(date -u +%s) - EMPTY_RUN_MARKER_FRESH_S - 600))" +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg w "$stale_iso" '.written_at = $w' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
# Now the marker says count=3 but is stale; ledger is absent.
# Seed an empty-run — it must merge count=0 (no ledger, stale marker) and
# produce count=1 in the new marker.
mark_seat_empty_run "$p" "$m" "t2627:recovery:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (recovery) failed"
fresh_count=$(count_of "$mf")
[[ "$fresh_count" == "1" ]] \
    || fail "(c) after a stale marker, merged count = $fresh_count, want 1 — the stale marker must NOT carry the high count forward; the recovered seat starts fresh"
ok "(c) stale same-class marker falls back to ledger (count=0); merged count = $fresh_count — recovered seat is NOT punished"

# --- (d) a DIFFERENT-CLASS marker DOES merge into empty-run count --------
# fleet-ops#2786: the spawn-bench marker is a SINGLE file per seat shared
# by mark_seat_empty_run and mark_seat_spawn_fail. A spawn_fail marker
# carries failure_mode=spawn_fail, count=N. The next empty-run MUST merge
# the spawn_fail count (the marker is the durable count authority regardless
# of failure_mode) so a seat that alternates between empty_run and
# spawn_fail reaches the failure-ceiling park. The live nemotron-3-ultra-free
# seat produced 10 empty runs over 3 days with every marker count=1 because
# a spawn_fail marker sat between empty runs and the same-class check
# skipped it — the park never fired, the flat 900s cooldown re-seated the
# same offender every cycle.
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "t2786:spawn:1" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail failed"
# Marker now has failure_mode=spawn_fail, count=1.
spawn_mf_count=$(count_of "$mf")
spawn_mf_mode=$(jq -r '.failure_mode // ""' "$mf")
[[ "$spawn_mf_mode" == "spawn_fail" ]] \
    || fail "(d) spawn-bench marker failure_mode = '$spawn_mf_mode', want spawn_fail"
[[ "$spawn_mf_count" == "1" ]] \
    || fail "(d) spawn-bench marker count = $spawn_mf_count, want 1"
# Now an empty-run: the marker is a DIFFERENT class, but it MUST merge the
# spawn_fail count (the marker is the durable count authority). The ledger
# is also absent (rm above). prev_count must be 1 (from the marker);
# merged=2.
clobber_with_healthy "$p" "$m" "$lf"
mark_seat_empty_run "$p" "$m" "t2786:after-spawn:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run after spawn-fail failed"
new_count=$(count_of "$mf")
new_mode=$(jq -r '.failure_mode // ""' "$mf")
[[ "$new_mode" == "empty_run" ]] \
    || fail "(d) marker failure_mode after empty-run = '$new_mode', want empty_run (the spawn_fail marker was OVERWRITTEN by the empty_run writer)"
[[ "$new_count" == "2" ]] \
    || fail "(d) marker count after empty-run (with prior spawn_fail marker) = $new_count, want 2 — cross-class markers MUST merge (fleet-ops#2786: the marker is a single file per seat, the count must accumulate across failure_mode classes)"
ok "(d) spawn_fail marker (count=1) IS absorbed into empty-run count; empty-run continues at count=2, marker carries empty_run mode forward (fleet-ops#2786 cross-class accumulation)"

# --- (e) geometric cooldown below the ceiling ------------------------------
# fleet-ops#3531: the empty-run bench now escalates geometrically below the
# failure ceiling (base * 2^(n-1), capped at 6 h). Prove that across
# clobbers: each no-op below the ceiling bench is ~base * 2^(n-1).
rm -f "$lf" "$mf"
for i in 1 2; do
    mark_seat_empty_run "$p" "$m" "t2627:geometric:${i}" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run geometric-${i} failed"
    clobber_with_healthy "$p" "$m" "$lf"
    want=$(( 900 * (2**(i-1)) ))
    backoff=$(wall_s_of_marker "$mf")
    (( backoff >= want - 30 && backoff <= want + 30 )) \
        || fail "(e) empty-run #${i} backoff = ${backoff}s, want ~${want}s (geometric below ceiling, fleet-ops#3531)"
    ok "(e${i}) empty-run #${i} backoff = ${backoff}s (geometric below ceiling — count accumulates and escalates until SEAT_FAILURE_CEILING=3)"
done

ok "fleet-ops#2627/#2786: empty_run count accumulates across healthy clobbers (marker is durable count authority), the failure-ceiling park engages for a chronic no-op'er from the marker-carried count, stale markers fall back to the ledger (recovery signal), and cross-class markers (spawn_fail) DO merge so a seat that alternates classes still reaches the park"

# --- (f) reverse direction: empty_run marker merges into spawn_fail count
# fleet-ops#2786 symmetric case: mark_seat_spawn_fail must ALSO read the
# count from the spawn-bench marker (any failure_mode, written recently),
# not only the clobberable ledger. A spawn_fail after an empty_run must
# continue the count from the empty_run marker so the spawn_fail escalation
# ladder and the failure-ceiling park fire from the accumulated count. The
# live nemotron-3-ultra-free seat alternated empty_run and spawn_fail
# markers; without this symmetric fix the spawn_fail writer read only the
# clobberable ledger (count=0 after a healthy observation) and restarted
# the count at 1 every cycle.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2786:empty:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (reverse seed) failed"
empty_mf_count=$(count_of "$mf")
empty_mf_mode=$(jq -r '.failure_mode // ""' "$mf")
[[ "$empty_mf_mode" == "empty_run" ]] \
    || fail "(f) marker failure_mode after empty-run = '$empty_mf_mode', want empty_run"
[[ "$empty_mf_count" == "1" ]] \
    || fail "(f) marker count after empty-run = $empty_mf_count, want 1"
# Clobber the ledger to healthy/count=0 (seat-health.ts healthy observation).
clobber_with_healthy "$p" "$m" "$lf"
# Now a spawn_fail: the marker is empty_run (count=1), the ledger is
# healthy/count=0. The spawn_fail writer MUST merge the marker count
# (prev_count=1) and write merged=2.
mark_seat_spawn_fail "$p" "$m" "t2786:spawn:after-empty" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail after empty-run failed"
sf_count=$(count_of "$mf")
sf_mode=$(jq -r '.failure_mode // ""' "$mf")
[[ "$sf_mode" == "spawn_fail" ]] \
    || fail "(f) marker failure_mode after spawn-fail = '$sf_mode', want spawn_fail (the empty_run marker was OVERWRITTEN by the spawn_fail writer)"
[[ "$sf_count" == "2" ]] \
    || fail "(f) marker count after spawn-fail (with prior empty_run marker) = $sf_count, want 2 — mark_seat_spawn_fail must merge the marker count across failure_mode classes (fleet-ops#2786)"
ok "(f) empty_run marker (count=1) IS absorbed into spawn_fail count; spawn_fail continues at count=2 (fleet-ops#2786 symmetric cross-class accumulation)"

# --- (g) full alternation reaches the failure-ceiling park -----------------
# fleet-ops#2786 end-to-end: a seat that alternates empty_run and spawn_fail
# (the live nemotron-3-ultra-free pattern) must reach the failure-ceiling
# park from the accumulated cross-class count, not stall at count=1 every
# cycle. SEAT_FAILURE_CEILING=3 here for test isolation. Three
# alternations (empty -> spawn -> empty) must park the seat on the 3rd.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t2786:alt:1" >/dev/null 2>&1 \
    || fail "alternation #1 (empty) failed"
clobber_with_healthy "$p" "$m" "$lf"
mark_seat_spawn_fail "$p" "$m" "t2786:alt:2" >/dev/null 2>&1 \
    || fail "alternation #2 (spawn) failed"
clobber_with_healthy "$p" "$m" "$lf"
mark_seat_empty_run "$p" "$m" "t2786:alt:3" >/dev/null 2>&1 \
    || fail "alternation #3 (empty) failed"
alt_count=$(count_of "$mf")
alt_mode=$(jq -r '.failure_mode // ""' "$mf")
[[ "$alt_count" == "3" ]] \
    || fail "(g) alternated marker count = $alt_count, want 3 — cross-class accumulation must reach the ceiling across empty_run/spawn_fail alternation"
[[ "$alt_mode" == "empty_run" ]] \
    || fail "(g) alternated marker failure_mode = '$alt_mode', want empty_run (last writer wins)"
# The 3rd no-op (count=3) must park the seat at ~SEAT_PARK_WALL_S.
alt_wall=$(wall_s_of_marker "$mf")
(( alt_wall >= SEAT_PARK_WALL_S - 120 && alt_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(g) alternated park wall = ${alt_wall}s, want ~${SEAT_PARK_WALL_S}s — the park must fire from the accumulated cross-class count at SEAT_FAILURE_CEILING=3"
if seat_usable "$p" "$m"; then
    fail "(g) seat_usable returned usable on the alternated parked seat — park wall must hold across the marker"
fi
ok "(g) empty_run -> spawn_fail -> empty_run alternation reaches count=3 and parks the seat (~${alt_wall}s wall) — fleet-ops#2786: a seat that alternates classes no longer stalls at count=1 every cycle"
