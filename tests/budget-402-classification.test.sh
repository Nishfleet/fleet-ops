#!/usr/bin/env bash
# tests/budget-402-classification.test.sh
#
# fleet-ops#6652: LiteLLM's worker-cheap group routes to nebius which returns
# HTTP 402 "Payment Required: You have exhausted your budget. Please add
# funds" wrapped in a litellm 429. Without classification, the death is
# booked error_class=unknown -> 300s spawn bench, and the dead group is
# re-offered every 5 min. This test pins:
#
#   1. is_quota_cap_error matches the 402 "Payment Required" / "exhausted
#      your budget" / "add funds" literals.
#   2. classify_death_error classifies the 402 budget literal as quota_cap,
#      not unknown.
#   3. mark_seat_quota_bench writes a real ledger entry (health_class=
#      quota_bench, usable_at in the future) and a clobber-proof spawn-bench
#      marker — the proxy does NOT own this cooldown.
#   4. seat_usable returns 1 (unusable) for a seat with a quota_bench ledger
#      entry, so the pick path falls back to the direct prepaid lane.
#
# Runs entirely offline: stubbed seat-caps.json, ledger dir, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t budget-402.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

lib="$repo_root/lib/litellm-seat.sh"
[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"

# Minimal seat-caps.json so seatlib loads.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["devin"],
  "providers": {
    "litellm": {
      "cap": 4, "class": "proxy",
      "quota_bench_default_s": 3600,
      "models": {"worker-cheap": 4, "worker-capable": 4, "senior": 2}
    },
    "devin": {
      "cap": 4, "class": "subscription",
      "quota_bench_default_s": 900,
      "models": {"glm-5-2": 4, "swe-2-max": 4}
    }
  },
  "error_classes": {
    "quota_bench": {
      "matcher": "is_quota_cap_error",
      "writer": "mark_seat_quota_bench",
      "default_window_s_seconds": "quota_bench_default_s",
      "trigger_order": 2,
      "description": "Hard cap / quota wall."
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "litellm": {
      "models": [
        { "id": "worker-cheap", "cost": { "input": 0 }, "contextWindow": 200000 },
        { "id": "worker-capable", "cost": { "input": 0 }, "contextWindow": 200000 },
        { "id": "senior", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "swe-2-max", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

# Offline: no live systemd units in cap accounting.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"

LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR" "$PI_PACKET_STATE"

# ============================================================================
# 1. is_quota_cap_error matches the 402 budget literals
# ============================================================================

# 1a. "Payment Required" literal.
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" 'Error: 402 Payment Required: You have exhausted your budget. Please add funds' "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota_cap_error must match 'Payment Required: exhausted your budget' (rc=$rc)"
ok "is_quota_cap_error: matches 'Payment Required: exhausted your budget'"

# 1b. "exhausted your budget" alone.
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" "" 'You have exhausted your budget' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota_cap_error must match 'exhausted your budget' (rc=$rc)"
ok "is_quota_cap_error: matches 'exhausted your budget'"

# 1c. "add funds" alone.
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" "" 'Please add funds to continue' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota_cap_error must match 'add funds' (rc=$rc)"
ok "is_quota_cap_error: matches 'add funds'"

# 1d. 402 wrapped in a litellm 429 body (the live fleet-ops#6652 shape).
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" 'litellm 429: {"detail":"Payment Required: You have exhausted your budget. Please add funds"}' "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota_cap_error must match 402-in-429 body (rc=$rc)"
ok "is_quota_cap_error: matches 402 wrapped in litellm 429"

# 1e. Does NOT match a generic 429 rate limit (not a budget wall).
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" "429 Too Many Requests" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_quota_cap_error must NOT match a bare 429 rate limit (rc=$rc)"
ok "is_quota_cap_error: does not match bare 429 rate limit"

# 1f. Does NOT match empty input.
set +e
bash -c 'source "$0"; load_seat_caps; is_quota_cap_error "$1" "$2"' \
    "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_quota_cap_error must NOT match empty input (rc=$rc)"
ok "is_quota_cap_error: does not match empty input"

# ============================================================================
# 2. classify_death_error classifies the 402 budget literal as quota_cap
# ============================================================================
out_file="$scratch/death-out.txt"
err_file="$scratch/death-err.txt"
printf 'Error: 402 Payment Required: You have exhausted your budget. Please add funds\n' >"$out_file"
: >"$err_file"

set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_cap" ]] \
    || fail "classify_death_error must classify 402 budget as quota_cap, got '$dec_cls'"
ok "classify_death_error: 402 budget -> quota_cap (not unknown)"

# 2b. A 402 with a reset window still classifies as quota_cap.
printf 'Payment Required: exhausted your budget. resets in 2h 30m\n' >"$out_file"
: >"$err_file"
set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_cap" ]] \
    || fail "classify_death_error must classify 402+reset as quota_cap, got '$dec_cls'"
ok "classify_death_error: 402 budget + reset window -> quota_cap"

# ============================================================================
# 3. mark_seat_quota_bench writes a real ledger + spawn-bench marker
# ============================================================================
# 3a. Write a quota bench for litellm/worker-cheap.
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' \
    "$lib" "litellm" "worker-cheap" 'Payment Required: You have exhausted your budget. Please add funds' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_quota_bench must return 0 on success (rc=$rc)"
ok "mark_seat_quota_bench: returns 0 for litellm/worker-cheap"

# 3b. Ledger entry exists with health_class=quota_bench.
ledger_path="$LEDGER/litellm__worker-cheap.json"
[[ -f "$ledger_path" ]] || fail "ledger entry not written: $ledger_path"
hc=$(jq -r '.health_class // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$hc" == "quota_bench" ]] || fail "ledger health_class must be quota_bench, got '$hc'"
ok "mark_seat_quota_bench: ledger health_class=quota_bench"

# 3c. usable_at is in the future.
usable_at=$(jq -r '.usable_at // ""' "$ledger_path" 2>/dev/null || echo "")
[[ -n "$usable_at" ]] || fail "ledger usable_at is empty"
now_epoch=$(date -u +%s)
ua_epoch=$(date -u -d "$usable_at" +%s 2>/dev/null || echo 0)
[[ "$ua_epoch" =~ ^[0-9]+$ ]] || fail "ledger usable_at is not a valid timestamp: $usable_at"
(( ua_epoch > now_epoch )) || fail "ledger usable_at must be in the future (ua=$usable_at, now=$(date -u +%Y-%m-%dT%H:%M:%SZ))"
ok "mark_seat_quota_bench: ledger usable_at=$usable_at is in the future"

# 3d. source is money_boundary (exempt from SEAT_NON_MONEY_WALL_MAX_S).
src=$(jq -r '.source // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$src" == "money_boundary" ]] || fail "ledger source must be money_boundary, got '$src'"
ok "mark_seat_quota_bench: ledger source=money_boundary"

# 3e. Clobber-proof spawn-bench marker also written.
marker_path="$LEDGER/litellm__worker-cheap.spawn-bench.json"
[[ -f "$marker_path" ]] || fail "spawn-bench marker not written: $marker_path"
m_usable=$(jq -r '.usable_at // ""' "$marker_path" 2>/dev/null || echo "")
[[ -n "$m_usable" ]] || fail "marker usable_at is empty"
ok "mark_seat_quota_bench: spawn-bench marker written with usable_at=$m_usable"

# 3f. Reset window parsing: "resets in 2h 30m" -> 9000s window.
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' \
    "$lib" "litellm" "worker-capable" 'Payment Required: exhausted your budget. resets in 2h 30m' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_quota_bench with reset window must return 0 (rc=$rc)"
ledger_path2="$LEDGER/litellm__worker-capable.json"
ua2=$(jq -r '.usable_at // ""' "$ledger_path2" 2>/dev/null || echo "")
ua2_epoch=$(date -u -d "$ua2" +%s 2>/dev/null || echo 0)
diff=$(( ua2_epoch - now_epoch ))
# 2h 30m = 9000s; allow ±60s slack.
(( diff > 8940 && diff < 9060 )) || fail "reset window 2h30m should give ~9000s, got ${diff}s"
ok "mark_seat_quota_bench: reset window '2h 30m' -> ~9000s bench (diff=${diff}s)"

# ============================================================================
# 4. seat_usable returns 1 (unusable) for a quota_benched seat
# ============================================================================
set +e
bash -c 'source "$0"; load_seat_caps; _SEAT_USABLE_SILENT=1 seat_usable "$1" "$2"' \
    "$lib" "litellm" "worker-cheap" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "seat_usable must return 1 (unusable) for a quota_benched seat (rc=$rc)"
ok "seat_usable: returns 1 (unusable) for litellm/worker-cheap with quota_bench"

# 4b. A clean seat (no ledger) is still usable.
set +e
bash -c 'source "$0"; load_seat_caps; _SEAT_USABLE_SILENT=1 seat_usable "$1" "$2"' \
    "$lib" "devin" "swe-2-max" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "seat_usable must return 0 (usable) for a clean seat (rc=$rc)"
ok "seat_usable: returns 0 (usable) for devin/swe-2-max (no ledger)"

echo
echo "All budget-402 classification tests passed."
