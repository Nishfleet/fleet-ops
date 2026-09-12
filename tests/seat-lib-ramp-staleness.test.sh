#!/usr/bin/env bash
# tests/seatlib-ramp-staleness.test.sh
#
# fleet-ops#4723: the AIMD ramp ratchet. A ramp=true entry bypasses the
# declared floor clamp in effective_provider_cap and climbs only +1 per
# probe; a probe requires the provider to actually be picked. A provider
# seeded at floor/2 by a deploy cap change and then walled is never picked,
# never probes, and stays pinned below its declared cap after the wall
# lifts. Measured on the live fleet 2026-09-09: xkiro learned_cap=1 of
# declared 3, ramp=true, last_at 2026-09-07T16:58Z (42h stale), while the
# intake reported "usable seat slots 3 < capacity slots 8" against
# target_concurrent=25.
#
# Acceptance:
#   1. FRESH ramp (last_at now) still ramps: cap stays below declared.
#      Guards the fleet-ops#3690 slow-start this must not undo.
#   2. STALE ramp (last_at older than LEARNED_RAMP_STALE_S) graduates:
#      the declared floor applies again.
#   3. Missing/unparseable last_at does NOT graduate (fail closed: never
#      raise a cap on a reading failure).
#
# Pure unit test: scratch seat-caps.json + learned-caps.json. No network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/seat-caps.json" <<'JSON'
{
  "providers": {
    "rampy": { "cap": 4, "models": { "m1": { "cap": 4 } } }
  }
}
JSON

# learned-caps with a ramp=true entry at floor/2, timestamp supplied per case.
write_learned() {
  local last_at="$1"
  if [[ "$last_at" == "__absent__" ]]; then
    cat >"$tmp/learned-caps.json" <<'JSON'
{ "providers": { "rampy": { "learned_cap": 2, "last_result": "ramp", "bench_until": null, "ramp": true } } }
JSON
  else
    jq -n --arg t "$last_at" \
      '{providers:{rampy:{learned_cap:2,last_result:"ramp",bench_until:null,ramp:true,last_at:$t}}}' \
      >"$tmp/learned-caps.json"
  fi
}

eff_cap() {
  # Re-source per case so the load path runs fresh (caps are cached in-process).
  SEAT_CAPS_JSON="$tmp/seat-caps.json" \
  LEARNED_CAPS_JSON="$tmp/learned-caps.json" \
  LEARNED_CAPS_AUDIT="$tmp/audit.log" \
  LEDGER_DIR="$tmp/ledger" \
  PI_SEAT_LIB_CHECK_SYSTEMD=0 \
  bash -c '
    set -euo pipefail
    mkdir -p "$LEDGER_DIR"
    # shellcheck disable=SC1090
    source "'"$lib"'" >/dev/null 2>&1 || true
    effective_provider_cap rampy
  ' 2>/dev/null | tail -1
}

# --- 1. fresh ramp keeps ramping (must NOT graduate) ---------------------
write_learned "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
got="$(eff_cap)"
[[ "$got" == "2" ]] || fail "fresh ramp should stay at floor/2 (slow start, fleet-ops#3690); got '$got' want 2"
ok "fresh ramp still ramps (eff=2 < declared 4)"

# --- 2. stale ramp graduates to the declared floor -----------------------
write_learned "$(date -u -d '-48 hours' +%Y-%m-%dT%H:%M:%SZ)"
got="$(eff_cap)"
[[ "$got" == "4" ]] || fail "stale ramp must graduate to declared cap 4 (fleet-ops#4723 ratchet); got '$got'"
ok "stale ramp graduates (eff=4 == declared)"

# --- 3. absent last_at fails closed (no silent cap raise) ----------------
write_learned "__absent__"
got="$(eff_cap)"
[[ "$got" == "2" ]] || fail "absent last_at must NOT graduate (fail closed); got '$got' want 2"
ok "absent last_at fails closed (eff=2)"

# --- 4. unparseable last_at fails closed ---------------------------------
write_learned "not-a-timestamp"
got="$(eff_cap)"
[[ "$got" == "2" ]] || fail "unparseable last_at must NOT graduate (fail closed); got '$got' want 2"
ok "unparseable last_at fails closed (eff=2)"

echo "PASS: tests/seatlib-ramp-staleness.test.sh"
