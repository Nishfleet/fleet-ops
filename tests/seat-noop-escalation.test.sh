#!/usr/bin/env bash
# tests/seat-noop-escalation.test.sh
#
# fleet-ops#1408: a seat that fails repeatedly must NOT be re-seated in a
# loop. Before this fix, mark_seat_spawn_fail benched for a FIXED backoff
# (300s) regardless of consecutive_failure_count, so a seat that failed every
# cycle re-entered rotation every 5 min and burned 12 attempts in 2h on the
# same seat (opencode/nemotron-3-ultra-free hit count=16 at a flat 300s
# bench).
#
# The fix: escalate the SPAWN-FAIL bench (a real provider wall: non-zero
# exit, HTTP 429/402/500, spawn ETIMEDOUT) by consecutive_failure_count so
# each repeated failure benches the seat longer, breaking the re-seat loop.
# fleet-ops#3531: EMPTY RUNS now share a single geometric ladder with the
# other error-class writers (overload, quota). The bench doubles per
# consecutive failure (base * 2^(n-1)) and caps at 6 h (21600 s), then parks
# at the failure ceiling (SEAT_FAILURE_CEILING consecutive failures -> 24 h
# wall). Remote agents (e.g. devin) are capped at 1800 s instead. The count is
# still tracked and reset to 0 by seat-health.ts on a healthy in-session
# observation, and seat_usable fail-opens after usable_at regardless of count.
#
# This test proves:
#   (1) repeated spawn-fail benches escalate (300 -> 600 -> 1200s, capped).
#   (2) repeated empty-run benches escalate geometrically (900 -> 1800s)
#       and park at the failure ceiling (fleet-ops#3531).
#   (3) the spawn-fail cap holds (no unbounded growth).
#   (4) a non-empty completion still exits 0 (work-complete is not punished).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-noop-escalation.XXXXXX)"
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
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "models": { "glm-5-2": 4 } }
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

usable_at_epoch() {
    local f="$1"
    local u
    u=$(jq -r '.usable_at // empty' "$f" 2>/dev/null || true)
    [[ -n "$u" ]] || { echo 0; return; }
    date -u -d "$u" +%s 2>/dev/null || echo 0
}

# --- (1) spawn-fail escalation: 300 -> 600 -> 1200s ------------------------
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
base=300
prev_epoch=$(date -u +%s)
mark_seat_spawn_fail "$p" "$m" "test:noop:1" >/dev/null 2>&1 || fail "mark_seat_spawn_fail #1 failed"
c1=$(jq -r '.consecutive_failure_count' "$lf")
u1=$(usable_at_epoch "$lf")
d1=$((u1 - prev_epoch))
[[ "$c1" == "1" ]] || fail "count after 1st spawn-fail = $c1, want 1"
(( d1 >= base - 30 && d1 <= base + 30 )) \
  || fail "1st spawn-fail backoff = ${d1}s, want ~${base}s (no escalation on count=1)"
ok "spawn-fail count=1 backoff=${d1}s (~${base}s, base)"

mark_seat_spawn_fail "$p" "$m" "test:noop:2" >/dev/null 2>&1 || fail "mark_seat_spawn_fail #2 failed"
c2=$(jq -r '.consecutive_failure_count' "$lf")
prev_epoch=$(date -u +%s)
u2=$(usable_at_epoch "$lf")
d2=$((u2 - prev_epoch))
[[ "$c2" == "2" ]] || fail "count after 2nd spawn-fail = $c2, want 2"
(( d2 >= 2*base - 30 && d2 <= 2*base + 30 )) \
  || fail "2nd spawn-fail backoff = ${d2}s, want ~$((2*base))s (escalated on count=2)"
ok "spawn-fail count=2 backoff=${d2}s (~$((2*base))s, escalated)"

mark_seat_spawn_fail "$p" "$m" "test:noop:3" >/dev/null 2>&1 || fail "mark_seat_spawn_fail #3 failed"
c3=$(jq -r '.consecutive_failure_count' "$lf")
prev_epoch=$(date -u +%s)
u3=$(usable_at_epoch "$lf")
d3=$((u3 - prev_epoch))
[[ "$c3" == "3" ]] || fail "count after 3rd spawn-fail = $c3, want 3"
(( d3 >= 4*base - 30 && d3 <= 4*base + 30 )) \
  || fail "3rd spawn-fail backoff = ${d3}s, want ~$((4*base))s (escalated on count=3)"
ok "spawn-fail count=3 backoff=${d3}s (~$((4*base))s, escalated)"

# --- (3) cap holds: many failures must not exceed the cap ------------------
cap="${SPAWN_FAIL_BACKOFF_CAP_S:-3600}"
for _ in 4 5 6 7 8 9 10; do
    mark_seat_spawn_fail "$p" "$m" "test:noop:cap" >/dev/null 2>&1 || true
done
prev_epoch=$(date -u +%s)
uc=$(usable_at_epoch "$lf")
dc=$((uc - prev_epoch))
(( dc <= cap + 30 )) \
  || fail "spawn-fail backoff after 10 failures = ${dc}s, exceeds cap ${cap}s"
ok "spawn-fail backoff capped at ~${dc}s (cap=${cap}s)"

# --- (2) empty-run geometric cooldown: 900s -> 1800s, then park at the failure ceiling (fleet-ops#3531) ---
# Test isolation: pin the failure ceiling low so the park fires in a few
# iterations. Production default is 20 (fleet-ops#3531).
export SEAT_FAILURE_CEILING=3
# A provider no-op (exit 0, < OUT_MIN stdout) is a retryable lane fault. It
# now shares the single geometric ladder with overload/quota writers
# (base * 2^(n-1), capped at 6 h) so a repeat offender is held out of
# rotation longer, but still fail-opens on a healthy observation.
rm -f "$lf" "$mf"
ebase=900
for i in 1 2; do
    mark_seat_empty_run "$p" "$m" "test:empty:${i}" >/dev/null 2>&1 || fail "mark_seat_empty_run #${i} failed"
    ec=$(jq -r '.consecutive_failure_count' "$lf")
    [[ "$ec" == "$i" ]] || fail "count after ${i} empty-runs = $ec, want $i"
    prev_epoch=$(date -u +%s)
    eu=$(usable_at_epoch "$lf")
    ed=$((eu - prev_epoch))
    want=$(( ebase * (2**(i-1)) ))
    (( ed >= want - 30 && ed <= want + 30 )) \
      || fail "empty-run #${i} backoff = ${ed}s, want ~${want}s (geometric, fleet-ops#3531)"
    ok "empty-run count=${i} backoff=${ed}s (~${want}s, geometric)"
done

# 3rd no-op: SEAT_FAILURE_CEILING (3 in this test, 20 in production) parks
# the seat at the SEAT_PARK_WALL_S (24h) wall — the chronic-no-op park.
mark_seat_empty_run "$p" "$m" "test:empty:3" >/dev/null 2>&1 || fail "mark_seat_empty_run #3 failed"
ec=$(jq -r '.consecutive_failure_count' "$lf")
[[ "$ec" == "3" ]] || fail "count after 3 empty-runs = $ec, want 3"
park="${SEAT_PARK_WALL_S:-86400}"
prev_epoch=$(date -u +%s)
eu=$(usable_at_epoch "$lf")
ed=$((eu - prev_epoch))
(( ed >= park - 30 && ed <= park + 30 )) \
  || fail "empty-run #3 backoff = ${ed}s, want ~${park}s (park at SEAT_FAILURE_CEILING, fleet-ops#3531)"
ok "empty-run count=3 backoff=${ed}s (~${park}s, parked at 3rd no-op — fleet-ops#3531)"

# --- (3b) park wall holds at higher counts (no hidden rebound) ------------
# Eight consecutive no-ops earlier breached the old 7200s cap; under
# fleet-ops#3531 the wall stays at SEAT_PARK_WALL_S for every count
# >= the ceiling — never a base rebound, never unbounded growth.
for _ in 4 5 6 7 8; do
    mark_seat_empty_run "$p" "$m" "test:empty:flat" >/dev/null 2>&1 || true
done
prev_epoch=$(date -u +%s)
euc=$(usable_at_epoch "$lf")
edc=$((euc - prev_epoch))
(( edc >= park - 30 && edc <= park + 30 )) \
  || fail "empty-run backoff after 8 failures = ${edc}s, want ~${park}s (park wall, capped — fleet-ops#2343/#3046)"
ok "empty-run backoff after 8 no-ops still ~${edc}s (park wall holds, capped — fleet-ops#2343/#3046)"

# --- (4) a non-empty completion is NOT punished: seat_usable after bench ---
# A benched seat is unusable only until usable_at; after it expires the seat
# is usable again (fail-open). This is the work-complete vs seat-fault split:
# a no-op seat is benched (seat-fault), a real completion is not (the bench
# only ever fires on a failure). Verify seat_usable fail-opens post-bench.
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "test:failopen" >/dev/null 2>&1 || true
if seat_usable "$p" "$m"; then
    fail "seat_usable returned usable immediately after a fresh spawn-fail bench"
fi
ok "freshly-benched seat is UNUSABLE (seat-fault held)"
# Force usable_at into the past to simulate bench expiry. fleet-ops#1512: the
# bench now lives in BOTH the ledger and the clobber-proof spawn-bench marker,
# so age both surfaces (in production real time passing ages both; the test
# simulates that by editing both).
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
sb_marker="$LEDGER/${p//[^A-Za-z0-9._-]/_}__${m//[^A-Za-z0-9._-]/_}.spawn-bench.json"
if [[ -f "$sb_marker" ]]; then
    tmp=$(mktemp)
    jq --arg u "$past_iso" '.usable_at = $u' "$sb_marker" >"$tmp" 2>/dev/null && mv "$tmp" "$sb_marker"
fi
if ! seat_usable "$p" "$m"; then
    fail "seat_usable returned unusable after bench expired — fail-open is broken (recovered seat walled)"
fi
ok "expired bench fail-opens — a recovered seat is re-eligible (work-complete not punished)"

ok "seat failure bench: spawn-fail escalates (capped), empty-run escalates geometrically (fleet-ops#3531), fail-open on recovery"
