#!/usr/bin/env bash
# tests/seat-lib-cursor-real-spend.test.sh
#
# fleet-ops#4621: the prepaid-usage counter's `usd_today` for cursor was a
# fabricated 0.000000. The token-derived meter (_provider_daily_spend_usd_tokens)
# is structurally $0 for cursor (cursor-cli sessions record 0 usage tokens and
# pi-models.json carries no cursor cost), so it reported a false 0 while 50
# cursor-grok-4.6-high senior sessions ran and the $400 Ultra INCLUDED API
# bucket drained. The real spend is read from the vendor dashboard by
# bin/fleet-prepaid-util-canary into prepaid-spend/<p>.json
# (api_bucket_used_usd = planUsage.apiPercentUsed x limit, GetCurrentPeriodUsage).
#
# _record_prepaid_pick must prefer that real dashboard figure over the
# token-derived estimate. What we prove:
#   1. With a prepaid-spend/cursor.json carrying api_bucket_used_usd, the
#      prepaid-usage counter's usd_today reflects the real figure (not 0).
#   2. Without a prepaid-spend file, the token-derived path is unchanged
#      (Pareto Pass keeps its meter, fleet-ops#4453).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-cursor.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export PI_PACKET_STATE="$scratch/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_PACKET_REPO=""
mkdir -p "$PI_PACKET_STATE/prepaid-usage" "$PI_PACKET_STATE/prepaid-spend" "$scratch/ledger"

# Minimal seat-caps + models so load_seat_caps and the token meter run.
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
    bash -c 'source "$0"; load_seat_caps; _record_prepaid_pick "$1"' "$lib" "$1" 2>/dev/null
}

# --- scenario 1: real dashboard spend is reflected (not a fabricated 0) -----
echo "--- scenario 1: prepaid-spend dashboard figure lands in usd_today ---"
cat >"$PI_PACKET_STATE/prepaid-spend/cursor.json" <<'JSON'
{"provider":"cursor","api_bucket_used_usd":18.0,"api_bucket_remaining_usd":382.0,"api_bucket_limit_usd":400.0,"source":"cursor-dashboard-getcurrentperiodusage"}
JSON
record_pick cursor
cf="$PI_PACKET_STATE/prepaid-usage/cursor.json"
[[ -f "$cf" ]] || fail "scenario 1: prepaid-usage/cursor.json not written"
ut=$(jq -r '.usd_today // ""' "$cf")
[[ "$ut" == "18.0" ]] \
    && ok "scenario 1: usd_today=$ut (real dashboard figure, not 0)" \
    || fail "scenario 1: expected usd_today=18.0 (the dashboard figure), got '$ut'"

# --- scenario 2: no prepaid-spend file -> token-derived path unchanged ------
echo "--- scenario 2: no dashboard file leaves the token meter intact ---"
rm -f "$PI_PACKET_STATE/prepaid-spend/cursor.json"
rm -f "$cf"
# A cursor session with usage tokens would still meter 0 (no cost card); the
# point is the override no-ops and usd_today stays a numeric 0, not a fault.
record_pick cursor
[[ -f "$cf" ]] || fail "scenario 2: counter not written"
ut=$(jq -r '.usd_today // ""' "$cf")
[[ "$ut" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    && ok "scenario 2: usd_today=$ut (token-derived path, no dashboard override)" \
    || fail "scenario 2: usd_today non-numeric: '$ut'"

ok "seat-lib-cursor-real-spend: all scenarios pass"