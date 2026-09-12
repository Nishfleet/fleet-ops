#!/usr/bin/env bash
# tests/seat-spawn-bench-ceiling-false-healthy.test.sh
#
# fleet-ops#3826: a seat whose spawn-bench marker count is past the failure
# ceiling is CHRONICALLY spawn-failing. seat-health.ts logs a transport 200
# as healthy during the very run that then exits 0 with 0-byte stdout
# (after_provider_response carries status+headers only, never the body), so
# its healthy write (observed_at > marker written_at) is NOT recovery
# evidence — it is the same false-healthy fleet-ops#3737 guards against.
#
# Without the fix the seat is re-offered to a work item every park-wall
# expiry (24h), spawn-fails again (no_block:rc=1), and the count climbs
# forever while the ledger stays health_class=healthy / http 200 (live:
# xkiro/deepseek-v4-flash at 47 consecutive spawn_fail).
#
# The fix: in the #3737 expired-marker hold, when the marker count is past
# the failure ceiling, a newer ledger observation only lifts the hold when
# its source is "comeback_release" (a tool-using probe that proved the seat
# can actually run a packet). A seat-health.ts false-healthy
# (source="after_provider_response") does NOT release a ceiling-parked seat.
#
# This test proves:
#   (1) A ceiling-parked seat with an expired marker usable_at + a newer
#       seat-health.ts healthy ledger write (source=after_provider_response)
#       is HELD unusable (not re-offered to burn a dispatch).
#   (2) The same seat IS released when the newer ledger write carries
#       source="comeback_release" (the comeback probe succeeded).
#   (3) A sub-ceiling seat is NOT affected — a newer healthy observation
#       still releases it (normal recovery path intact).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-spawn-ceiling-false-healthy.XXXXXX)"
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
# Keep the ceiling low so the test does not need 47 spawn-fail calls.
export SEAT_FAILURE_CEILING=3
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

# Write a ledger observation with a given source + observed_at. This mirrors
# what seat-health.ts (after_provider_response) and comeback-release
# (unwall_seat) write to the per-seat ledger.
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

# --- setup: drive the seat past the failure ceiling via spawn-fail --------
# SEAT_FAILURE_CEILING=3, so 4 spawn-fails parks the seat (count=4 >= 3).
rm -f "$lf" "$mf"
for i in 1 2 3 4; do
    mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 \
        || fail "mark_seat_spawn_fail #$i failed"
done
mcount=$(jq -r '.consecutive_failure_count // 0' "$mf")
(( mcount >= 3 )) || fail "marker count=$mcount did not reach ceiling (3)"
ok "setup: marker count=$mcount past ceiling (SEAT_FAILURE_CEILING=3)"

# --- (1) expired marker + false-healthy seat-health.ts write => HELD -------
# Expire the marker's usable_at (set to the past) but keep written_at fresh
# (now) so the #3737 hold applies. Then write a NEWER healthy observation
# with source="after_provider_response" (the seat-health.ts false-healthy).
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
later_iso=$(date -u -d "@$(( $(date -u +%s) + 120 ))" +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp); jq --arg u "$past_iso" '.usable_at = $u' "$mf" >"$tmp" && mv "$tmp" "$mf"
tmp=$(mktemp); jq --arg w "$now_iso" '.written_at = $w' "$mf" >"$tmp" && mv "$tmp" "$mf"
write_ledger_obs "$p" "$m" "after_provider_response" "$later_iso" "$lf"
ledger_hc=$(jq -r '.health_class' "$lf")
[[ "$ledger_hc" == "healthy" ]] || fail "ledger not healthy (hc=$ledger_hc)"
ledger_obs=$(jq -r '.observed_at' "$lf")
marker_written=$(jq -r '.written_at' "$mf")
# observed_at MUST be newer than written_at for the #3737 hold to reach the
# ceiling fence (otherwise the earlier sb_obs_s <= sb_written_s branch holds).
[[ "$(date -u -d "$ledger_obs" +%s)" -gt "$(date -u -d "$marker_written" +%s)" ]] \
    || fail "test harness: ledger observed_at not newer than marker written_at"
if seat_usable "$p" "$m"; then
    fail "REGRESSION: ceiling-parked seat re-offered after false-healthy seat-health.ts write — burns a dispatch (fleet-ops#3826)"
fi
ok "REGRESSION FIXED: ceiling-parked seat held after false-healthy write (source=after_provider_response)"

# --- (2) expired marker + comeback_release unwall => RELEASED --------------
# The comeback-release organ ran a tool-using probe that succeeded and wrote
# source="comeback_release" to the ledger. That IS real recovery — release.
write_ledger_obs "$p" "$m" "comeback_release" "$later_iso" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable held a seat after a comeback_release unwall — real recovery release broken (fleet-ops#3826)"
fi
ok "comeback_release unwall releases the ceiling-parked seat (tool-using probe succeeded)"

# --- (3) sub-ceiling seat: newer healthy observation still releases ---------
# A seat that has NOT reached the ceiling must keep the normal #3737 recovery
# path: a newer healthy observation releases it (no ceiling fence).
rm -f "$lf" "$mf"
export SEAT_FAILURE_CEILING=20
mark_seat_spawn_fail "$p" "$m" "test:spawn:sub-ceiling" >/dev/null 2>&1 \
    || fail "mark_seat_spawn_fail (sub-ceiling) failed"
mcount=$(jq -r '.consecutive_failure_count // 0' "$mf")
(( mcount < 20 )) || fail "sub-ceiling setup wrong (count=$mcount)"
# Expire marker usable_at, fresh written_at, newer healthy ledger obs.
tmp=$(mktemp); jq --arg u "$past_iso" '.usable_at = $u' "$mf" >"$tmp" && mv "$tmp" "$mf"
tmp=$(mktemp); jq --arg w "$now_iso" '.written_at = $w' "$mf" >"$tmp" && mv "$tmp" "$mf"
write_ledger_obs "$p" "$m" "after_provider_response" "$later_iso" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "sub-ceiling seat held after a newer healthy observation — normal recovery path broken by the #3826 fence"
fi
ok "sub-ceiling seat still released by a newer healthy observation (normal recovery intact)"

ok "seat spawn-bench ceiling false-healthy: chronic spawn_fail not re-offered on false-healthy (#3826)"
