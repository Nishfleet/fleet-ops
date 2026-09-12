#!/usr/bin/env bash
# tests/seat-spawn-corpse.test.sh
#
# fleet-ops#3889: a seat with a CHRONIC spawn_fail streak past a threshold
# must be classed a CORPSE regardless of HTTP status, instead of resetting to
# a flat 86400s park wall. Live xkiro/deepseek-v4-flash reached 47
# consecutive spawn_fail while the LEDGER stayed health_class=healthy /
# http 200: seat-health.ts logs a transport 200 as healthy during the very
# run that then exits 0 with 0-byte stdout (after_provider_response carries
# status+headers only, never the body), so its healthy write clobbers the
# ledger's bench to seat_dead=false + count=0 + usable_at=null while the
# wrapper's spawn-bench marker count climbs forever. Every flat 24h park-wall
# expiry re-offered the seat, which spawn-failed again — the loop.
#
# The fix (lib/litellm-seat.sh), mirroring the quota writer's corpse
# reclassification (fleet-ops#2594): mark_seat_spawn_fail writes seat_dead=true
# once merged_count >= SEAT_DEAD_CONSECUTIVE_THRESHOLD (default 25, matching
# seat-health.ts), AND carries that seat_dead=true onto the clobber-proof
# spawn-bench marker (the only record seat-health.ts never touches), so the
# corpse survives the false-healthy 200. seat_usable holds a marker-declared
# corpse DURABLY — over the marker's expired usable_at and over the #3737
# marker-age fail-open (>24h), with only a comeback_release recovery probe
# (tool-using, source="comeback_release") re-proving the seat.
#
# This test proves:
#   S1  sub-threshold spawn_fail -> seat_dead=false (unchanged behaviour).
#   S2  at-threshold  spawn_fail -> ledger seat_dead=true AND marker
#       seat_dead=true (corpse reclassification + durable projection).
#   S3  chronic streak (the live 47 shape) -> corpse in ledger + marker.
#   S4  a marker-declared corpse is HELD even after marker usable_at expires
#       AND marker ages past the 24h #3737 fail-open AND the ledger is
#       clobbered to false-healthy http 200 / seat_dead=false — the durable
#       hold over every prior re-offer path.
#   S5  only a comeback_release recovery re-proves the corpse; seat_usable
#       then returns usable.
#   S6  a sub-threshold seat still releases on a newer healthy observation
#       (normal recovery path intact — the corpse fence does not hold it).
#   S7  empty_run write does NOT corpse (seat_dead stays false on the marker)
#       — the corpse fence is spawn_fail-only.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-spawn-corpse.XXXXXX)"
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
export PI_SEAT_LIB_CHECK_TRANSPORT=0
# Keep the corpse threshold low so the test does not need 47 spawn-fails. Keep
# the generic ceiling HIGH so the corpse fence is the ONLY thing holding the
# seat (cleanly isolates the #3889 behaviour from the #3826 ceiling fence).
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=3
export SEAT_FAILURE_CEILING=20
export SEAT_PARK_WALL_S=86400
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

# Write a false-healthy / recovery observation to the ledger, mirroring what
# seat-health.ts (after_provider_response) and comeback-release (unwall_seat)
# write. $4=source, $5=observed_at ISO.
write_ledger_obs() {
    local p="$1" m="$2" src="$3" obs="$4" lf="$5"
    local tmp="$lf.obs.$$.$RANDOM.tmp"
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg obs "$obs" --arg src "$src" \
        '{provider:$provider, model:$model, http_status:200,
          health_class:"healthy", retryable:false, seat_dead:false,
          poison_ladder:false, observed_at:$obs,
          source:$src, failure_mode:"none",
          usable_at:null, consecutive_failure_count:0}' \
        > "$tmp" 2>/dev/null
    mv "$tmp" "$lf" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# --- S1: sub-threshold spawn_fail stays non-corpse -------------------------
rm -f "$lf" "$mf"
if ! mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1; then
    fail "S1: mark_seat_spawn_fail (count=1) failed"
fi
ldead=$(jq -r '.seat_dead // false' "$lf" 2>/dev/null || echo false)
mdead=$(jq -r '.seat_dead // false' "$mf" 2>/dev/null || echo false)
[[ "$ldead" == "false" ]] || fail "S1: sub-threshold LEDGER seat_dead=$ldead, want false"
[[ "$mdead" == "false" ]] || fail "S1: sub-threshold MARKER seat_dead=$mdead, want false"
ok "S1: count=1 -> seat_dead=false in ledger + marker (below threshold, unchanged)"

# --- S2: at-threshold (3) spawn_fail -> corpse in ledger AND marker ---------
rm -f "$lf" "$mf"
for i in 1 2 3; do
    mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 \
        || fail "S2: mark_seat_spawn_fail #$i failed"
done
c=$(jq -r '.consecutive_failure_count // 0' "$mf")
(( c >= 3 )) || fail "S2: marker count=$c did not reach threshold (3)"
ldead=$(jq -r '.seat_dead // false' "$lf" 2>/dev/null || echo false)
mdead=$(jq -r '.seat_dead // false' "$mf" 2>/dev/null || echo false)
[[ "$ldead" == "true" ]] || fail "S2: at-threshold LEDGER seat_dead=$ldead, want true (corpse reclassification)"
[[ "$mdead" == "true" ]] || fail "S2: at-threshold MARKER seat_dead=$mdead, want true (durable corpse projection)"
ok "S2: count=3 -> CORPSE reclassified in ledger AND projected to marker (seat_dead=true)"

# --- S3: the live chronic streak shape (count=47 -> low threshold 3 already
# --- exceeds; prove higher counts keep the corpse flag) ---------------------
rm -f "$lf" "$mf"
for i in $(seq 1 5); do
    mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 \
        || fail "S3: mark_seat_spawn_fail #$i failed"
done
c=$(jq -r '.consecutive_failure_count // 0' "$mf")
(( c >= 3 )) || fail "S3: marker count=$c did not reach threshold (3)"
mdead=$(jq -r '.seat_dead // false' "$mf" 2>/dev/null || echo false)
[[ "$mdead" == "true" ]] || fail "S3: chronic streak MARKER seat_dead=$mdead, want true"
ok "S3: chronic spawn_fail streak keeps corpse flag on the durable marker (live 47 shape)"

# --- S4: a marker corpse is HELD durably over expired clock + aged marker +
#         false-healthy ledger clobber -----------------------------------------
rm -f "$lf" "$mf"
for i in 1 2 3; do
    mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 \
        || fail "S4: mark_seat_spawn_fail #$i failed (setup corpse)"
done
mdead=$(jq -r '.seat_dead // false' "$mf")
[[ "$mdead" == "true" ]] || fail "S4: expected marker corpse, got seat_dead=$mdead"
# (a) Expire the marker's usable_at (past) AND age the marker > 24h so the
#     #3737/#3826 fresh-marker hold CANNOT fire — only the #3889 corpse hold may.
#     written_at = 25h ago (just over EMPTY_RUN_COUNT_WINDOW_S=86400).
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
old_iso=$(date -u -d "@$(( $(date -u +%s) - 90000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$past_iso")
tmp=$(mktemp); jq --arg u "$past_iso" --arg o "$old_iso" '(.usable_at = $u | .written_at = $o)' "$mf" >"$tmp" && mv "$tmp" "$mf"
mu=$(jq -r '.usable_at' "$mf"); mw=$(jq -r '.written_at' "$mf")
now_s=$(date -u +%s)
mw_s=$(date -u -d "$mw" +%s 2>/dev/null || echo 0)
[[ -n "$mu" && "$mu" == "$past_iso" ]] || fail "S4: harness: marker usable_at not expired ($mu)"
(( mw_s > 0 && (now_s - mw_s) > 86400 )) || fail "S4: harness: marker written_at not aged >24h ($mw)"
# (b) Clobber the ledger to false-healthy: fresh observed_at > marker
#     written_at, http 200, seat_dead false, source=after_provider_response.
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_ledger_obs "$p" "$m" "after_provider_response" "$now_iso" "$lf"
lhc=$(jq -r '.health_class' "$lf"); ldead=$(jq -r '.seat_dead' "$lf")
[[ "$lhc" == "healthy" && "$ldead" == "false" ]] || fail "S4: harness: ledger not false-healthy (hc=$lhc dead=$ldead)"
# (c) Despite all three re-offer paths being clear, the corpse must hold.
if seat_usable "$p" "$m"; then
    fail "S4: marker-declared corpse re-offered despite expired clock + aged marker (>24h fail-open) + false-healthy http 200 ledger — burns a dispatch (fleet-ops#3889)"
fi
ok "S4: marker corpse held DURABLY over expired clock + >24h aged marker + false-healthy 200 ledger"

# --- S5: only a comeback_release recovery re-proves the corpse ----------------
write_ledger_obs "$p" "$m" "comeback_release" "$now_iso" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "S5: seat_usable held a marker corpse after a comeback_release recovery (tool-using probe succeeded) — recovery release broken (fleet-ops#3889)"
fi
ok "S5: comeback_release recovery re-proves and releases the marker corpse"

# --- S6: a sub-threshold seat still releases on a healthy observation -------
rm -f "$lf" "$mf"
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=10
mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 || fail "S6: sub-threshold setup failed"
mdead=$(jq -r '.seat_dead // false' "$mf")
[[ "$mdead" == "false" ]] || fail "S6: harness: marker seat_dead=$mdead, want false"
# Expire the marker's usable_at but keep written_at FRESH (now) so the #3737
# hold + #3826 ceiling fence evaluate; count=1 < threshold(10) < ceiling(20),
# so the ONLY thing that could hold is a buggy corpse fence. A newer healthy
# observation must release the sub-threshold seat (normal recovery).
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
later_iso=$(date -u -d "@$(( $(date -u +%s) + 120 ))" +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp); jq --arg u "$past_iso" --arg w "$now_iso" '(.usable_at = $u | .written_at = $w)' "$mf" >"$tmp" && mv "$tmp" "$mf"
write_ledger_obs "$p" "$m" "after_provider_response" "$later_iso" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "S6: sub-threshold seat held after a newer healthy observation — normal recovery path broken by the #3889 corpse fence"
fi
ok "S6: sub-threshold seat still released by a newer healthy observation (normal recovery intact)"
# reset for S7
unset SEAT_DEAD_CONSECUTIVE_THRESHOLD

# --- S7: empty_run does NOT corpse -------------------------------------------
rm -f "$lf" "$mf"
for i in 1 2 3; do
    mark_seat_empty_run "$p" "$m" "tools=0 empty" >/dev/null 2>&1 \
        || fail "S7: mark_seat_empty_run #$i failed"
done
mdead=$(jq -r '.seat_dead // false' "$mf" 2>/dev/null || echo false)
[[ "$mdead" == "false" ]] || fail "S7: empty_run marker seat_dead=$mdead, want false (no-op bench is a HOLD, not a corpse — fleet-ops#3675/#3889)"
ok "S7: empty_run marker stays seat_dead=false (no-op bench is not a corpse; corpse fence is spawn_fail-only)"

ok "seat spawn corpse: chronic spawn_fail past the threshold is durably classed a CORPSE (ledger + marker seat_dead=true) and held regardless of HTTP 200, released only by a recovery probe (#3889)"
