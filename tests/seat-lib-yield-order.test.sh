#!/usr/bin/env bash
# tests/seat-lib-yield-order.test.sh
#
# fleet-ops#3125 (accepted assumption + decisions 2026-09-04): product picks
# (PI_PICK_ROLE=product, exported by pi-issue-run/pi-packet-run) order issue-
# work seats by the rolling PR-yield ledger (config/seat-caps.json
# product_order: "yield") instead of the retired volume front-of-ladder.
# The ledger itself is written by libexec/fleet-metrics-export.py
# (fleet-ops#3250) as a top-level {"provider/model": {yield, sessions,
# provisional}} JSON. This drill proves pick_seat behaviour the config drill
# cannot see:
#   1. Product picks route to the highest-yield seat (ledger beats the class
#      ladder: a 0.90-yield prepaid seat beats the free-first pick).
#   2. Ties in yield break by class: prepaid-quota before metered before
#      free, so prepaid subs still drain first among equal performers.
#   3. A seat absent from the ledger falls back to provisional 0.5 and is
#      tried, not starved.
#   4. Scout/canary/audit picks (any other PI_PICK_ROLE) keep the free-first
#      class ladder; the ledger is ignored.
#   5. The pick_seat yield-order log line fires once per product pick.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Scratch models/caps/yield so live state cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t seat-lib-yield-order.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    },
    "xai-oauth": {
      "models": [ { "id": "grok-4.6", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    },
    "commandcode": {
      "models": [ { "id": "poolside/laguna-s-2.1-free", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    },
    "openrouter": {
      "models": [ { "id": "deepseek/deepseek-v4-flash-0731", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "product_order": "yield",
  "free_providers_in_order": ["commandcode"],
  "prepaid_providers_in_order": ["devin", "xai-oauth"],
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800
  },
  "providers": {
    "devin": { "cap": 2, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "xai-oauth": { "cap": 2, "class": "prepaid-quota", "models": { "grok-4.6": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "poolside/laguna-s-2.1-free": 1 } },
    "openrouter": { "cap": 2, "class": "metered", "models": { "deepseek/deepseek-v4-flash-0731": 1 } }
  }
}
JSON

# Ledger shape matches what libexec/fleet-metrics-export.py writes
# (fleet-ops#3250): top-level {"provider/model": {yield, sessions,
# provisional}}. <20 sessions => provisional true with 0.5 yield.
cat >"$scratch/seat-yield.json" <<'JSON'
{
  "devin/glm-5-2": { "yield": 0.70, "sessions": 30, "pr_count": 21, "provisional": false },
  "xai-oauth/grok-4.6": { "yield": 0.90, "sessions": 25, "pr_count": 22, "provisional": false },
  "commandcode/poolside/laguna-s-2.1-free": { "yield": 0.05, "sessions": 40, "pr_count": 2, "provisional": false },
  "openrouter/deepseek/deepseek-v4-flash-0731": { "yield": 0.50, "sessions": 25, "pr_count": 12, "provisional": false }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_PACKET_STATE="$scratch/state"
export SEAT_YIELD_JSON="$scratch/seat-yield.json"
export PI_SEAT_CREDENTIAL_PRECHECK=0
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export QUALITY_ROUTING_JSON="$scratch/missing-quality.json"
export QUALITY_SCOREBOARD_JSON="$scratch/missing-scoreboard.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
mkdir -p "$PI_PACKET_STATE" "$PI_SEAT_HEALTH_LEDGER_DIR"

pick() {
    # pick <role> [tried]
    local role="${1:-scout}" tried="${2:-}"
    if [[ -n "$tried" ]]; then
        bash -c 'source "$0"; load_seat_caps; PI_PICK_ROLE="'"$role"'" pick_seat "" "" 0 "'"$tried"'" light' "$lib" 2>/dev/null
    else
        bash -c 'source "$0"; load_seat_caps; PI_PICK_ROLE="'"$role"'" pick_seat "" "" 0 "" light' "$lib" 2>/dev/null
    fi
}

# --- 1. product picks route by yield (highest-yield, not free-first) ------
prod1=$(SEAT_YIELD_JSON="$scratch/seat-yield.json" pick product) || fail "1: product pick must succeed"
[[ "$prod1" == "xai-oauth	grok-4.6" ]] \
  || fail "1: product expected xai-oauth/grok-4.6 (yield 0.90 > glm-5-2 0.70 > openrouter 0.50 > commandcode 0.05), got: $prod1"
ok "1: product pick routes to the highest-yield seat (xai-oauth/grok-4.6), not free-first"

# --- 2. ties break by class: prepaid before metered before free -------------
# Equate grok-4.6 with openrouter at 0.50 (and drop glm-5-2 below both):
# prepaid must win the metered tie, glm-5-2 must not interfere.
python3 - <<PY
import json
y = json.load(open("$scratch/seat-yield.json".replace("$scratch", "$scratch")))
y["xai-oauth/grok-4.6"]["yield"] = 0.5
y["devin/glm-5-2"]["yield"] = 0.4
json.dump(y, open("$scratch/seat-yield-tie.json", "w"), sort_keys=True)
PY
prod2=$(SEAT_YIELD_JSON="$scratch/seat-yield-tie.json" pick product) || fail "2: product tie pick must succeed"
[[ "$prod2" == "xai-oauth	grok-4.6" ]] \
  || fail "2: tie at 0.50 must break to prepaid xai-oauth/grok-4.6 (openrouter is metered), got: $prod2"
ok "2: equal yields break by class (prepaid xai-oauth before metered openrouter)"

# --- 3. seats absent from the ledger get provisional 0.5 (tried, not starved) ---
tried="$scratch/tried.txt"
printf 'xai-oauth/grok-4.6\ndevin/glm-5-2\ncommandcode/poolside/laguna-s-2.1-free\n' >"$tried"
cat >"$scratch/seat-yield-provisional.json" <<'JSON'
{
  "devin/glm-5-2": { "yield": 0.70, "sessions": 30, "pr_count": 21, "provisional": false },
  "xai-oauth/grok-4.6": { "yield": 0.90, "sessions": 25, "pr_count": 22, "provisional": false },
  "commandcode/poolside/laguna-s-2.1-free": { "yield": 0.05, "sessions": 40, "pr_count": 2, "provisional": false }
}
JSON
prod3=$(SEAT_YIELD_JSON="$scratch/seat-yield-provisional.json" pick product "$tried") || fail "3: provisional pick must succeed"
[[ "$prod3" == "openrouter	deepseek/deepseek-v4-flash-0731" ]] \
  || fail "3: openrouter must be picked after the higher seats are tried, got: $prod3"
ok "3: tried seats excluded; remaining candidate still offered (ledger absent seats never starve a pick)"

# --- 4. scout/canary/audit keep free-first; the ledger is ignored ----------
scout=$(SEAT_YIELD_JSON="$scratch/seat-yield.json" pick scout) || fail "4: scout pick must succeed"
[[ "$scout" == "commandcode	poolside/laguna-s-2.1-free" ]] \
  || fail "4: scout must keep free-first (commandcode), got: $scout"
ok "4: scout role keeps free-first (commandcode), ignoring the 0.90-yield prepaid seat"

# --- 5. the yield-order log line fires once per product pick ---------------
export SEAT_LOG_FORCE_FILE=1
export PI_PACKET_STATE="$scratch/state-log"
mkdir -p "$PI_PACKET_STATE"
SEAT_YIELD_JSON="$scratch/seat-yield.json" bash -c \
  'source "$0"; load_seat_caps; PI_PICK_ROLE=product pick_seat "" "" 0 "" light >/dev/null' "$lib" 2>/dev/null || true
picklog="$PI_PACKET_STATE/watch.log"
[[ -f "$picklog" ]] || fail "5: missing pick log $picklog"
grep -c 'yield-order (product):' "$picklog" | grep -qx '1' \
  || fail "5: expected exactly one yield-order log line, got: $(grep -c 'yield-order (product):' "$picklog" 2>/dev/null || echo 0)"
grep 'yield-order (product):' "$picklog" | grep -q 'xai-oauth/grok-4.6@0.9' \
  || fail "5: log must show the computed order with yields"
ok "5: pick_seat logs the yield order once per pick"

ok "seat-lib-yield-order: product-yield ordering, class tie-break, provisional, scout free-first, log line"