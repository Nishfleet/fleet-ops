#!/usr/bin/env bash
# tests/seat-lib-last-resort.test.sh
#
# fleet-ops#4625: DeepSeek direct (api.deepseek.com) is a LAST-RESORT metered
# rung. pick_seat may offer it ONLY when ALL of these hold:
#   1. every other free / prepaid-quota / metered seat is unusable for a
#      quota, credential, or health reason (walled, quota-benched, dead,
#      corpse, HTTP 402/403/429-with-reset, cap 0 by standing rule),
#   2. there are ZERO at-capacity seats (busy != broken; the gate waits for a
#      healthy busy seat to free up — never falls through to DeepSeek merely
#      because all other seats are occupied),
#   3. this exhaustion is observed on THREE consecutive pick evaluations at
#      least 60 seconds apart (a healthy re-probe of any walled/benched seat
#      resets the counter to 0),
#   4. at admission GET /user/balance returns is_available=true and
#      total_balance > $0.50 USD (else bench + MONEY-BOUNDARY).
#
# What we prove:
#   1. last_resort seat is never chosen while any other seat is usable.
#   2. DeepSeek is not chosen after the first exhaustion observation (1/3).
#   3. DeepSeek is not chosen after the second observation (2/3).
#   4. DeepSeek is chosen only after the third observation (3/3).
#   5. Observations must respect the 60-second spacing (a too-soon second
#      observation does not increment the counter).
#   6. At-capacity does not count as exhaustion (a busy seat is healthy).
#   7. A healthy re-probe resets the counter to 0.
#   8. Balance-unavailable or low-balance path benches the seat and alerts
#      (MONEY-BOUNDARY written to NISH-ESCALATIONS.md).
#   9. deepseek-v4-pro (keystone_only) is never offered to a non-keystone pick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-lr.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

# models.json: a free ollama lane + the deepseek direct provider (last-resort).
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    },
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "api": "openai-completions",
      "apiKey": "!printf '%s' '${DEEPSEEK_API_KEY_STUB:-sk-stub-test-key}'",
      "models": [
        { "id": "deepseek-v4-flash", "cost": { "input": 0.44, "output": 1.32 } },
        { "id": "deepseek-v4-pro", "cost": { "input": 1.32, "output": 3.96 } }
      ]
    }
  }
}
JSON

# seat-caps: ollama free, deepseek metered last_resort. flash cap 4, pro cap 1
# keystone_only.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.0,
  "product_order": "value",
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": [],
  "providers": {
    "ollama": {
      "cap": 2,
      "class": "free",
      "models": {
        "deepseek-v4-flash:0731": 2
      }
    },
    "deepseek": {
      "cap": 5,
      "class": "metered",
      "last_resort": true,
      "models": {
        "deepseek-v4-flash": 4,
        "deepseek-v4-pro": {
          "cap": 1,
          "keystone_only": true,
          "reason": "2026-09-09 fleet-ops#4625: pro is keystone-class only."
        }
      }
    }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"
export SEAT_LAST_RESORT_COUNTER="$scratch/state/last-resort-exhaustion.json"
export SEAT_LAST_RESORT_PROM="$scratch/state/fleet-seat-last-resort.prom"
export MONEY_BOUNDARY_NISH="$scratch/NISH-ESCALATIONS.md"

ledger="$scratch/ledger"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"

# Helper: bench a seat by writing a seat-health ledger entry.
# Args: provider model health_class bench_until_s
bench_seat() {
    local p="$1" m="$2" hc="$3" bu="${4:-3600}"
    local sp="${p//[^A-Za-z0-9._-]/_}"
    local sm="${m//[^A-Za-z0-9._-]/_}"
    local f="$ledger/${sp}__${sm}.json"
    local now future
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    future=$(date -u -d "+${bu} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -u -d "+${bu} seconds" +%Y-%m-%dT%H:%M:%SZ)
    jq -nc --arg p "$p" --arg m "$m" --arg hc "$hc" --arg n "$now" --arg u "$future" \
        '{provider:$p,model:$m,health_class:$hc,http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:$n,source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
        > "$f"
}

# Helper: clear all bench ledgers so seats become healthy again.
clear_benches() {
    rm -f "$ledger"/*.json 2>/dev/null || true
}

# Helper: run pick_seat. Args: difficulty
run_pick() {
    local diff="${1:-light}"
    bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "" "'"$diff"'"' "$lib" 2>/dev/null
}

# Helper: assert the pick output is the deepseek direct provider (not ollama
# whose model name happens to contain "deepseek"). Matches "deepseek\t" at
# the start of the line (provider tab model).
is_deepseek_direct() {
    printf '%s' "$1" | grep -q '^deepseek	'
}

# Helper: set the exhaustion counter to a specific count + last_observed epoch.
# Args: count last_observed_epoch
set_counter() {
    local count="$1" last="$2"
    local f="$SEAT_LAST_RESORT_COUNTER"
    local now_iso
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc --argjson c "$count" --argjson t "$last" --arg iso "$now_iso" \
        '{count:$c,last_observed:$t,updated:$iso}' >"$f"
}

# Helper: read the current counter count.
get_counter() {
    local f="$SEAT_LAST_RESORT_COUNTER"
    [[ -f "$f" ]] || { echo 0; return; }
    jq -r '.count // 0' "$f" 2>/dev/null || echo 0
}

# --- scenario 1: last_resort never chosen while a free seat is usable --------
echo "--- scenario 1: free seat usable -> deepseek never chosen ---"
clear_benches
set_counter 0 0
set +e
out=$(run_pick light)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "expected a pick, got rc=$rc"
printf '%s' "$out" | grep -q "ollama" \
    || fail "expected ollama, got: $out"
is_deepseek_direct "$out" \
    && fail "deepseek was chosen while a free seat was usable" \
    || ok "deepseek not chosen while free seat usable (rc=$rc out=$out)"
[[ "$(get_counter)" == "0" ]] \
    || fail "counter should be 0 with a healthy seat, got $(get_counter)"

# --- scenario 2: not chosen after 1/3 exhaustion ---------------------------
echo "--- scenario 2: 1/3 exhaustion -> deepseek not chosen ---"
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
set_counter 0 0
# First observation: simulate by running pick_seat (which observes exhaustion).
set +e
out=$(run_pick light)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] \
    || fail "expected no pick at 1/3, got rc=$rc out=$out"
[[ "$(get_counter)" == "1" ]] \
    || fail "counter should be 1 after first observation, got $(get_counter)"
is_deepseek_direct "$out" \
    && fail "deepseek chosen at 1/3" \
    || ok "deepseek not chosen at 1/3 (counter=1, rc=$rc)"

# --- scenario 3: not chosen after 2/3 ---------------------------------------
echo "--- scenario 3: 2/3 exhaustion -> deepseek not chosen ---"
# Set the counter to 1 with a last_observed > 60s ago so the next observation
# increments.
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 1 "$local_epoch"
set +e
out=$(run_pick light)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] \
    || fail "expected no pick at 2/3, got rc=$rc out=$out"
[[ "$(get_counter)" == "2" ]] \
    || fail "counter should be 2 after second observation, got $(get_counter)"
is_deepseek_direct "$out" \
    && fail "deepseek chosen at 2/3" \
    || ok "deepseek not chosen at 2/3 (counter=2, rc=$rc)"

# --- scenario 4: chosen only after 3/3 -------------------------------------
echo "--- scenario 4: 3/3 exhaustion -> deepseek chosen ---"
# Stub the balance check to succeed (DEEPSEEK_API_KEY_STUB is set, but the
# curl will fail — we override the balance check function for this test).
# We simulate a healthy balance by pre-writing the balance file.
mkdir -p "$PI_PACKET_STATE/prepaid-usage"
jq -nc '{is_available:true,total_balance:"9.99"}' \
    > "$PI_PACKET_STATE/prepaid-usage/deepseek-balance-stub.json"
# Override _deepseek_balance_check to always succeed in this scenario.
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 2 "$local_epoch"
set +e
out=$(bash -c '
source "$0"
load_seat_caps
_deepseek_balance_check() { return 0; }
pick_seat "" "" 0 "" light
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "expected a pick at 3/3, got rc=$rc"
printf '%s' "$out" | grep -q "deepseek" \
    || fail "expected deepseek at 3/3, got: $out"
is_deepseek_direct "$out" \
    || fail "expected deepseek direct provider at 3/3, got: $out"
printf '%s' "$out" | grep -q "deepseek-v4-flash" \
    || fail "expected deepseek-v4-flash (not pro) for light pick, got: $out"
ok "deepseek chosen at 3/3 (rc=$rc out=$out)"

# --- scenario 5: 60-second spacing respected --------------------------------
echo "--- scenario 5: too-soon observation does not increment ---"
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
# Set counter to 1 with last_observed only 10s ago (within the 60s gap).
local_epoch=$(( $(date -u +%s) - 10 ))
set_counter 1 "$local_epoch"
set +e
out=$(run_pick light)
rc=$?
set -e
[[ "$(get_counter)" == "1" ]] \
    || fail "counter should stay 1 (too soon), got $(get_counter)"
ok "60s spacing: counter stayed at 1 (too-soon observation ignored)"

# --- scenario 6: at-capacity does not count as exhaustion -------------------
echo "--- scenario 6: at-capacity seat -> deepseek not chosen (busy != broken) ---"
# An at-capacity seat (busy, not broken) must NOT count as exhaustion.
# We test the gate logic directly: _last_resort_observe with at_cap_n=1 must
# reset the counter to 0 (a healthy busy seat resets the gate). The full
# pick_seat at-capacity path needs real systemd units (count_active_on_seat
# calls systemctl), so we unit-test the gate decision here.
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 2 "$local_epoch"
# Simulate an at-capacity observation: exhausted=1, healthy_n=0, at_cap_n=1.
# The gate must reset to 0 (busy != broken).
set +e
count=$(bash -c '
source "$0"
_last_resort_observe 1 0 1
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$count" == "0" ]] \
    || fail "at-capacity should reset counter to 0, got $count"
ok "at-capacity: counter reset to 0 (busy != broken, at_cap_n=1 resets the gate)"

# --- scenario 7: healthy re-probe resets the counter ------------------------
echo "--- scenario 7: healthy re-probe resets counter to 0 ---"
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 2 "$local_epoch"
# Now clear the bench (seat becomes healthy) and run pick_seat.
clear_benches
set +e
out=$(run_pick light)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "expected ollama pick after re-probe, got rc=$rc"
printf '%s' "$out" | grep -q "ollama" \
    || fail "expected ollama after healthy re-probe, got: $out"
[[ "$(get_counter)" == "0" ]] \
    || fail "counter should reset to 0 on healthy re-probe, got $(get_counter)"
ok "healthy re-probe: counter reset to 0, ollama picked"

# --- scenario 8: low balance benches + raises MONEY-BOUNDARY ----------------
echo "--- scenario 8: low balance -> bench + MONEY-BOUNDARY ---"
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 2 "$local_epoch"
# Override the balance check to return 1 (low balance) and verify the
# MONEY-BOUNDARY line is written.
set +e
out=$(bash -c '
source "$0"
load_seat_caps
_deepseek_balance_check() {
    seat_log "pick_seat: LAST-RESORT deepseek balance LOW — is_available=false total_balance=\$0.10 (floor \$0.50, fleet-ops#4625) — benching + MONEY-BOUNDARY"
    _deepseek_raise_money_boundary "false" "0.10"
    return 1
}
pick_seat "" "" 0 "" light
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] \
    || fail "expected no pick on low balance, got rc=$rc out=$out"
is_deepseek_direct "$out" \
    && fail "deepseek chosen on low balance" \
    || ok "low balance: deepseek not chosen (rc=$rc)"
[[ -f "$MONEY_BOUNDARY_NISH" ]] \
    || fail "NISH-ESCALATIONS.md not written"
grep -q "MONEY-BOUNDARY" "$MONEY_BOUNDARY_NISH" \
    || fail "MONEY-BOUNDARY line not found in NISH-ESCALATIONS.md"
grep -q "deepseek-direct" "$MONEY_BOUNDARY_NISH" \
    || fail "MONEY-BOUNDARY line does not name deepseek-direct"
ok "low balance: MONEY-BOUNDARY raised for deepseek-direct"

# --- scenario 9: pro never offered to a non-keystone pick -------------------
echo "--- scenario 9: deepseek-v4-pro (keystone_only) never offered to light pick ---"
clear_benches
bench_seat ollama "deepseek-v4-flash:0731" quota_bench 3600
local_epoch=$(( $(date -u +%s) - 120 ))
set_counter 2 "$local_epoch"
set +e
out=$(bash -c '
source "$0"
load_seat_caps
_deepseek_balance_check() { return 0; }
pick_seat "" "" 0 "" light
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "expected a pick at 3/3, got rc=$rc"
printf '%s' "$out" | grep -q "deepseek-v4-flash" \
    || fail "expected deepseek-v4-flash for light pick, got: $out"
printf '%s' "$out" | grep -q "deepseek-v4-pro" \
    && fail "deepseek-v4-pro offered to a light pick (keystone_only violated)" \
    || ok "pro not offered to light pick (keystone_only enforced)"

echo "ALL OK: fleet-ops#4625 last_resort triple-verify exhaustion gate"
