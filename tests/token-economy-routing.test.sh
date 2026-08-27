#!/usr/bin/env bash
# tests/token-economy-routing.test.sh
#
# Proves fleet-ops#1167 pick_seat behaviour that the config drill
# (tests/fleet-token-economy.test.sh) cannot see:
#   1. Volume/light packets never land on cursor (keystone-only).
#   2. Leftover prepaid after the volume prefix is xai-oauth, not cursor.
#   3. Keystone (and senior-review) still route to cursor.
#   4. When included_exhausted=true, only cursor-grok-4.6-high is offered.
#   5. Every pick appends seat-selection.jsonl (fleet_seat_selection_24h).
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Scratch models/caps so live seat-caps cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t token-economy-routing.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "cursor": {
      "models": [
        { "id": "composer-2.5", "cost": { "input": 0 }, "contextWindow": 128000 },
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "xai-oauth": {
      "models": [
        { "id": "grok-4.6", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "volume_providers_in_order": ["commandcode"],
  "free_providers_in_order": ["commandcode"],
  "prepaid_providers_in_order": ["cursor", "xai-oauth"],
  "keystone_only_providers": ["cursor"],
  "cursor_overage": {
    "opens_after_included_exhausted": true,
    "overage_model": "cursor-grok-4.6-high",
    "daily_spend_target_usd": 16,
    "included_exhausted": false
  },
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800
  },
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } },
    "cursor": { "cap": 1, "class": "prepaid-quota", "models": { "composer-2.5": 1, "cursor-grok-4.6-high": 1 } },
    "xai-oauth": { "cap": 1, "class": "prepaid-quota", "models": { "grok-4.6": 1 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_CREDENTIAL_PRECHECK=0
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export QUALITY_ROUTING_JSON="$scratch/missing-quality.json"
export QUALITY_SCOREBOARD_JSON="$scratch/missing-scoreboard.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR"

pick() {
    local capable="${1:-0}" difficulty="${2:-light}" tried="${3:-}"
    export PI_PACKET_STATE="$scratch/state-$capable-$difficulty-$$"
    mkdir -p "$PI_PACKET_STATE"
    if [[ -n "$tried" ]]; then
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "'"$tried"'" "'"$difficulty"'"' "$lib" 2>/dev/null
    else
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "" "'"$difficulty"'"' "$lib" 2>/dev/null
    fi
}

# --- 1. light/volume never lands on cursor --------------------------------
light=$(pick 0 light) || fail "1: light pick must succeed"
[[ "$light" == "commandcode	deepseek/deepseek-v4-flash" ]] \
  || fail "1: light expected commandcode (volume prefix), got: $light"
ok "1: light/volume picks commandcode, not cursor"

# --- 2. leftover prepaid is xai-oauth, not cursor -------------------------
tried_vol="$scratch/tried-volume.txt"
printf 'commandcode/deepseek/deepseek-v4-flash\n' >"$tried_vol"
left=$(pick 0 light "$tried_vol") || fail "2: leftover prepaid pick must succeed"
[[ "$left" == "xai-oauth	grok-4.6" ]] \
  || fail "2: leftover prepaid expected xai-oauth, got: $left"
ok "2: leftover prepaid is xai-oauth, not cursor"

# --- 3. keystone still routes to cursor -----------------------------------
key=$(pick 1 keystone) || fail "3: keystone pick must succeed"
case "$key" in
    "cursor	cursor-grok-4.6-high"|"cursor	composer-2.5")
        ok "3: keystone routes to cursor ($key)"
        ;;
    *) fail "3: keystone expected a cursor seat, got: $key" ;;
esac

# --- 4. senior-review is the same class as keystone -----------------------
sr=$(pick 1 senior-review) || fail "4: senior-review pick must succeed"
case "$sr" in
    "cursor	cursor-grok-4.6-high"|"cursor	composer-2.5")
        ok "4: senior-review routes to cursor ($sr)"
        ;;
    *) fail "4: senior-review expected a cursor seat, got: $sr" ;;
esac

# --- 5. overage pin: included_exhausted skips composer --------------------
jq '.cursor_overage.included_exhausted = true' "$scratch/seat-caps.json" \
  >"$scratch/seat-caps-overage.json"
export SEAT_CAPS_JSON="$scratch/seat-caps-overage.json"
ov=$(pick 1 keystone) || fail "5: overage keystone pick must succeed"
[[ "$ov" == "cursor	cursor-grok-4.6-high" ]] \
  || fail "5: overage expected cursor-grok-4.6-high, got: $ov"
ok "5: included_exhausted pins cursor-grok-4.6-high"

# --- 6. selection ledger is written ---------------------------------------
ledger="$scratch/state-1-keystone-$$/seat-selection.jsonl"
[[ -f "$ledger" ]] || fail "6: missing $ledger"
grep -q '"provider":"cursor"' "$ledger" \
  || fail "6: expected a cursor selection row in $ledger"
prom="$scratch/state-1-keystone-$$/fleet-seat-selection.prom"
[[ -f "$prom" ]] || fail "6b: missing $prom"
grep -q 'fleet_seat_selection_24h{provider="cursor"}' "$prom" \
  || fail "6b: expected fleet_seat_selection_24h cursor row in $prom"
ok "6: pick_seat appends seat-selection.jsonl and writes fleet_seat_selection_24h"

ok "token-economy-routing: cursor keystone-only, leftover prepaid is xai-oauth, overage pin, selection ledger"
