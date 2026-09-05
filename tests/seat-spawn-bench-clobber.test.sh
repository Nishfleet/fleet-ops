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
#   (3) After the marker's usable_at expires, seat_usable fail-opens.
#   (4) mark_seat_empty_run writes the marker too (same clobber survival).
#   (5) A seat with NO marker and a healthy ledger is usable (no false block).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

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

# --- (3) marker expiry fail-opens ------------------------------------------
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable returned unusable after marker expired — fail-open broken (recovered seat walled)"
fi
ok "expired marker fail-opens — recovered seat re-eligible"

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
