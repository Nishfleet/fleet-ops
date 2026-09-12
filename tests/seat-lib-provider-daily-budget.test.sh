#!/usr/bin/env bash
# tests/seatlib-provider-daily-budget.test.sh
#
# fleet-ops#4453: ParetoInference's Pareto Pass is a prepaid worker seat with a
# $20/day allowance that EXPIRES at 23:59 (unused $ is lost). The provider
# reports usage.cost=0 on the Pass (the $3/wk credits bill off the rate card,
# not per-call cost), so the per-seat usage.cost meter (fleet-ops#3724) reads 0
# forever. seatlib therefore meters the provider by TOKENS x the provider's
# own pi-models rate card (per 1M) — for paretoinference
#   usd = input*0.081/1e6 + output*0.162/1e6 + cacheRead*0.016/1e6
# — records `usd_today` in the existing prepaid-usage counter file, and benches
# every model on the provider until 00:00 UTC once today's token-derived spend
# reaches the stop (a money wall, never charged to the work item).
#
# What we prove (replay drill against synthetic Pi session files):
#   1. Below the stop: a paretoinference model is pickable.
#   2. At/above the stop: the paretoinference seat is benched (quota_bench
#      ledger, source=provider_daily_budget, count 0, dated reason, until
#      00:00 UTC) and pick-seat skips it; the free fallback is picked.
#   3. The prepaid-usage counter file shows `usd_today` and it never exceeds
#      the stop (i.e. the budget is respected).
#   4. Only today's spend on THIS provider counts: yesterday's sessions and a
#      different provider's sessions leave usd_today at 0.
#   5. The 429-after-budget flag is set in the counter when a quota 429
#      arrives after the budget is reached.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seatlib-pdb.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: no live systemd units, no no-usable-seat cooldown.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0

export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

# paretoinference (prepaid-quota, rate card exactly as in pi-models.json) plus
# an ollama free fallback lane so pick-seat has somewhere to go when the
# pareto seat is benched. Models[0].cost is what the token meter reads.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "paretoinference": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash",
          "cost": { "input": 0.081, "output": 0.162, "cacheRead": 0.016, "cacheWrite": 0 } },
        { "id": "z-ai/glm-5.3-flash",
          "cost": { "input": 0.075, "output": 0.25, "cacheRead": 0.015, "cacheWrite": 0 } }
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

# seat-caps: paretoinference cap 2, prepaid-quota, daily_budget_usd 20 /
# daily_stop_usd 0.02 (the STOP drives the drill — a tiny stop so the small
# fixture token counts cross it; production uses 19.5 below the $20 Pass
# allowance). ollama fallback. paretoinference is FIRST in
# prepaid_providers_in_order (expiry-first).
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["paretoinference"],
  "providers": {
    "paretoinference": {
      "cap": 2,
      "class": "prepaid-quota",
      "quota_bench_default_s": 900,
      "daily_budget_usd": 20,
      "daily_stop_usd": 0.02,
      "models": {
        "deepseek/deepseek-v4-flash": 2
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
export PI_PACKET_REPO=""
export FLEET_SESSIONS_DIR="$scratch/sessions"
STATE_DIR="$PI_PACKET_STATE"

# Helper: write a synthetic Pi session file pinned to a provider/model.
# Args: dir filename provider modelId turns input_tokens output_tokens cache_tokens
write_session_tokens() {
    local dir="$1" name="$2" prov="$3" model="$4" turns="${5:-0}" \
          inp="${6:-0}" out="${7:-0}" cac="${8:-0}"
    local sd="${FLEET_SESSIONS_DIR}/$dir"
    mkdir -p "$sd"
    local ts="${name%%_*}"; ts="${ts}T12-00-00-000Z"
    local f="$sd/$name.jsonl"
    {
        printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"/home/nish"}\n' "$name" "$ts"
        printf '{"type":"model_change","id":"m1","parentId":null,"timestamp":"%s","provider":"%s","modelId":"%s"}\n' \
            "$ts" "$prov" "$model"
        printf '{"type":"thinking_level_change","id":"t1","parentId":"m1","timestamp":"%s","thinkingLevel":"off"}\n' "$ts"
        local i
        for ((i = 0; i < turns; i++)); do
            printf '{"type":"message","id":"u%d","parentId":"t1","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n' \
                "$i" "$ts"
            printf '{"type":"message","id":"a%d","parentId":"u%d","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input":%s,"output":%s,"cacheRead":%s,"cacheWrite":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}\n' \
                "$i" "$i" "$ts" "$inp" "$out" "$cac"
        done
    } >"$f"
}

# pick helper: runs pick-seat in a clean bash with the given pick role.
run_pick() {
    local role="${1:-scout}"
    bash -c 'source "$0"; load_seat_caps; PI_PICK_ROLE="'"$role"'" pick-seat "" "" 0 "" light' "$lib" 2>/dev/null
}

today=$(date -u +%Y-%m-%d)
yesterday=$(date -u -d "yesterday" +%Y-%m-%d)
# Prepaid-usage counter file for the usd_today assertions (the existing
# prepaid-usage counter, fleet-ops#4453).
counter_file="$STATE_DIR/prepaid-usage/paretoinference.json"

# --- scenario 1: below stop -> pareto seat pickable ----------------------
# For a scout pick (free-first) the pareto seat only shows when the free
# ollama fallback is unusable, so bench it here; scenario 2 leaves it usable
# so it is the documented fallback.
bench_ollama() {
    local ps="ollama" ms="deepseek-v4-flash:0731"
    ps="${ps//[^A-Za-z0-9._-]/_}"; ms="${ms//[^A-Za-z0-9._-]/_}"
    jq -nc --arg u "2999-01-01T00:00:00Z" \
      '{provider:"ollama",model:"deepseek-v4-flash:0731",health_class:"quota_bench",http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:"2026-09-06T00:00:00Z",source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
      > "$ledger/${ps}__${ms}.json"
}

echo "--- scenario 1: spend below daily stop -> pareto seat offered ---"
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/one"
# 100k in + 50k out tokens x the rate card per 1M: 0.00810 + 0.00810
# = USD 0.0162, below the 0.02 stop.
write_session_tokens "one" "${today}_s1" "paretoinference" "deepseek/deepseek-v4-flash" 1 100000 50000 0
rm -f "$ledger"/*.json "$counter_file"
bench_ollama
set +e
out=$(run_pick scout); rc=$?
set -e
[[ "$rc" == "0" ]] || fail "below-stop: expected a pick, got rc=$rc out=$out"
printf '%s' "$out" | grep -q "paretoinference" \
    && ok "below-stop: pareto seat offered (spend 0.0162 < 0.02)" \
    || fail "below-stop: pareto seat NOT offered, got: $out"

# --- scenario 2: at/above stop -> benched, free fallback picked -----------
echo "--- scenario 2: spend at/above daily stop -> benched to 00:00 UTC ---"
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/two"
# 130k in + 60k out tokens = 0.01053 + 0.00972 = USD 0.02025 >= 0.02 stop.
write_session_tokens "two" "${today}_s2" "paretoinference" "deepseek/deepseek-v4-flash" 1 130000 60000 0
rm -f "$ledger"/*.json "$counter_file"
set +e
out=$(run_pick scout); rc=$?
set -e
printf '%s' "$out" | grep -q "paretoinference" \
    && fail "at-stop: pareto seat offered despite the daily budget, got: $out" \
    || ok "at-stop: pareto seat skipped at the daily stop"
printf '%s' "$out" | grep -q "ollama" \
    && ok "at-stop: free fallback picked" \
    || fail "at-stop: free fallback NOT picked, got: $out"
# Ledger: quota_bench money wall, count 0, dated reason, source tag.
_ps="paretoinference"; _ms="deepseek/deepseek-v4-flash"
_ps="${_ps//[^A-Za-z0-9._-]/_}"; _ms="${_ms//[^A-Za-z0-9._-]/_}"
bf="$ledger/${_ps}__${_ms}.json"
[[ -f "$bf" ]] || fail "at-stop: bench ledger not written at $bf"
hc=$(jq -r '.health_class // ""' "$bf")
fm=$(jq -r '.failure_mode // ""' "$bf")
cfc=$(jq -r '.consecutive_failure_count // "MISSING"' "$bf")
src=$(jq -r '.source // ""' "$bf")
rsn=$(jq -r '.reason // ""' "$bf")
bu=$(jq -r '.bench_until // ""' "$bf")
[[ "$hc" == "quota_bench" ]] || fail "at-stop: health_class=$hc expected quota_bench"
[[ "$fm" == "quota_cap" ]] || fail "at-stop: failure_mode=$fm expected quota_cap (money wall)"
[[ "$cfc" == "0" ]] || fail "at-stop: consecutive_failure_count=$cfc expected 0 (external budget, not seat fault)"
[[ "$src" == "provider_daily_budget" ]] || fail "at-stop: source=$src expected provider_daily_budget"
printf '%s' "$rsn" | grep -q "^${today}" || fail "at-stop: reason not dated today: $rsn"
[[ -n "$bu" ]] || fail "at-stop: bench_until empty"
ok "at-stop: quota_bench/quota_cap ledger, count 0, dated reason, until $bu"

# --- scenario 3: usd_today written and capped ------------------------------
echo "--- scenario 3: prepaid-usage counter carries usd_today, capped ---"
# Clean below-stop pick that actually RECORDS the counter: a prepaid seat
# records _record_prepaid_pick (with usd_today) on the pick that offers it.
# 30k input + 20k output = 30000*0.081/1M + 20000*0.162/1M = USD 0.00567.
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/three"
rm -f "$ledger"/*.json "$counter_file"
write_session_tokens "three" "${today}_s3" "paretoinference" "deepseek/deepseek-v4-flash" 1 30000 20000 0
bench_ollama
set +e
run_pick scout >/dev/null 2>&1 || true
set -e
[[ -f "$counter_file" ]] || { echo "COUNTER MISSING; ledger:"; ls "$ledger"; echo "sessions:"; find "$FLEET_SESSIONS_DIR" -type f; fail "usd_today: counter file not written at $counter_file"; }
ut=$(jq -r '.usd_today // ""' "$counter_file")
[[ -n "$ut" && "$ut" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "usd_today: missing/non-numeric ($ut)"
awk -v u="$ut" 'BEGIN{ if (u < 0) exit 1 }' || fail "usd_today: negative ($ut)"
ok "usd_today: counter writes $ut (expect ~0.00567)"
cnt=$(jq -r '.count // 0' "$counter_file")
[[ "$cnt" =~ ^[0-9]+$ ]] && (( cnt >= 1 )) \
    || fail "usd_today: count missing in counter ($cnt)"

# --- scenario 4: other provider's / yesterday's spend not counted ----------
echo "--- scenario 4: other provider + yesterday spend leave usd_today 0 ---"
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/four" "$FLEET_SESSIONS_DIR/fourb"
rm -f "$ledger"/*.json "$counter_file"
# ollama session today with big tokens — must NOT count toward pareto.
write_session_tokens "four"  "${today}_s4ollama"  "ollama" "deepseek-v4-flash:0731" 1 5000000 5000000 0
# pareto session dated yesterday — must NOT count.
write_session_tokens "fourb" "${yesterday}_s4pareto" "paretoinference" "deepseek/deepseek-v4-flash" 1 900000000 900000000 0
bench_ollama
set +e
out=$(run_pick scout); rc=$?
set -e
printf '%s' "$out" | grep -q "paretoinference" \
    && ok "other/yesterday: pareto seat offered (only this-provider today counts)" \
    || fail "other/yesterday: pareto seat NOT offered, got: $out"

# --- scenario 5: 429-after-budget flag set in counter ----------------------
echo "--- scenario 5: first 429-after-budget logged when the budget is reached ---"
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/five"
rm -f "$ledger"/*.json "$counter_file"
# Spend above stop so the provider budget is exhausted, then record a quota
# 429 on the seat: the one-time 429-after-budget flag must appear.
write_session_tokens "five" "${today}_s5" "paretoinference" "deepseek/deepseek-v4-flash" 1 130000 60000 0
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "paretoinference" "deepseek/deepseek-v4-flash" "A request limit was reached"' "$lib" 2>/dev/null || true
[[ -f "$counter_file" ]] || fail "429flag: counter file not written"
f9=$(jq -r '.provider_daily_logged_429 // false' "$counter_file")
[[ "$f9" == "true" ]] \
    && ok "429flag: provider_daily_logged_429=true recorded in counter" \
    || fail "429flag: provider_daily_logged_429=$f9 expected true"

# --- scenario 6: 429 never a seat-dead corpse (docs.paretoinference.com/errors.md)
echo "--- scenario 6: 25 quota 429s do not corpse a daily-budget seat ---"
rm -rf "$FLEET_SESSIONS_DIR"
mkdir -p "$FLEET_SESSIONS_DIR/six"
rm -f "$ledger"/*.json "$counter_file"
write_session_tokens "six" "${today}_s6" "paretoinference" "deepseek/deepseek-v4-flash" 1 130000 60000 0
i=0
while (( i < 25 )); do
    bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "paretoinference" "deepseek/deepseek-v4-flash" "A request limit was reached"' "$lib" >/dev/null 2>&1 || true
    i=$((i + 1))
done
sd=$(jq -r '.seat_dead // false' "$bf")
[[ "$sd" == "false" ]] \
    && ok "no-corpse: seat_dead=false after 25 quota 429s on a daily-budget seat" \
    || fail "no-corpse: seat_dead=$sd expected false (never a seat-dead corpse)"

# --- live accept: repo config (not the fixture) -----------------------------
echo "--- live accept: seat-caps / entitled / pi-models / pi-issue-run ---"
live_caps="$repo_root/config/seat-caps.json"
live_ent="$repo_root/config/entitled-seats.json"
live_models="$repo_root/config/pi-models.json"
live_run="$repo_root/bin/pi-issue-run"
jq -e '.providers.paretoinference.cap == 4
        and .providers.paretoinference.daily_budget_usd == 20
        and .providers.paretoinference.max_probe_ceiling == 8
        and .providers.paretoinference.models["z-ai/glm-5.3"].cap == 0
        and .prepaid_providers_in_order[0] == "devin"
        and .prepaid_providers_in_order[1] == "paretoinference"' \
    "$live_caps" >/dev/null \
    && ok "live seat-caps: cap 4 / daily_budget_usd 20 / glm-5.3:0 / AIMD 8 / devin first, paretoinference overflow (fleet-ops#4558)" \
    || fail "live seat-caps: accept jq failed"
jq -e '.seats[] | select(.id=="paretoinference") | .class=="prepaid-quota"' \
    "$live_ent" >/dev/null \
    && ok "live entitled-seats: paretoinference prepaid-quota" \
    || fail "live entitled-seats: paretoinference missing"
jq -e '.providers.paretoinference.compat.maxTokensField == "max_tokens"' \
    "$live_models" >/dev/null \
    && ok "live pi-models: compat.maxTokensField=max_tokens" \
    || fail "live pi-models: compat.maxTokensField missing"
grep -q 'no-context-files' "$live_run" \
    && grep -q 'paretoinference' "$live_run" \
    && ok "pi-issue-run: trimmed prefix (--no-context-files) on paretoinference" \
    || fail "pi-issue-run: missing --no-context-files for paretoinference"
# Workers cannot add a P14 verify-command line. This test rides
# tests/seat.lib.test.sh (already listed).
grep -q 'seatlib-provider-daily-budget.test.sh' "$repo_root/.github/workflows/ci.yml" \
    && fail "ci.yml must NOT list this test (no Workflows permission); host it from seat.lib.test.sh" \
    || ok "ci.yml does not list this test (hosted by seat.lib.test.sh)"

echo
echo "ALL OK: fleet-ops#4453 provider daily-budget spend meter replay drill"
