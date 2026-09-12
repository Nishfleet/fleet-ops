#!/usr/bin/env bash
# tests/seatlib-cursor-usd-today.test.sh
#
# fleet-ops#4621: cursor-cli sessions record 0 usage tokens and pi-models
# carries no cursor cost, so the token meter is structurally $0. The vendor
# figure (Cursor GetCurrentPeriodUsage included-API-bucket 24h delta) is
# written into prepaid-usage/cursor.json usd_today by
# bin/fleet-prepaid-util-canary. A later pick must not clobber that overlay
# with the token 0, and must keep the provenance fields (source, cycle
# figure, billing lane). Pareto Pass and every other provider keep the
# token path (fleet-ops#4453).
#
# What we prove:
#   1. A vendor overlay (usd_today != 0 / 0.000000, plus provenance) survives
#      _record_prepaid_pick; count increments.
#   2. An UNAVAILABLE:<why> overlay also survives (never replaced with 0).
#   3. With no overlay file, the token-derived path still writes a numeric
#      usd_today (cursor will be 0; that is the pre-canary state, not a fault).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seatlib-cursor-usd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export PI_PACKET_STATE="$scratch/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_PACKET_REPO=""
export SEAT_LOG_FILE="$scratch/watch.log"
mkdir -p "$PI_PACKET_STATE/prepaid-usage" "$scratch/ledger"

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "prepaid_providers_in_order": ["cursor"],
  "providers": {
    "cursor": { "cap": 2, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 2 } }
  }
}
JSON
cat >"$scratch/models.json" <<'JSON'
{"providers":{"cursor":{"models":[{"id":"cursor-grok-4.6-high","cost":null}]}}}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"
export FLEET_SESSIONS_DIR="$scratch/sessions"
mkdir -p "$FLEET_SESSIONS_DIR"

record_pick() {
    bash -c 'source "$0"; load_seat_caps; _record_prepaid_pick "$1"' "$lib" "$1"
}

cf="$PI_PACKET_STATE/prepaid-usage/cursor.json"

# --- 1. vendor overlay survives a pick ------------------------------------
echo "--- scenario 1: vendor usd_today and provenance survive a pick ---"
cat >"$cf" <<'JSON'
{"week":"2026-W37","count":7,"usd_today":"6.3600","cursor_api_cycle_usd":"11.360000","usd_today_source":"cursor-dashboard-getcurrentperiodusage","billing_lane":"ultra-included-api-bucket","provider_daily_logged_429":false,"provider_daily_logged_429_date":"","provider_daily_logged_200":false,"provider_daily_logged_200_date":""}
JSON
record_pick cursor
[[ -f "$cf" ]] || fail "scenario 1: prepaid-usage/cursor.json missing after pick"
ut=$(jq -r '.usd_today // empty' "$cf")
[[ "$ut" == "6.3600" ]] || fail "scenario 1: pick clobbered vendor usd_today (got '$ut')"
[[ "$(jq -r '.count' "$cf")" == "8" ]] || fail "scenario 1: count must increment 7 -> 8"
[[ "$(jq -r '.usd_today_source' "$cf")" == "cursor-dashboard-getcurrentperiodusage" ]] \
    || fail "scenario 1: usd_today_source must survive the pick"
[[ "$(jq -r '.billing_lane' "$cf")" == "ultra-included-api-bucket" ]] \
    || fail "scenario 1: billing_lane must survive the pick"
[[ "$(jq -r '.cursor_api_cycle_usd' "$cf")" == "11.360000" ]] \
    || fail "scenario 1: cursor_api_cycle_usd must survive the pick"
ok "scenario 1: vendor overlay and provenance survive _record_prepaid_pick"

# --- 2. UNAVAILABLE overlay is not replaced with token 0 -------------------
echo "--- scenario 2: UNAVAILABLE usd_today survives a pick ---"
cat >"$cf" <<'JSON'
{"week":"2026-W37","count":8,"usd_today":"UNAVAILABLE:cursor-history-warming","cursor_api_cycle_usd":"11.360000","usd_today_source":"cursor-dashboard-getcurrentperiodusage","billing_lane":"ultra-included-api-bucket","provider_daily_logged_429":false,"provider_daily_logged_429_date":"","provider_daily_logged_200":false,"provider_daily_logged_200_date":""}
JSON
record_pick cursor
ut=$(jq -r '.usd_today // empty' "$cf")
[[ "$ut" == "UNAVAILABLE:cursor-history-warming" ]] \
    || fail "scenario 2: pick replaced UNAVAILABLE with '$ut' (must not fabricate 0)"
[[ "$ut" != "0" && "$ut" != "0.000000" ]] \
    || fail "scenario 2: fabricated 0.000000 is the #4621 bug"
ok "scenario 2: UNAVAILABLE overlay survives a pick"

# --- 3. no overlay -> token path still writes a numeric usd_today ----------
echo "--- scenario 3: no overlay leaves the token meter intact ---"
rm -f "$cf"
record_pick cursor
[[ -f "$cf" ]] || fail "scenario 3: counter not written"
ut=$(jq -r '.usd_today // empty' "$cf")
[[ "$ut" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || fail "scenario 3: usd_today non-numeric: '$ut'"
ok "scenario 3: usd_today=$ut (token-derived path, no overlay)"

ok "seatlib-cursor-usd-today: all scenarios pass"
