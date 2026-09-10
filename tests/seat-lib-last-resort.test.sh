#!/usr/bin/env bash
# tests/seat-lib-last-resort.test.sh
#
# fleet-ops#4625: the DeepSeek direct API seat is a LAST-RESORT metered seat.
# pick_seat may admit it ONLY when ALL of these hold:
#   1. every other seat (free/prepaid/metered/product_only) is unusable this
#      pick — a last_resort seat is never chosen while any other usable seat
#      exists,
#   2. the exhaustion was independently verified 3 times >=60s apart (the
#      triple-verify gate) — a single observation or two is NOT enough,
#   3. no seat is merely at capacity (capacity is not exhaustion — wait for
#      capacity rather than burning metered dollars),
#   4. a healthy re-probe on any walled/benched seat resets the counter to 0
#      and the healthy seat is used instead,
#   5. the DeepSeek balance (GET /user/balance) is available and > $0.50 — a
#      depleted/invalid balance benches the seat and raises a Nish
#      money-boundary notification (never silently degrade).
#
# What we prove (replay drill against synthetic fixtures, no real API key):
#   1. last_resort seat is never chosen while a free seat is usable.
#   2. It is not chosen at 1/3 observations.
#   3. It is not chosen at 2/3 observations.
#   4. It is chosen at 3/3 observations (with a stubbed-OK balance).
#   5. At-capacity is not treated as exhausted (last_resort refused).
#   6. Healthy re-probe resets the counter to 0.
#   7. Balance bench: a depleted balance (<= $0.50) benches the seat and the
#      admission is refused.
#   8. The loud admission log line matches the required format.

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

# Offline: no live systemd units, no no-usable-seat cooldown.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0

export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

# A free ollama lane + the last_resort deepseek direct seat.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    },
    "deepseek": {
      "models": [
        { "id": "deepseek-v4-flash", "cost": { "input": 0.44 } },
        { "id": "deepseek-v4-pro", "cost": { "input": 1.32 } }
      ]
    }
  }
}
JSON

# seat-caps: ollama free, deepseek metered + last_resort:true.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": {
      "cap": 2,
      "class": "free",
      "models": {
        "deepseek-v4-flash:0731": 2
      }
    },
    "deepseek": {
      "cap": 4,
      "class": "metered",
      "last_resort": true,
      "models": {
        "deepseek-v4-flash": 4,
        "deepseek-v4-pro": 1
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

# Stub the balance check: write a fake balance file and short-circuit the
# curl call. We override DEEPSEEK_CURL_BIN to a stub that emits a JSON balance,
# and DEEPSEEK_KEY_FILE to a temp file so no real key is read.
echo 'DEEPSEEK_API_KEY=test-stub-key-not-real' >"$scratch/deepseek.env"
export DEEPSEEK_KEY_FILE="$scratch/deepseek.env"
export DEEPSEEK_API_BASE="https://stub.invalid"

# balance_ok: 1 = available + > 0.50, 0 = depleted/unavailable
balance_ok=1
make_curl_stub() {
    cat >"$scratch/curl-stub" <<'EOF'
#!/usr/bin/env bash
# stub: emit a DeepSeek /user/balance response
EOF
    if (( balance_ok == 1 )); then
        cat >>"$scratch/curl-stub" <<'EOF'
printf '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"9.71","granted_balance":"0.00","topped_up_balance":"9.71"}]}'
EOF
    else
        cat >>"$scratch/curl-stub" <<'EOF'
printf '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0.30","granted_balance":"0.00","topped_up_balance":"0.30"}]}'
EOF
    fi
    chmod +x "$scratch/curl-stub"
}
export DEEPSEEK_CURL_BIN="$scratch/curl-stub"
make_curl_stub

# Bench a seat by writing a far-future quota_bench ledger entry.
# Args: provider model
bench_seat() {
    local p="$1" m="$2"
    local ps="${p//[^A-Za-z0-9._-]/_}" ms="${m//[^A-Za-z0-9._-]/_}"
    # Use +365d, not 2999: _wall_capped_at_horizon caps a bench to the
    # provider's reset horizon, so a 2999 date gets clipped to "now" and
    # seat_usable fails open. A year out survives the cap and stays benched.
    local u
    u=$(date -u -d '+365 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2999-01-01T00:00:00Z")
    jq -nc --arg u "$u" \
      '{provider:"'"$p"'",model:"'"$m"'",health_class:"quota_bench",http_status:429,retryable:true,seat_dead:false,poison_ladder:false,observed_at:"2026-09-10T00:00:00Z",source:"test",failure_mode:"quota_cap",bench_until:$u,usable_at:$u,consecutive_failure_count:0}' \
      > "$ledger/${ps}__${ms}.json"
}

# pick helper: runs pick_seat in a clean bash with the given env.
run_pick() {
    bash -c 'source "$0"; load_seat_caps; PI_PICK_ROLE="scout" pick_seat "" "" 0 "" light' "$lib" 2>/dev/null
}

# Counter state file lives under PI_PACKET_STATE.
state_f="$PI_PACKET_STATE/last-resort-exhaust.json"

# --- scenario 1: last_resort never chosen while free seat is usable ---------
echo "--- scenario 1: usable free seat -> last_resort refused ---"
rm -f "$ledger"/*.json "$state_f"
set +e
out=$(run_pick)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "usable-free: expected a pick, got rc=$rc"
printf '%s' "$out" | grep -q "ollama" \
    && ok "usable-free: free lane picked, last_resort not offered" \
    || fail "usable-free: free lane NOT picked, got: $out"
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && fail "usable-free: last_resort deepseek offered while free seat usable, got: $out" \
    || true

# --- scenario 2: not chosen at 1/3 observations -----------------------------
echo "--- scenario 2: 1/3 exhaustion observations -> last_resort refused ---"
rm -f "$ledger"/*.json "$state_f"
bench_seat ollama "deepseek-v4-flash:0731"
set +e
out=$(run_pick)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] || fail "1/3: expected no pick, got rc=$rc out=$out"
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && fail "1/3: last_resort admitted after only 1 observation, got: $out" \
    || ok "1/3: last_resort refused (need 3 observations)"
count=$(jq -r '.count // 0' "$state_f" 2>/dev/null || echo 0)
[[ "$count" == "1" ]] || fail "1/3: counter is $count, expected 1"

# --- scenario 3: not chosen at 2/3 observations ----------------------------
echo "--- scenario 3: 2/3 exhaustion observations -> last_resort refused ---"
# Backdate the last observation so the >=60s gap is satisfied.
ts_past=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --argjson c 1 --arg ts "$ts_past" --argjson admitted false \
    '{count:$c,last_ts:$ts,admitted:$admitted}' >"$state_f"
set +e
out=$(run_pick)
rc=$?
set -e
[[ "$rc" != "0" || -z "$out" ]] || fail "2/3: expected no pick, got rc=$rc out=$out"
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && fail "2/3: last_resort admitted after only 2 observations, got: $out" \
    || ok "2/3: last_resort refused (need 3 observations)"
count=$(jq -r '.count // 0' "$state_f" 2>/dev/null || echo 0)
[[ "$count" == "2" ]] || fail "2/3: counter is $count, expected 2"

# --- scenario 4: chosen at 3/3 observations (balance OK) -------------------
echo "--- scenario 4: 3/3 exhaustion observations + balance OK -> last_resort admitted ---"
ts_past=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --argjson c 2 --arg ts "$ts_past" --argjson admitted false \
    '{count:$c,last_ts:$ts,admitted:$admitted}' >"$state_f"
set +e
out=$(run_pick)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "3/3: expected a pick, got rc=$rc"
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && ok "3/3: last_resort deepseek admitted after 3/3 exhaustion verifications" \
    || fail "3/3: last_resort NOT admitted, got: $out"
# Balance meter file written.
bf="$PI_PACKET_STATE/prepaid-usage/deepseek.json"
[[ -f "$bf" ]] || fail "3/3: balance meter file not written at $bf"
bal=$(jq -r '.balance_usd // ""' "$bf" 2>/dev/null || true)
[[ "$bal" == "9.71" ]] || fail "3/3: balance_usd=$bal, expected 9.71"
ok "3/3: balance meter recorded USD 9.71 to prepaid-usage/deepseek.json"

# --- scenario 5: at-capacity is not exhaustion -----------------------------
echo "--- scenario 5: seat at capacity -> last_resort refused (capacity is not exhaustion) ---"
rm -f "$ledger"/*.json "$state_f"
# Simulate the free seat being at capacity by spawning 2 active workers on it
# (cap 2). We register 2 active seats so the cap check skips it as at-capacity.
active_dir="$PI_PACKET_STATE/active-seats"
mkdir -p "$active_dir"
jq -nc '{provider:"ollama",model:"deepseek-v4-flash:0731",unit:"u1",started_at:"2026-09-10T00:00:00Z"}' >"$active_dir/u1.json"
jq -nc '{provider:"ollama",model:"deepseek-v4-flash:0731",unit:"u2",started_at:"2026-09-10T00:00:00Z"}' >"$active_dir/u2.json"
set +e
out=$(run_pick)
rc=$?
set -e
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && fail "at-capacity: last_resort admitted while a seat is merely at capacity, got: $out" \
    || ok "at-capacity: last_resort refused (capacity is not exhaustion)"
rm -f "$active_dir"/*.json

# --- scenario 6: counter resets when a non-last_resort seat recovers --------
echo "--- scenario 6: counter resets when a non-last_resort seat recovers ---"
rm -f "$ledger"/*.json "$state_f"
bench_seat ollama "deepseek-v4-flash:0731"
# Run once to bump the counter to 1.
set +e; out=$(run_pick); rc=$?; set -e
count=$(jq -r '.count // 0' "$state_f" 2>/dev/null || echo 0)
[[ "$count" == "1" ]] || fail "re-probe setup: counter is $count, expected 1"
# picks the healthy ollama seat and resets the counter to 0 (a stale counter
# must not short-circuit the gate the next time all seats are unusable).
rm -f "$ledger"/*.json
set +e
out=$(run_pick)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "re-probe: expected the healthy seat, got rc=$rc"
printf '%s' "$out" | grep -q "ollama" \
    && ok "re-probe: healthy free seat picked, counter reset" \
    || fail "re-probe: healthy seat NOT picked, got: $out"
count=$(jq -r '.count // 0' "$state_f" 2>/dev/null || echo 0)
[[ "$count" == "0" ]] || fail "re-probe: counter is $count, expected 0 after reset"

# --- scenario 7: balance bench (depleted <= $0.50) -------------------------
echo "--- scenario 7: depleted balance (<= \$0.50) -> seat benched, admission refused ---"
rm -f "$ledger"/*.json "$state_f"
bench_seat ollama "deepseek-v4-flash:0731"
# Set counter to 2 (one observation away from admission) and backdate.
ts_past=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --argjson c 2 --arg ts "$ts_past" --argjson admitted false \
    '{count:$c,last_ts:$ts,admitted:$admitted}' >"$state_f"
# Flip the balance stub to depleted.
balance_ok=0
make_curl_stub
set +e
out=$(run_pick)
rc=$?
set -e
printf '%s' "$out" | grep -qP "^deepseek\t" \
    && fail "balance-bench: last_resort admitted despite depleted balance, got: $out" \
    || ok "balance-bench: last_resort refused (balance <= \$0.50)"
# Bench ledger written for the deepseek seat.
ds_bench="$ledger/deepseek__deepseek-v4-flash.json"
[[ -f "$ds_bench" ]] || fail "balance-bench: bench ledger not written at $ds_bench"
src=$(jq -r '.source // ""' "$ds_bench")
hc=$(jq -r '.health_class // ""' "$ds_bench")
[[ "$src" == "money_boundary" ]] || fail "balance-bench: source=$src, expected money_boundary"
[[ "$hc" == "quota_bench" ]] || fail "balance-bench: health_class=$hc, expected quota_bench"
ok "balance-bench: quota_bench/money_boundary ledger written for deepseek"
# Balance meter file records the depleted balance.
bf="$PI_PACKET_STATE/prepaid-usage/deepseek.json"
[[ -f "$bf" ]] || fail "balance-bench: meter file not written"
bal=$(jq -r '.balance_usd // ""' "$bf" 2>/dev/null || true)
[[ "$bal" == "0.30" ]] || fail "balance-bench: balance_usd=$bal, expected 0.30"
ok "balance-bench: depleted balance USD 0.30 recorded to meter"

# --- scenario 8: loud admission log line format -----------------------------
echo "--- scenario 8: admission log line matches required format ---"
rm -f "$ledger"/*.json "$state_f"
bench_seat ollama "deepseek-v4-flash:0731"
balance_ok=1
make_curl_stub
# Prime the counter to 2, backdated, then run to admit.
ts_past=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --argjson c 2 --arg ts "$ts_past" --argjson admitted false \
    '{count:$c,last_ts:$ts,admitted:$admitted}' >"$state_f"
log_out=$(bash -c 'source "$0"; load_seat_caps; PI_PICK_ROLE="scout" pick_seat "" "" 0 "" light' "$lib" 2>&1 1>/dev/null || true)
printf '%s' "$log_out" | grep -qE 'pick_seat: LAST-RESORT deepseek admitted after 3/3 exhaustion verifications \([0-9]+ other seats unusable\)' \
    && ok "admission-log: loud line matches required format" \
    || fail "admission-log: log line does not match. Got: $log_out"

echo
echo "ALL OK: fleet-ops#4625 last_resort triple-verify gate + balance meter"
