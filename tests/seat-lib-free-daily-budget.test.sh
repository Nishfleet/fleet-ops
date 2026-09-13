#!/usr/bin/env bash
# tests/seat-lib-free-daily-budget.test.sh
#
# fleet-ops#3723: OpenRouter's free-model request budget is per ACCOUNT, not
# per key (openrouter.ai/docs/api-reference/limits: "Making additional accounts
# or API keys will not affect your rate limits, as we govern capacity globally").
# The documented daily cap (50 req/day with < $10 credits) is shared across
# every *:free model on the provider. seat-lib counts assistant turns (each
# turn = one model request) across the provider's *:free sessions today (UTC)
# and benches every free model on the provider once the shared counter hits
# the configured budget, until 00:00 UTC.
#
# What we prove (replay drill against synthetic Pi session files):
#   1. Below the cap: an openrouter *:free model is pickable (no bench).
#   2. At/above the cap: the free model is benched (quota_bench ledger entry
#      with bench_until = next 00:00 UTC) and pick_seat skips it.
#   3. The bench is NOT charged to the work item: the ledger's
#      consecutive_failure_count is 0 (an account-wide external limit, not a
#      seat fault — no escalation, no failure ceiling).
#   4. The bench releases after 00:00 UTC: a session file dated tomorrow is
#      not counted, so the counter restarts at 0 and the model is pickable
#      again once the bench_until timestamp passes (fail-open).
#   5. A non-free openrouter model (no :free suffix) is NOT subject to the
#      daily budget even when the free counter is at the cap (the budget is
#      free-model-only, matching the OpenRouter docs).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-fdb.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: no live systemd units, no cooldown.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
# Isolate from live quality scoreboard / routing.
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

# A models.json with an openrouter free model and a non-free sibling, plus a
# control free lane (ollama) so pick_seat has a fallback when openrouter free
# is benched.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "openrouter": {
      "models": [
        { "id": "minimax/minimax-m3:free", "cost": { "input": 0 } },
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

# seat-caps with a tiny free_model_daily_request_budget (3) so the test does
# not need 50 session files. The openrouter paid model is cap 0 (it is walled
# in production today) so it never interferes; the free model is cap 2.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["openrouter", "ollama"],
  "providers": {
    "openrouter": {
      "cap": 2,
      "class": "free",
      "free_model_daily_request_budget": 3,
      "models": {
        "minimax/minimax-m3:free": 2,
        "deepseek/deepseek-v4-flash-0731": 0
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

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
ledger="$scratch/ledger"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"

# Helper: write a synthetic Pi session file under FLEET_SESSIONS_DIR.
# Args: relative_dir filename provider modelId assistant_turns
write_session() {
    local dir="$1" name="$2" prov="$3" model="$4" turns="${5:-0}"
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
            printf '{"type":"message","id":"a%d","parentId":"u%d","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}\n' \
                "$i" "$i" "${name%%_*}"
        done
    } >"$f"
}

today=$(date -u +%Y-%m-%d)
tomorrow=$(date -u -d "tomorrow" +%Y-%m-%d)

# --- scenario 1: below the cap, free model is pickable -------------------
echo "--- scenario 1: below cap (2 turns < budget 3) -> pickable ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-below"
write_session "pi-issue-test-1" "${today}T05-11-27-532Z_test-1.jsonl" "openrouter" "minimax/minimax-m3:free" 2
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "below-cap: expected a pick, got rc=$rc"
echo "$out" | grep -q "openrouter" && ok "below-cap: openrouter free model picked" \
    || fail "below-cap: openrouter free model NOT picked, got: $out"

# --- scenario 2: at the cap, free model is benched and skipped ----------
echo "--- scenario 2: at cap (3 turns >= budget 3) -> benched, skipped ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-atcap"
# 3 assistant turns in one openrouter :free session today -> counter = 3 = budget.
write_session "pi-issue-test-2" "${today}T06-00-00-000Z_test-2.jsonl" "openrouter" "minimax/minimax-m3:free" 3
# Clear any ledger from scenario 1.
rm -f "$ledger"/*.json
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "at-cap: expected a fallback pick (ollama), got rc=$rc"
# The free model must NOT be picked; ollama is the fallback.
echo "$out" | grep -q "openrouter" \
    && fail "at-cap: openrouter free model was picked despite daily cap, got: $out" \
    || ok "at-cap: openrouter free model skipped (daily cap reached)"
echo "$out" | grep -q "ollama" \
    && ok "at-cap: ollama fallback picked" \
    || fail "at-cap: ollama fallback NOT picked, got: $out"

# --- scenario 3: bench is NOT charged to the work item ------------------
echo "--- scenario 3: bench consecutive_failure_count == 0 (not charged) ---"
# Compute the ledger path the same way seat_ledger_path does (sanitise
# provider/model to the on-disk filename).
p3_prov="openrouter"
p3_model="minimax/minimax-m3:free"
_ps="${p3_prov//[^A-Za-z0-9._-]/_}"
_ms="${p3_model//[^A-Za-z0-9._-]/_}"
bf="$ledger/${_ps}__${_ms}.json"
[[ -f "$bf" ]] || fail "not-charged: bench ledger file not written at $bf"
hc=$(jq -r '.health_class // ""' "$bf")
bu=$(jq -r '.bench_until // ""' "$bf")
cfc=$(jq -r '.consecutive_failure_count // "MISSING"' "$bf")
src=$(jq -r '.source // ""' "$bf")
[[ "$hc" == "quota_bench" ]] || fail "not-charged: health_class=$hc, expected quota_bench"
[[ "$cfc" == "0" ]] || fail "not-charged: consecutive_failure_count=$cfc, expected 0 (account-wide external limit, not a seat fault)"
[[ "$src" == "free_daily_budget" ]] || fail "not-charged: source=$src, expected free_daily_budget"
[[ -n "$bu" ]] || fail "not-charged: bench_until is empty"
ok "not-charged: health_class=quota_bench, consecutive_failure_count=0, source=free_daily_budget, bench_until=$bu"

# --- scenario 4: bench releases after 00:00 UTC (counter restarts) ------
echo "--- scenario 4: tomorrow's sessions not counted -> counter 0, pickable ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-tomorrow"
# A session dated tomorrow with 3 turns must NOT count against today's budget.
write_session "pi-issue-test-3" "${tomorrow}T06-00-00-000Z_test-3.jsonl" "openrouter" "minimax/minimax-m3:free" 3
# Clear the bench ledger so seat_usable does not hold the seat from scenario 2.
rm -f "$ledger"/*.json
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "tomorrow: expected a pick, got rc=$rc"
echo "$out" | grep -q "openrouter" \
    && ok "tomorrow: openrouter free model picked (today's counter is 0)" \
    || fail "tomorrow: openrouter free model NOT picked, got: $out"

# --- scenario 5: non-free openrouter model is NOT subject to the budget --
echo "--- scenario 5: non-free model NOT subject to daily budget ---"
export FLEET_SESSIONS_DIR="$scratch/sessions-nonfree"
# 3 turns on the :free model today (hitting the cap). The daily budget must
# bench the :free model but NOT the non-free sibling — the budget is
# free-model-only, matching the OpenRouter docs. We give the non-free model
# cap 2 in a fresh seat-caps so it is a candidate alongside the free one.
cat >"$scratch/seat-caps-nonfree.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["openrouter"],
  "providers": {
    "openrouter": {
      "cap": 2,
      "class": "free",
      "free_model_daily_request_budget": 3,
      "models": {
        "deepseek/deepseek-v4-flash-0731": 2,
        "minimax/minimax-m3:free": 2
      }
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps-nonfree.json"
# Put the 3 turns on the :free model so the free counter hits the cap.
write_session "pi-issue-test-4" "${today}T07-00-00-000Z_test-4.jsonl" "openrouter" "minimax/minimax-m3:free" 3
rm -f "$ledger"/*.json
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "non-free: expected a pick, got rc=$rc"
# The :free model must be benched; the non-free sibling must be picked.
echo "$out" | grep -q "deepseek-v4-flash-0731" \
    && ok "non-free: openrouter paid model picked (daily budget is free-model-only)" \
    || fail "non-free: openrouter paid model NOT picked, got: $out"
echo "$out" | grep -q ":free" \
    && fail "non-free: :free model was picked despite daily cap, got: $out" \
    || ok "non-free: :free model correctly benched (daily cap reached)"

echo
echo "ALL OK: fleet-ops#3723 free-model daily request budget replay drill"
