#!/usr/bin/env bash
# tests/seat-lib-product-only-spend-cap.test.sh
#
# fleet-ops#3724: the paid openrouter/deepseek-v4-flash-0731 seat is a
# product_only last-resort seat with a USD/day spend cap. pick_seat may offer
# it ONLY when all of these hold:
#   1. the packet repo carries the `product` flag in config/intake-repos.json
#      (0509 today; fleet-ops is control plane and must NEVER land on it;
#      an unclassified packet repo fails closed),
#   2. no free/prepaid seat is usable — the seat sits in a last-resort bucket
#      appended after every class in every pick order, including the product
#      value order (a high-yield paid seat must still lose to a usable free
#      seat),
#   3. today's (UTC) Pi usage.cost on the seat is below daily_spend_cap_usd —
#      reaching it writes a quota_bench/quota_cap ledger entry (a money wall
#      the seat-floor fail-open never lifts) with a dated reason, benching
#      the seat until 00:00 UTC, consecutive_failure_count=0 (never charged
#      to the work item).
#
# What we prove (replay drill against synthetic Pi session files):
#   1. Packet repo = fleet-ops (control plane): the paid seat is never
#      offered — pick_seat returns nothing even when it is the only seat
#      with cap>0.
#   2. Packet repo unclassified (no PI_PACKET_REPO): same — fails closed.
#   3. Packet repo = 0509 (product): a usable free seat wins even when the
#      paid seat's rolling yield is higher in the product value order.
#   4. Packet repo = 0509 with the free seat unusable (benched): the paid
#      seat IS offered — last resort works.
#   5. Spend at/above daily_spend_cap_usd: the seat is benched until
#      00:00 UTC (source=daily_spend_cap, consecutive_failure_count=0, dated
#      reason) and not offered; the free seat takes over.
#   6. Yesterday's spend does not count: a session file whose cost lines are
#      timestamped yesterday leaves today's counter at 0 — the seat is
#      offered for a product repo.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-po.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: no live systemd units, no no-usable-seat cooldown.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0

export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

# The paid openrouter seat plus a free ollama fallback lane.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "openrouter": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash-0731", "cost": { "input": 0.045 } }
      ]
    },
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON

# seat-caps: openrouter metered, the paid model flagged product_only with a
# USD 2/day spend cap (small so the drill does not need large fixture sums);
# ollama free with a free model. product_order=value so scenario 3 also
# exercises the product value ordering.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "product_order": "value",
  "free_providers_in_order": ["ollama"],
  "providers": {
    "openrouter": {
      "cap": 1,
      "class": "metered",
      "models": {
        "deepseek/deepseek-v4-flash-0731": {
          "cap": 1,
          "product_only": true,
          "daily_spend_cap_usd": 2
        }
      }
    },
    "ollama": {
      "cap": 2,
      "class": "free",
      "models": {
        "deepseek-v4-flash:0731": 2
      }
    }
  }
}
JSON

# intake-repos fixture: 0509 is the product repo; fleet-ops is control plane.
cat >"$scratch/intake-repos.json" <<'JSON'
{
  "checkout_root": "/home/nish/workspaces/products",
  "repos": [
    { "name": "0509", "product": true },
    { "name": "fleet-ops", "product": false }
  ]
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export FLEET_INTAKE_REPOS_JSON="$scratch/intake-repos.json"
ledger="$scratch/ledger"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"

# Helper: write a synthetic Pi session file under FLEET_SESSIONS_DIR.
# Args: relative_dir filename provider modelId assistant_turns cost_per_turn
write_session() {
    local dir="$1" name="$2" prov="$3" model="$4" turns="${5:-0}" cost="${6:-0}"
    local sd="${FLEET_SESSIONS_DIR:-$scratch/sessions}/$dir"
    mkdir -p "$sd"
    local f="$sd/$name"
    {
        printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"/home/nish"}\n' \
            "$name" "${name%%_*}"
        printf '{"type":"model_change","id":"m1","parentId":null,"timestamp":"%s","provider":"%s","modelId":"%s"}\n' \
            "${name%%_*}" "$prov" "$model"
        printf '{"type":"thinking_level_change","id":"t1","parentId":"m1","timestamp":"%s","thinkingLevel":"off"}\n' \
            "${name%%_*}"
        local i
        for ((i = 0; i < turns; i++)); do
            printf '{"type":"message","id":"u%d","parentId":"t1","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n' \
                "$i" "${name%%_*}"
            printf '{"type":"message","id":"a%d","parentId":"u%d","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input":10,"output":5,"cost":{"input":0,"output":0,"total":%s}}}}\n' \
                "$i" "$i" "${name%%_*}" "$cost"
        done
    } >"$f"
}

# pick helper: runs pick_seat in a clean bash with the given repo env.
# Args: packet_repo pick_role
run_pick() {
    local repo="$1" role="${2:-scout}"
    if [[ -n "$repo" ]]; then
        bash -c 'source "$0"; load_seat_caps; PI_PACKET_REPO="'"$repo"'" PI_PICK_ROLE="'"$role"'" pick_seat "" "" 0 "" light' "$lib" 2>/dev/null
    else
        bash -c 'source "$0"; load_seat_caps; unset PI_PACKET_REPO; PI_PICK_ROLE="'"$role"'" pick_seat "" "" 0 "" light' "$lib" 2>/dev/null
    fi
}

today=$(date -u +%Y-%m-%d)
yesterday=$(date -u -d "yesterday" +%Y-%m-%d)

# --- scenario 1: fleet-ops packet can never take the paid seat -----------
echo "--- scenario 1: packet repo fleet-ops -> paid seat refused ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-empty"
# Bench the free lane so the paid seat is the ONLY cap>0 candidate; the pick
# must still refuse it for fleet-ops (repo gate beats last-resort).
cat >"$scratch/ledger-bench" <<'EOF'
EOF
_ps="ollama"; _ms="deepseek-v4-flash:0731"
_ps="${_ps//[^A-Za-z0-9._-]/_}"; _ms="${_ms//[^A-Za-z0-9._-]/_}"
free_bench="$ledger/${_ps}__${_ms}.json"
jq -nc --arg u "2999-01-01T00:00:00Z" \
  '{provider:"ollama",model:"deepseek-v4-flash:0731",health_class:"quota_bench",http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:"2026-09-06T00:00:00Z",source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
  > "$free_bench"
set +e
out=$(run_pick "fleet-ops" product)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] || fail "fleet-ops: expected no pick, got rc=$rc out=$out"
printf '%s' "$out" | grep -q "openrouter" \
    && fail "fleet-ops: paid openrouter seat was offered to a control-plane repo, got: $out" \
    || ok "fleet-ops: paid seat refused for fleet-ops packet (rc=$rc)"

# --- scenario 2: unclassified packet repo fails closed -------------------
echo "--- scenario 2: no packet repo -> paid seat refused (fail-closed) ---"
set +e
out=$(run_pick "" product)
rc=$?
set -e
printf '%s' "$out" | grep -q "openrouter" \
    && fail "unclassified: paid seat offered with no packet repo, got: $out" \
    || ok "unclassified: paid seat refused without a packet repo (rc=$rc)"

# --- scenario 3: product repo + usable free seat -> free wins ------------
echo "--- scenario 3: 0509 packet + usable free seat -> paid seat loses even at higher yield ---"
rm -f "$ledger"/*.json
export FLEET_SESSIONS_DIR="$scratch/sessions-empty"
# Give the paid seat a perfect rolling yield and the free seat a mediocre
# one — in the product value order the paid seat would rank FIRST if it were
# bucketed normally. product_only must keep it last regardless.
cat >"$scratch/seat-yield.json" <<'JSON'
{
  "openrouter/deepseek/deepseek-v4-flash-0731": {"yield": 1.0, "sessions": 25, "provisional": false, "cost_per_session": 0.01},
  "ollama/deepseek-v4-flash:0731": {"yield": 0.4, "sessions": 25, "provisional": false, "cost_per_session": 0}
}
JSON
export SEAT_YIELD_JSON="$scratch/seat-yield.json"
set +e
out=$(run_pick "0509" product)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "product+free-usable: expected a pick, got rc=$rc"
printf '%s' "$out" | grep -q "ollama" \
    && ok "product+free-usable: free lane picked while paid seat waits last" \
    || fail "product+free-usable: free lane NOT picked, got: $out"
printf '%s' "$out" | grep -q "openrouter" \
    && fail "product+free-usable: paid seat was picked over a usable free seat, got: $out" \
    || true

# --- scenario 4: product repo, free lane unusable -> paid seat offered ---
echo "--- scenario 4: 0509 packet + free lane benched -> paid seat offered ---"
_ps="ollama"; _ms="deepseek-v4-flash:0731"
_ps="${_ps//[^A-Za-z0-9._-]/_}"; _ms="${_ms//[^A-Za-z0-9._-]/_}"
jq -nc --arg u "2999-01-01T00:00:00Z" \
  '{provider:"ollama",model:"deepseek-v4-flash:0731",health_class:"quota_bench",http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:"2026-09-06T00:00:00Z",source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
  > "$ledger/${_ps}__${_ms}.json"
set +e
out=$(run_pick "0509" product)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "product+no-free: expected the paid seat, got rc=$rc"
printf '%s' "$out" | grep -q "openrouter" \
    && ok "product+no-free: paid seat offered as last resort for product repo" \
    || fail "product+no-free: paid seat NOT offered for product repo, got: $out"

# --- scenario 5: spend at cap -> bench until 00:00 UTC -------------------
echo "--- scenario 5: today's usage.cost >= cap -> seat benched to 00:00 UTC ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-spend"
# 4 assistant turns at USD 0.60 each = 2.40 >= the 2.00 cap.
write_session "pi-issue-test-5" "${today}T06-00-00-000Z_test-5.jsonl" "openrouter" "deepseek/deepseek-v4-flash-0731" 4 0.60
rm -f "$ledger"/*.json
set +e
out=$(run_pick "0509" product)
rc=$?
set -e
printf '%s' "$out" | grep -q "openrouter" \
    && fail "spend-cap: paid seat offered despite daily spend cap, got: $out" \
    || ok "spend-cap: paid seat skipped at the USD cap"
# Free fallback picked.
printf '%s' "$out" | grep -q "ollama" \
    && ok "spend-cap: free fallback picked" \
    || fail "spend-cap: free fallback NOT picked, got: $out"
# Ledger entry: quota_bench money wall, count 0, dated reason, source tag.
_ps="openrouter"; _ms="deepseek/deepseek-v4-flash-0731"
_ps="${_ps//[^A-Za-z0-9._-]/_}"; _ms="${_ms//[^A-Za-z0-9._-]/_}"
bf="$ledger/${_ps}__${_ms}.json"
[[ -f "$bf" ]] || fail "spend-cap: bench ledger file not written at $bf"
hc=$(jq -r '.health_class // ""' "$bf")
fm=$(jq -r '.failure_mode // ""' "$bf")
cfc=$(jq -r '.consecutive_failure_count // "MISSING"' "$bf")
src=$(jq -r '.source // ""' "$bf")
rsn=$(jq -r '.reason // ""' "$bf")
bu=$(jq -r '.bench_until // ""' "$bf")
[[ "$hc" == "quota_bench" ]] || fail "spend-cap: health_class=$hc, expected quota_bench"
[[ "$fm" == "quota_cap" ]] || fail "spend-cap: failure_mode=$fm, expected quota_cap (money wall — floor never lifts it)"
[[ "$cfc" == "0" ]] || fail "spend-cap: consecutive_failure_count=$cfc, expected 0 (external budget, not a seat fault)"
[[ "$src" == "daily_spend_cap" ]] || fail "spend-cap: source=$src, expected daily_spend_cap"
printf '%s' "$rsn" | grep -q "^${today}" || fail "spend-cap: reason is not dated today: $rsn"
[[ -n "$bu" ]] || fail "spend-cap: bench_until empty"
ok "spend-cap: quota_bench/quota_cap ledger with dated reason, count 0, until $bu"

# --- scenario 6: yesterday's spend does not count -------------------------
echo "--- scenario 6: yesterday's spend leaves today's counter at 0 ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-yesterday"
# Same 4x0.60 turns but timestamped yesterday — the cap must NOT fire.
# Name the file for yesterday too (the realistic shape); the message-day
# filter is what decides, not the filename.
write_session "pi-issue-test-6" "${yesterday}T23-55-00-000Z_test-6.jsonl" "openrouter" "deepseek/deepseek-v4-flash-0731" 4 0.60
rm -f "$ledger"/*.json
# Bench the free lane so the paid seat is the only candidate — a wrong
# count would stall the pick (rc!=1).
_ps="ollama"; _ms="deepseek-v4-flash:0731"
_ps="${_ps//[^A-Za-z0-9._-]/_}"; _ms="${_ms//[^A-Za-z0-9._-]/_}"
jq -nc --arg u "2999-01-01T00:00:00Z" \
  '{provider:"ollama",model:"deepseek-v4-flash:0731",health_class:"quota_bench",http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:"2026-09-06T00:00:00Z",source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
  > "$ledger/${_ps}__${_ms}.json"
set +e
out=$(run_pick "0509" product)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "yesterday-spend: expected the paid seat, got rc=$rc"
printf '%s' "$out" | grep -q "openrouter" \
    && ok "yesterday-spend: paid seat offered (yesterday's spend not counted)" \
    || fail "yesterday-spend: paid seat NOT offered, got: $out"

echo
echo "ALL OK: fleet-ops#3724 product_only + daily spend cap replay drill"
