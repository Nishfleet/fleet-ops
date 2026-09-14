#!/usr/bin/env bash
# tests/budget-402-pick-fallback.test.sh
#
# fleet-ops#6652: when the LiteLLM proxy is ready but the picked group
# (litellm/worker-cheap) is budget-walled (402 "Payment Required: exhausted
# your budget"), the pick path in bin/pi-issue-run must fall back in the SAME
# tick to the direct prepaid lane (devin/swe-2-max) so the work item still
# runs. Without this, the walled group is re-picked every restart and burns
# the StartLimitBurst on a guaranteed 402.
#
# Proves:
#   1. bin/pi-issue-run has the fleet-ops#6652 seat_usable check on the
#      litellm seat with fallback to direct_fallback_seat.
#   2. The fallback block is gated on seat_usable returning 1 (unusable)
#      for the litellm seat.
#   3. The fallback block calls direct_fallback_seat and checks seat_usable
#      on the direct seat before using it.
#   4. The block logs the fallback reason (fleet-ops#6652).
#
# Runs entirely offline: grep-based structural test on bin/pi-issue-run.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# === Test 1: the #6652 seat_usable check block exists in pi-issue-run ===
grep -qF 'fleet-ops#6652' "$bin" \
    || fail "bin/pi-issue-run does not reference fleet-ops#6652"
ok "Test 1: bin/pi-issue-run references fleet-ops#6652"

# === Test 2: the block checks seat_usable on the litellm seat ===
# The block must call seat_usable on the litellm-picked seat (_lit_p/_lit_m).
grep -qE 'seat_usable.*_lit_p.*_lit_m' "$bin" \
    || fail "bin/pi-issue-run does not check seat_usable on the litellm seat"
ok "Test 2: seat_usable check on litellm seat (_lit_p/_lit_m)"

# === Test 3: the block falls back to direct_fallback_seat ===
# The fallback must call direct_fallback_seat when the litellm seat is benched.
# The #6652 block must be INSIDE the litellm_ready branch (not the else branch
# which already had direct_fallback_seat for #6315).
grep -B2 -A2 'direct_fallback_seat' "$bin" | grep -q 'fleet-ops#6652' \
    || fail "bin/pi-issue-run does not wire direct_fallback_seat in the #6652 block"
ok "Test 3: direct_fallback_seat called in the #6652 fallback block"

# === Test 4: the block checks seat_usable on the direct fallback seat ===
grep -qE 'seat_usable.*_dfp_p.*_dfp_m' "$bin" \
    || fail "bin/pi-issue-run does not check seat_usable on the direct fallback seat"
ok "Test 4: seat_usable check on direct fallback seat (_dfp_p/_dfp_m)"

# === Test 5: the block logs the fallback reason ===
grep -qF 'litellm group' "$bin" && grep -qF 'benched' "$bin" \
    && grep -qF 'fleet-ops#6652' "$bin" \
    || fail "bin/pi-issue-run does not log the #6652 fallback reason"
ok "Test 5: fallback reason logged (litellm group benched; fleet-ops#6652)"

# === Test 6: the block is inside the litellm_ready TRUE branch ===
# The #6652 block must be after `if litellm_ready; then` and before the
# `seat_log "pi-issue-run: $inst group=` line that follows the fi. This
# ensures it runs when the proxy IS ready but the group is walled, not
# just when the proxy is down (which is the #6315 path).
line_ready=$(grep -n 'if litellm_ready; then' "$bin" | head -1 | cut -d: -f1)
line_6652=$(grep -n 'fleet-ops#6652' "$bin" | head -1 | cut -d: -f1)
line_group_log=$(grep -n 'seat_log.*group=.*privacy' "$bin" | head -1 | cut -d: -f1)
[[ -n "$line_ready" && -n "$line_6652" && -n "$line_group_log" ]] \
    || fail "could not locate litellm_ready / #6652 / group_log lines (ready=$line_ready 6652=$line_6652 group=$line_group_log)"
(( line_ready < line_6652 )) || fail "#6652 block is before litellm_ready (ready=$line_ready 6652=$line_6652)"
(( line_6652 < line_group_log )) || fail "#6652 block is after group_log (6652=$line_6652 group=$line_group_log)"
ok "Test 6: #6652 block is inside the litellm_ready TRUE branch (ready=$line_ready < 6652=$line_6652 < group_log=$line_group_log)"

# === Test 7: functional test — walled litellm seat -> direct fallback ===
# Simulate the pick path: litellm_ready returns 0, litellm_seat returns
# litellm/worker-cheap, seat_usable returns 1 for litellm/worker-cheap
# (walled) and 0 for devin/swe-2-max (usable). The pick path must fall
# back to devin/swe-2-max.
scratch="$(mktemp -d -t budget-402-pick.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "providers": {
    "litellm": {"cap": 4, "class": "proxy", "models": {"worker-cheap": 4}},
    "devin": {"cap": 4, "class": "subscription", "models": {"swe-2-max": 4}}
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "litellm": {"models": [{"id": "worker-cheap", "cost": {"input": 0}}]},
    "devin": {"models": [{"id": "swe-2-max", "cost": {"input": 0}}]}
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE" "$XDG_RUNTIME_DIR"

lib="$repo_root/lib/litellm-seat.sh"

# Write a quota_bench ledger for litellm/worker-cheap so seat_usable returns 1.
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' \
    "$lib" "litellm" "worker-cheap" 'Payment Required: You have exhausted your budget. Please add funds' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_quota_bench failed in functional test (rc=$rc)"

# Simulate the pick path logic:
# 1. litellm_ready -> true (stubbed)
# 2. litellm_seat worker-cheap -> litellm/worker-cheap
# 3. seat_usable litellm/worker-cheap -> 1 (walled)
# 4. direct_fallback_seat -> devin/swe-2-max
# 5. seat_usable devin/swe-2-max -> 0 (usable)
# 6. seat = devin/swe-2-max
set +e
result=$(bash -c '
    source "$0" 2>/dev/null
    load_seat_caps 2>/dev/null
    litellm_ready() { return 0; }
    direct_fallback_seat() { printf "devin\tswe-2-max\n"; }
    seat=$(litellm_seat "worker-cheap" 2>/dev/null || true)
    if [[ -n "$seat" ]]; then
        read -r _lit_p _lit_m <<< "$seat"
        if ! _SEAT_USABLE_SILENT=1 seat_usable "$_lit_p" "$_lit_m" 2>/dev/null; then
            seat=""
            if _dfp=$(direct_fallback_seat); then
                read -r _dfp_p _dfp_m <<< "$_dfp"
                if _SEAT_USABLE_SILENT=1 seat_usable "$_dfp_p" "$_dfp_m" 2>/dev/null; then
                    seat="$_dfp"
                fi
            fi
        fi
    fi
    printf "%s" "$seat"
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pick path simulation failed (rc=$rc)"
[[ "$result" == $'devin\tswe-2-max' ]] \
    || fail "pick path must fall back to devin/swe-2-max, got '$result'"
ok "Test 7: walled litellm/worker-cheap -> fallback to devin/swe-2-max (result=$result)"

# === Test 8: when litellm seat is NOT walled, no fallback ===
# Remove the ledger so litellm/worker-cheap is usable.
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/litellm__worker-cheap.json" "$PI_SEAT_HEALTH_LEDGER_DIR/litellm__worker-cheap.spawn-bench.json"
set +e
result2=$(bash -c '
    source "$0" 2>/dev/null
    load_seat_caps 2>/dev/null
    litellm_ready() { return 0; }
    direct_fallback_seat() { printf "devin\tswe-2-max\n"; }
    seat=$(litellm_seat "worker-cheap" 2>/dev/null || true)
    if [[ -n "$seat" ]]; then
        read -r _lit_p _lit_m <<< "$seat"
        if ! _SEAT_USABLE_SILENT=1 seat_usable "$_lit_p" "$_lit_m" 2>/dev/null; then
            seat=""
            if _dfp=$(direct_fallback_seat); then
                read -r _dfp_p _dfp_m <<< "$_dfp"
                if _SEAT_USABLE_SILENT=1 seat_usable "$_dfp_p" "$_dfp_m" 2>/dev/null; then
                    seat="$_dfp"
                fi
            fi
        fi
    fi
    printf "%s" "$seat"
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pick path simulation (no wall) failed (rc=$rc)"
[[ "$result2" == $'litellm\tworker-cheap' ]] \
    || fail "pick path must keep litellm/worker-cheap when not walled, got '$result2'"
ok "Test 8: healthy litellm/worker-cheap -> no fallback (result=$result2)"

# === Test 9: cross-group fallback exists (worker-capable then worker-private) ===
# The 2026-09-14 outage: classifier fired, direct prepaid was unusable,
# workers=0 while worker-capable and worker-private were USABLE. The pick
# path must try those groups before the no-seat exit.
grep -qF 'for _fb_group in worker-capable worker-private' "$bin" \
    || fail "bin/pi-issue-run does not loop worker-capable then worker-private after a walled cheap group"
ok "Test 9: worker-capable then worker-private loop is in pi-issue-run"

# === Test 10: cheap walled + prepaid unusable -> worker-capable ===
set +e
result3=$(bash -c '
    source "$0" 2>/dev/null
    load_seat_caps 2>/dev/null
    litellm_ready() { return 0; }
    direct_fallback_seat() { printf "devin\tswe-2-max\n"; }
    seat_usable() {
        case "$1/$2" in
            litellm/worker-cheap|devin/swe-2-max) return 1 ;;
            *) return 0 ;;
        esac
    }
    _lit_group="worker-cheap"
    seat=$(litellm_seat "$_lit_group" 2>/dev/null || true)
    if [[ -n "$seat" ]]; then
        read -r _lit_p _lit_m <<< "$seat"
        if ! _SEAT_USABLE_SILENT=1 seat_usable "$_lit_p" "$_lit_m" 2>/dev/null; then
            seat=""
            if _dfp=$(direct_fallback_seat); then
                read -r _dfp_p _dfp_m <<< "$_dfp"
                if _SEAT_USABLE_SILENT=1 seat_usable "$_dfp_p" "$_dfp_m" 2>/dev/null; then
                    seat="$_dfp"
                fi
            fi
        fi
    fi
    if [[ -z "$seat" && "$_lit_group" == "worker-cheap" ]]; then
        for _fb_group in worker-capable worker-private; do
            _fb=$(litellm_seat "$_fb_group" 2>/dev/null || true)
            [[ -n "$_fb" ]] || continue
            read -r _fb_p _fb_m <<< "$_fb"
            if _SEAT_USABLE_SILENT=1 seat_usable "$_fb_p" "$_fb_m" 2>/dev/null; then
                seat="$_fb"
                break
            fi
        done
    fi
    printf "%s" "$seat"
' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "cross-group pick path simulation failed (rc=$rc)"
[[ "$result3" == $'litellm\tworker-capable' ]] \
    || fail "pick path must fall back to litellm/worker-capable when cheap+prepaid are unusable, got '$result3'"
ok "Test 10: walled cheap + unusable prepaid -> worker-capable (result=$result3)"

echo
echo "All budget-402 pick fallback tests passed."
