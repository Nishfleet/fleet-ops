#!/usr/bin/env bash
# tests/seat-lib-dispatch.test.sh
#
# fleet-ops#859: data-driven lane-fault dispatch. _dispatch_lane_faults
# iterates the error_classes registry in seat-caps.json by trigger_order;
# the FIRST matching class fires its writer and the function returns (no later
# class fires — one writer wins, no double-bench).
#
# What we prove:
#   1. _load_error_classes reads seat-caps.json's error_classes block, sorted
#      by trigger_order ascending (quota_bench=2 before overload_bench=3).
#   2. _dispatch_lane_faults fires the writer for the matching class and
#      returns 0; no match returns 1.
#   3. Trigger-order contract: when two classes match the same body, the LOWER
#      trigger_order wins and the higher one's writer does NOT fire.
#   4. No-double-bench contract: a single dispatch call fires exactly one
#      writer, even if both matchers would match.
#   5. Backwards-compat: the per-provider quota_bench_default_s and
#      503_bench_default_s fields still resolve through the writers unchanged.
#
# Runs entirely offline: stubbed seat-caps.json, ledger dir, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-dispatch.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: no live systemd units in cap accounting.
export PI_SEAT_LIB_CHECK_SYSTEMD=0

LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

# Cap map with both error class defaults. commandcode has 503_bench_default_s=600
# (the live fleet-ops#652 fixture); devin has quota_bench_default_s=900.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2, "class": "free",
      "503_bench_default_s": 600,
      "models": {"minimax/minimax-m3-free": 2}
    },
    "devin": {
      "cap": 4, "class": "subscription",
      "quota_bench_default_s": 900,
      "models": {"swe-1-7": 4}
    }
  },
  "error_classes": {
    "quota_bench": {
      "matcher": "is_quota_cap_error",
      "writer": "mark_seat_quota_bench",
      "default_window_s_seconds": "quota_bench_default_s",
      "trigger_order": 2,
      "description": "Hard cap / quota wall."
    },
    "overload_bench": {
      "matcher": "is_overload_error",
      "writer": "mark_seat_overload_bench",
      "default_window_s_seconds": "503_bench_default_s",
      "trigger_order": 3,
      "description": "503 / upstream-overload storm."
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

# Minimal models.json so seat-lib loads without complaint.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "minimax/minimax-m3-free", "cost": { "input": 0 } }
      ]
    },
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

lib="$repo_root/lib/seat-lib.sh"

# --- 1. _load_error_classes: sorted by trigger_order ----------------------
set +e
loaded=$(bash -c 'source "$0"; load_seat_caps; _load_error_classes' "$lib" 2>/dev/null)
set -e
# Expect: quota_bench (order 2) BEFORE overload_bench (order 3).
order_line=$(printf '%s\n' "$loaded" | head -n1)
cls_name=$(printf '%s' "$order_line" | cut -f2)
[[ "$cls_name" == "quota_bench" ]] || fail "_load_error_classes: first row must be quota_bench (trigger_order=2), got '$cls_name'"

second_line=$(printf '%s\n' "$loaded" | sed -n '2p')
cls_name2=$(printf '%s' "$second_line" | cut -f2)
[[ "$cls_name2" == "overload_bench" ]] || fail "_load_error_classes: second row must be overload_bench (trigger_order=3), got '$cls_name2'"
ok "_load_error_classes: sorted ascending by trigger_order (quota_bench=2, overload_bench=3)"

# --- 2. _dispatch_lane_faults: overload body hits overload_bench only -------
rm -f "$LEDGER"/*.json 2>/dev/null || true
overload_body='errorMessage: 503: Upstream model provider is temporarily unavailable.'
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" "$overload_body" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "_dispatch: overload body must match and return rc=0 (got $rc)"
ledger_file="$LEDGER/commandcode__minimax_minimax-m3-free.json"
[[ -f "$ledger_file" ]] || fail "_dispatch: overload writer did not create ledger at $ledger_file"
hc=$(jq -r '.health_class' "$ledger_file")
[[ "$hc" == "overload_bench" ]] || fail "_dispatch: overload writer must write health_class=overload_bench, got '$hc'"
fm=$(jq -r '.failure_mode' "$ledger_file")
[[ "$fm" == "overload_503" ]] || fail "_dispatch: overload writer must write failure_mode=overload_503, got '$fm'"
ok "_dispatch: overload body -> overload_bench writer fires, health_class=overload_bench failure_mode=overload_503"

# --- 2b. _dispatch_lane_faults: quota body hits quota_bench only -------------
rm -f "$LEDGER"/*.json 2>/dev/null || true
quota_body="INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h"
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "devin" "swe-1-7" "$quota_body" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "_dispatch: quota body must match and return rc=0 (got $rc)"
ledger_file="$LEDGER/devin__swe-1-7.json"
[[ -f "$ledger_file" ]] || fail "_dispatch: quota writer did not create ledger at $ledger_file"
hc=$(jq -r '.health_class' "$ledger_file")
[[ "$hc" == "quota_bench" ]] || fail "_dispatch: quota writer must write health_class=quota_bench, got '$hc'"
ok "_dispatch: quota body -> quota_bench writer fires, health_class=quota_bench"

# --- 3. trigger-order contract: dual-match body, quota wins (lower order) ----
# A body that genuinely matches BOTH matchers: 'weekly Clinepass limit' hits
# is_quota_cap_error's hard-cap keyword, '503 ... temporarily unavailable' hits
# is_overload_error. quota_bench (trigger_order=2) is checked first and fires
# its writer; overload_bench (order 3) never runs -> no double-bench.
rm -f "$LEDGER"/*.json 2>/dev/null || true
both_body=$'HTTP/1.1 503 Service Unavailable\nINFERENCE_CAP_ERROR: weekly Clinepass limit reached\nUpstream model provider is temporarily unavailable'
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "devin" "swe-1-7" "$both_body" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "_dispatch: dual-match body must return rc=0 (got $rc)"
ledger_file="$LEDGER/devin__swe-1-7.json"
[[ -f "$ledger_file" ]] || fail "_dispatch: dual-match must write exactly one ledger"
hc=$(jq -r '.health_class' "$ledger_file")
# quota_bench has trigger_order=2 (checked first), so it wins.
[[ "$hc" == "quota_bench" ]] || fail "_dispatch: dual-match must fire quota_bench (trigger_order=2, lower wins), got '$hc'"
ok "_dispatch: dual-match body -> quota_bench wins (trigger_order=2 before overload_bench=3), no double-bench"

# --- 4. no-double-bench: only ONE writer fires, one ledger line -----------
# Same dual-match body. Verify the ledger has exactly ONE entry (not two).
# The writer writes a single file per seat; mark_seat_quota_bench then
# mark_seat_overload_bench would both write to the SAME file (same seat),
# so the final file reflects whichever ran last. Since dispatch STOPS after
# the first match, only quota_bench ran. Verify failure_mode is quota_cap.
fm=$(jq -r '.failure_mode' "$ledger_file")
[[ "$fm" == "quota_cap" ]] || fail "_dispatch: dual-match ledger failure_mode must be quota_cap (overload writer did not fire), got '$fm'"
ok "_dispatch: no-double-bench — only the first matching writer fires"

# --- 4b. no match: dispatch returns 1 and writes nothing -------------------
rm -f "$LEDGER"/*.json 2>/dev/null || true
no_match_body="some unrelated error message that matches nothing"
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" "$no_match_body" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "_dispatch: no-match body must return rc=1 (got $rc)"
shopt -s nullglob
count=( "$LEDGER"/*.json )
shopt -u nullglob
[[ "${#count[@]}" == "0" ]] || fail "_dispatch: no-match must write zero ledger entries (got ${#count[@]}"
ok "_dispatch: no-match body -> rc=1, no writer fired"

# --- 5. backwards-compat: writers still resolve provider defaults ----------
# Overload body with no Retry-After -> mark_seat_overload_bench uses
# 503_bench_default_s=600 from the commandcode provider row.
rm -f "$LEDGER"/*.json 2>/dev/null || true
overload_no_retry='errorMessage: 503: Upstream model provider is temporarily unavailable.'
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" "$overload_no_retry" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "_dispatch: overload-no-retry must still fire (got $rc)"
ledger_file="$LEDGER/commandcode__minimax_minimax-m3-free.json"
[[ -f "$ledger_file" ]] || fail "_dispatch: overload-no-retry did not write ledger"
bw=$(jq -r '.bench_window_s' "$ledger_file")
[[ "$bw" == "600" ]] || fail "_dispatch: overload writer must use 503_bench_default_s=600 when no Retry-After in body, got '$bw'"
bu=$(jq -r '.bench_until' "$ledger_file")
bu_s=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
now_s=$(date -u +%s)
delta=$((bu_s - now_s))
(( delta >= 595 && delta <= 605 )) || fail "_dispatch: overload bench_until must be ~now+600s, got delta=${delta}s"
ok "_dispatch: overload writer resolves 503_bench_default_s=600 from seat-caps.json (backwards-compat with provider default key)"

# Quota body with no explicit window -> mark_seat_quota_bench uses
# quota_bench_default_s=900 from the devin provider row.
rm -f "$LEDGER"/*.json 2>/dev/null || true
quota_no_window='INFERENCE_CAP_ERROR: weekly Clinepass limit'
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "devin" "swe-1-7" "$quota_no_window" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "_dispatch: quota-no-window must still fire (got $rc)"
ledger_file="$LEDGER/devin__swe-1-7.json"
bw=$(jq -r '.bench_window_s' "$ledger_file")
[[ "$bw" == "900" ]] || fail "_dispatch: quota writer must use quota_bench_default_s=900 when no window in body, got '$bw'"
ok "_dispatch: quota writer resolves quota_bench_default_s=900 from seat-caps.json (backwards-compat)"

# --- 6. _dispatch_lane_faults is safe with no error_classes block ----------
cat >"$scratch/seat-caps-no-registry.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "quota_bench_default_s": 900, "models": { "swe-1-7": 4 } }
  }
}
JSON
rm -f "$LEDGER"/*.json 2>/dev/null || true
# A quota body that WOULD match — but no registry -> nothing dispatched.
quota_body2="INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h"
set +e
SEAT_CAPS_JSON="$scratch/seat-caps-no-registry.json" \
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "devin" "swe-1-7" "$quota_body2" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "_dispatch: no registry must return rc=1 (no match), got $rc"
shopt -s nullglob
count=( "$LEDGER"/*.json )
shopt -u nullglob
[[ "${#count[@]}" == "0" ]] || fail "_dispatch: no registry must write zero ledgers (got ${#count[@]}"
ok "_dispatch: missing error_classes block -> rc=1, no writer fires (graceful degradation)"

ok "seat-lib-dispatch: registry sorted, trigger-order wins, no-double-bench, backward-compat, graceful no-registry"
