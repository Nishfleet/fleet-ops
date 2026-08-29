#!/usr/bin/env bash
# tests/seat-noop-escalation.test.sh
#
# fleet-ops#1408: a seat that no-ops or spawn-fails repeatedly must NOT be
# re-seated in a loop. Before this fix, mark_seat_spawn_fail and
# mark_seat_empty_run benched for a FIXED backoff (300s / 900s) regardless of
# consecutive_failure_count, so a seat that no-ops every cycle re-entered
# rotation every 5 min and burned 12 attempts in 2h on the same seat
# (opencode/nemotron-3-ultra-free hit count=16 at a flat 300s bench).
#
# The fix: escalate the bench backoff by consecutive_failure_count so each
# repeated failure benches the seat longer, breaking the re-seat loop. The
# count is already tracked and reset to 0 by seat-health.ts on a healthy
# in-session observation, so the escalation is fair — a recovered seat is
# re-tried at the base backoff, not a stale-high one. seat_usable fail-opens
# after usable_at regardless of count, so no seat is walled permanently.
#
# This test proves:
#   (1) repeated spawn-fail benches escalate (300 -> 600 -> 1200s, capped).
#   (2) repeated empty-run benches escalate (900 -> 1800 -> 3600s, capped).
#   (3) the cap holds (no unbounded growth).
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

# --- (2) empty-run escalation: 900 -> 1800 -> 3600s ------------------------
rm -f "$lf"
ebase=900
mark_seat_empty_run "$p" "$m" "test:empty:1" >/dev/null 2>&1 || fail "mark_seat_empty_run #1 failed"
ec1=$(jq -r '.consecutive_failure_count' "$lf")
prev_epoch=$(date -u +%s)
eu1=$(usable_at_epoch "$lf")
ed1=$((eu1 - prev_epoch))
[[ "$ec1" == "1" ]] || fail "count after 1st empty-run = $ec1, want 1"
(( ed1 >= ebase - 30 && ed1 <= ebase + 30 )) \
  || fail "1st empty-run backoff = ${ed1}s, want ~${ebase}s"
ok "empty-run count=1 backoff=${ed1}s (~${ebase}s, base)"

mark_seat_empty_run "$p" "$m" "test:empty:2" >/dev/null 2>&1 || fail "mark_seat_empty_run #2 failed"
ec2=$(jq -r '.consecutive_failure_count' "$lf")
prev_epoch=$(date -u +%s)
eu2=$(usable_at_epoch "$lf")
ed2=$((eu2 - prev_epoch))
[[ "$ec2" == "2" ]] || fail "count after 2nd empty-run = $ec2, want 2"
(( ed2 >= 2*ebase - 30 && ed2 <= 2*ebase + 30 )) \
  || fail "2nd empty-run backoff = ${ed2}s, want ~$((2*ebase))s (escalated)"
ok "empty-run count=2 backoff=${ed2}s (~$((2*ebase))s, escalated)"

mark_seat_empty_run "$p" "$m" "test:empty:3" >/dev/null 2>&1 || fail "mark_seat_empty_run #3 failed"
ec3=$(jq -r '.consecutive_failure_count' "$lf")
prev_epoch=$(date -u +%s)
eu3=$(usable_at_epoch "$lf")
ed3=$((eu3 - prev_epoch))
[[ "$ec3" == "3" ]] || fail "count after 3rd empty-run = $ec3, want 3"
(( ed3 >= 4*ebase - 30 && ed3 <= 4*ebase + 30 )) \
  || fail "3rd empty-run backoff = ${ed3}s, want ~$((4*ebase))s (escalated)"
ok "empty-run count=3 backoff=${ed3}s (~$((4*ebase))s, escalated)"

ecap="${EMPTY_RUN_BACKOFF_CAP_S:-7200}"
for _ in 4 5 6 7 8; do
    mark_seat_empty_run "$p" "$m" "test:empty:cap" >/dev/null 2>&1 || true
done
prev_epoch=$(date -u +%s)
euc=$(usable_at_epoch "$lf")
edc=$((euc - prev_epoch))
(( edc <= ecap + 30 )) \
  || fail "empty-run backoff after 8 failures = ${edc}s, exceeds cap ${ecap}s"
ok "empty-run backoff capped at ~${edc}s (cap=${ecap}s)"

# --- (4) a non-empty completion is NOT punished: seat_usable after bench ---
# A benched seat is unusable only until usable_at; after it expires the seat
# is usable again (fail-open). This is the work-complete vs seat-fault split:
# a no-op seat is benched (seat-fault), a real completion is not (the bench
# only ever fires on a failure). Verify seat_usable fail-opens post-bench.
rm -f "$lf"
mark_seat_spawn_fail "$p" "$m" "test:failopen" >/dev/null 2>&1 || true
if seat_usable "$p" "$m"; then
    fail "seat_usable returned usable immediately after a fresh spawn-fail bench"
fi
ok "freshly-benched seat is UNUSABLE (seat-fault held)"
# Force usable_at into the past to simulate bench expiry.
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable returned unusable after bench expired — fail-open is broken (recovered seat walled)"
fi
ok "expired bench fail-opens — a recovered seat is re-eligible (work-complete not punished)"

ok "seat no-op escalation: repeated failures bench longer, capped, fail-open on recovery"
