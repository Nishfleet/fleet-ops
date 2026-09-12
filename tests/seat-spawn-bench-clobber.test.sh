#!/usr/bin/env bash
# tests/seat-spawn-bench-clobber.test.sh
#
# fleet-ops#1512: a wrapper-written spawn-fail/empty-run bench must survive a
# later healthy observation that seat-health.ts writes to the per-seat ledger.
#
# Root cause: the ledger file is co-written by the pi seat-health.ts extension
# (after_provider_response / cli_spawn) AND by the wrapper-side
# mark_seat_spawn_fail / mark_seat_empty_run functions. A seat that is HTTP-200
# with a non-empty body but functionally dead for an agentic packet (tools=0 /
# no diagnosis block) gets benched by mark_seat_spawn_fail as
# health_class:"transient_fault" + future usable_at. But a LATER healthy
# observation from seat-health.ts (a different worker's simple packet that
# produced output) clobbers the ledger back to health_class:"healthy" + null
# usable_at, so seat_usable re-admits the dead seat on the next trip and the
# organ (stop-escalation.service) fails again.
#
# The fix: a separate clobber-proof marker file (<seat>.spawn-bench.json)
# written ONLY by the wrapper, checked by seat_usable BEFORE trusting the
# ledger's health_class. The marker survives the clobber; seat_usable honours
# it until usable_at expires (fail-open, same as the ledger's own bench_until).
#
# This test proves:
#   (1) mark_seat_spawn_fail writes the spawn-bench marker.
#   (2) After a healthy ledger clobber, seat_usable STILL returns unusable
#       (marker held over the stale healthy ledger entry).
#   (3) After the marker's usable_at expires, seat_usable keeps a FRESH
#       marker held while it is the seat's latest evidence (probe-gated
#       re-admission, fleet-ops#3737); post-bench evidence or marker age
#       >24h releases it.
#   (4) mark_seat_empty_run writes the marker too (same clobber survival).
#   (5) A seat with NO marker and a healthy ledger is usable (no false block).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-spawn-bench-clobber.XXXXXX)"
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

# Simulate seat-health.ts writing a healthy observation to the ledger (the
# clobber). This is exactly what the extension's writeSeatLedgerEntry does on
# an after_provider_response HTTP-200 with a non-empty body: health_class
# flips to "healthy", usable_at to null.
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

p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# --- (5) baseline: no marker + healthy ledger => usable --------------------
clobber_with_healthy "$p" "$m" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "baseline: healthy ledger with no marker returned unusable (false block)"
fi
ok "baseline: healthy ledger + no marker => usable (no false block)"

# --- (1) mark_seat_spawn_fail writes the marker ----------------------------
rm -f "$lf" "$mf"
mark_seat_spawn_fail "$p" "$m" "test:spawn:no-block" >/dev/null 2>&1 \
  || fail "mark_seat_spawn_fail failed"
[[ -f "$mf" ]] || fail "spawn-fail did not write the spawn-bench marker at $mf"
marker_usable=$(jq -r '.usable_at // ""' "$mf")
[[ -n "$marker_usable" ]] || fail "spawn-bench marker has no usable_at"
ok "mark_seat_spawn_fail wrote spawn-bench marker (usable_at=$marker_usable)"

# --- (2) healthy ledger clobber does NOT re-admit the benched seat ---------
# This is the core regression: before the fix, the clobber flipped seat_usable
# back to usable and the organ re-picked the dead seat.
clobber_with_healthy "$p" "$m" "$lf"
ledger_hc=$(jq -r '.health_class' "$lf")
[[ "$ledger_hc" == "healthy" ]] || fail "clobber did not flip ledger to healthy (hc=$ledger_hc)"
if seat_usable "$p" "$m"; then
    fail "REGRESSION: seat_usable returned usable after healthy clobber — spawn-bench marker not honoured"
fi
ok "REGRESSION FIXED: seat_usable held unusable after healthy ledger clobber (marker honoured)"

# --- (3) expired marker is probe-gated while it is the latest evidence ---
# fleet-ops#3737: an expired wrapper bench no longer fails open — while the
# marker is fresh (< EMPTY_RUN_COUNT_WINDOW_S) and still the seat's latest
# evidence, seat_usable holds it for the comeback organ's tool-using probe,
# so a dead-weight seat never costs a work item a turn. The ledger's
# clobbered-healthy write here has observed_at == the marker's write
# instant (the mid-run 200 the extension logged during the empty run), so
# the marker remains the latest evidence.
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
marker_written=$(jq -r '.written_at // ""' "$mf")
[[ -n "$marker_written" ]] || fail "spawn-bench marker has no written_at"
tmp=$(mktemp)
jq --arg o "$marker_written" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if seat_usable "$p" "$m"; then
    fail "seat_usable fail-opened an expired fresh marker that is the latest evidence — probe-gate broken (fleet-ops#3737)"
fi
ok "expired fresh marker held as latest evidence — probe-gated re-admission (fleet-ops#3737)"

# --- (3b) post-bench evidence releases ------------------------------------
# A ledger observation NEWER than the marker's written_at means a real run
# produced output after the bench was written — recovery evidence, so the
# ledger decides again (healthy -> usable).
tmp=$(mktemp)
later_iso=$(date -u -d "@$(( $(date -u -d "$marker_written" +%s) + 120 ))" +%Y-%m-%dT%H:%M:%SZ)
jq --arg o "$later_iso" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable held a seat with post-bench healthy evidence — recovery release broken"
fi
ok "post-bench healthy observation releases the expired marker — recovered seat re-eligible"

# --- (3c) archaeology escape: a stale marker fail-opens -------------------
# A marker older than the count window is archaeology — fail-open so a
# stalled comeback organ cannot strand the seat forever.
tmp=$(mktemp)
old_iso=$(date -u -d "@$(( $(date -u +%s) - 90000 ))" +%Y-%m-%dT%H:%M:%SZ)
jq --arg w "$old_iso" '.written_at = $w' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
tmp=$(mktemp)
jq --arg o "$old_iso" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable held a stale (>24h) marker — dead-organ escape hatch broken"
fi
ok "stale marker (>24h) fail-opens — dead-organ escape hatch intact"

# --- (4) mark_seat_empty_run writes the marker + survives clobber ----------
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "test:empty:tools=0" >/dev/null 2>&1 \
  || fail "mark_seat_empty_run failed"
[[ -f "$mf" ]] || fail "empty-run did not write the spawn-bench marker"
clobber_with_healthy "$p" "$m" "$lf"
if seat_usable "$p" "$m"; then
    fail "REGRESSION: empty-run bench not held over healthy clobber"
fi
ok "mark_seat_empty_run marker survives healthy clobber (held unusable)"

# --- marker is independent of ledger file presence -------------------------
# If the ledger is deleted but the marker is fresh, seat_usable must still
# block (the marker is the wrapper's bench, not the ledger's).
rm -f "$lf"
mark_seat_spawn_fail "$p" "$m" "test:no-ledger" >/dev/null 2>&1 || true
[[ -f "$lf" ]] || fail "mark_seat_spawn_fail did not re-create the ledger"
# Delete the ledger to simulate it being absent; marker alone should block.
rm -f "$lf"
if seat_usable "$p" "$m"; then
    fail "seat_usable returned usable with no ledger but a fresh marker — marker ignored when ledger absent"
fi
ok "fresh marker blocks even when ledger file is absent (wrapper bench is independent)"

ok "seat spawn-bench clobber: wrapper bench survives healthy ledger clobber (#1512)"
