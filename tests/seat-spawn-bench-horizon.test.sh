#!/usr/bin/env bash
# tests/seat-spawn-bench-horizon.test.sh
#
# fleet-ops#4640: a count=0 quota_cap stamp with usable_at a year out cannot
# be a real provider quota wall. Live 2026-09-09 spawn-bench files:
#
#   minimax__MiniMax-M3.spawn-bench.json
#     usable_at=2027-09-08T09:36:52Z count=0 failure_mode=quota_cap
#     backoff_s=31536000 writer=alert-repair-FleetProviderSpendBoundary
#   openrouter__{google_gemma-4-31b-it_free,minimax_minimax-m3_free,
#                nvidia_nemotron-3-ultra-550b-a55b_free,z-ai_glm-5.2_free}
#     same 2027 stamp, same count=0
#
# The ledger for MiniMax-M3 was health_class=healthy / http 200. seat_usable
# checked the spawn-bench clock FIRST and returned UNUSABLE, so
# PICK_SEAT_COUNT_SLOTS counted 0 light slots.
#
# This test pins the live shape: a 365d count=0 quota_cap marker written 7h
# ago, over a healthy ledger observed after the marker, MUST be usable
# after the 6h error-class cap. Before the cap, the same fixture is
# unusable (the 365d clock wins). A 1h count=0 wall still holds. A
# spawn_fail marker is not this class and still holds. Write-side
# _seat_write_spawn_bench must refuse to persist backoff_s=31536000.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-spawn-bench-horizon.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export SEAT_FAILURE_CEILING_PROM="$scratch/fleet-seat-failure-ceiling.prom"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_LIB_CHECK_TRANSPORT=0
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "minimax": { "models": [ { "id": "MiniMax-M3" } ] },
    "openrouter": { "models": [ { "id": "minimax/minimax-m3:free" } ] },
    "nowindow": { "models": [ { "id": "m1" } ] },
    "dailyp": { "models": [ { "id": "m1" } ] }
  }
}
JSON

# Mirrors production: minimax and openrouter declare NO quota_window, so
# _wall_capped_at_horizon is a no-op and only the #4640 error-class cap fires.
cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["openrouter"],
  "providers": {
    "minimax": { "cap": 2, "class": "metered", "models": { "MiniMax-M3": 2 } },
    "openrouter": { "cap": 4, "class": "metered", "models": { "minimax/minimax-m3:free": 2 } },
    "nowindow": { "cap": 1, "class": "free", "models": { "m1": 1 } },
    "dailyp": { "cap": 1, "class": "free", "quota_window": "daily", "models": { "m1": 1 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"
load_seat_caps

iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

marker_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.spawn-bench.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

write_healthy_ledger() {
    local p="$1" m="$2" obs="$3"
    jq -n --arg p "$p" --arg m "$m" --arg o "$obs" \
        '{provider:$p, model:$m, http_status:200, health_class:"healthy",
          retryable:false, seat_dead:false, poison_ladder:false,
          observed_at:$o, source:"after_provider_response",
          failure_mode:"none", usable_at:null, consecutive_failure_count:0}' \
        >"$(ledger_file "$p" "$m")"
}

write_count0_spawn_bench() {
    local p="$1" m="$2" written="$3" usable="$4"
    jq -n --arg p "$p" --arg m "$m" --arg w "$written" --arg u "$usable" \
        '{provider:$p, model:$m, usable_at:$u, written_at:$w,
          backoff_s:31536000, failure_mode:"quota_cap",
          consecutive_failure_count:0, seat_dead:false,
          reason:"money boundary fleet-ops#3284",
          writer:"alert-repair-FleetProviderSpendBoundary"}' \
        >"$(marker_file "$p" "$m")"
}

now_s=$(date -u +%s)
SIXH=21600
YEAR=31536000

# --- A: live MiniMax-M3 shape. Marker written 7h ago, 365d wall, count=0.
# Ledger healthy observed 1h ago (after the marker, so #3737 does not hold).
# After the 6h cap the wall is in the past -> USABLE.
p=minimax; m=MiniMax-M3
write_count0_spawn_bench "$p" "$m" "$(iso_at $(( now_s - 7 * 3600 )))" "$(iso_at $(( now_s + YEAR )))"
write_healthy_ledger "$p" "$m" "$(iso_at $(( now_s - 3600 )))"
seat_usable "$p" "$m" >/dev/null 2>&1 \
    || fail "A: count=0 quota_cap spawn-bench 365d written 7h ago must fail-open after the 6h cap (live MiniMax-M3 2027 stamp)"
ok "A: live MiniMax-M3 shape (count=0, 365d, written 7h ago) is usable after the 6h cap"

# --- B: same class, wall still inside 6h -> UNUSABLE.
write_count0_spawn_bench "$p" "$m" "$(iso_at "$now_s")" "$(iso_at $(( now_s + 3600 )))"
write_healthy_ledger "$p" "$m" "$(iso_at "$now_s")"
if seat_usable "$p" "$m" >/dev/null 2>&1; then
    fail "B: a 1h count=0 quota_cap wall must still hold"
fi
ok "B: a 1h count=0 quota_cap wall still holds"

# --- C: spawn_fail is a different error class and is not this cap.
jq -n --arg p "$p" --arg m "$m" --arg w "$(iso_at "$now_s")" --arg u "$(iso_at $(( now_s + 300 )))" \
    '{provider:$p, model:$m, usable_at:$u, written_at:$w, backoff_s:300,
      failure_mode:"spawn_fail", consecutive_failure_count:1, seat_dead:false,
      reason:"no_block:rc=1"}' \
    >"$(marker_file "$p" "$m")"
write_healthy_ledger "$p" "$m" "$(iso_at "$now_s")"
if seat_usable "$p" "$m" >/dev/null 2>&1; then
    fail "C: spawn_fail marker must still hold (not the count=0 quota_cap class)"
fi
ok "C: spawn_fail (no_block:rc=1) still holds — cap cites error class"

# --- D: write-side refuses to persist a 365d count=0 quota_cap stamp.
rm -f "$(marker_file "$p" "$m")"
far=$(iso_at $(( now_s + YEAR )))
_seat_write_spawn_bench "$p" "$m" "$far" "money boundary fleet-ops#3284" "$YEAR" 0 "quota_cap" false \
    || fail "D: _seat_write_spawn_bench failed"
got_ua=$(jq -r '.usable_at' "$(marker_file "$p" "$m")")
got_bo=$(jq -r '.backoff_s' "$(marker_file "$p" "$m")")
got_s=$(date -u -d "$got_ua" +%s)
delta=$(( got_s - now_s ))
(( delta <= SIXH + 5 && delta > 0 )) \
    || fail "D: write-side usable_at=$got_ua delta=${delta}s, want <= ${SIXH}s (6h cap)"
[[ "$got_bo" == "$SIXH" ]] || fail "D: write-side backoff_s=$got_bo, want $SIXH"
ok "D: _seat_write_spawn_bench clamps 365d count=0 quota_cap to 6h"

# --- E: openrouter ledger quota_bench count=0 365d (the sibling of the
# spawn-bench stamp). observed 7h ago -> 6h cap already passed -> USABLE.
p=openrouter; m="minimax/minimax-m3:free"
obs=$(iso_at $(( now_s - 7 * 3600 )))
until=$(iso_at $(( now_s + YEAR )))
jq -n --arg p "$p" --arg m "$m" --arg o "$obs" --arg b "$until" \
    '{provider:$p, model:$m, health_class:"quota_bench", seat_dead:false,
      observed_at:$o, usable_at:$b, bench_until:$b, source:"money_boundary",
      failure_mode:"quota_cap", consecutive_failure_count:0}' \
    >"$(ledger_file "$p" "$m")"
rm -f "$(marker_file "$p" "$m")"
seat_usable "$p" "$m" >/dev/null 2>&1 \
    || fail "E: count=0 quota_bench ledger 365d observed 7h ago must fail-open after the 6h cap"
ok "E: live openrouter :free ledger shape (count=0 quota_bench 2027) is usable after the 6h cap"

# --- F: healthy control, no marker, no wall.
p=nowindow; m=m1
write_healthy_ledger "$p" "$m" "$(iso_at "$now_s")"
rm -f "$(marker_file "$p" "$m")"
seat_usable "$p" "$m" >/dev/null 2>&1 \
    || fail "F: healthy control with no marker must be usable"
ok "F: healthy control group is usable"

# --- G: _error_class_wall_cap_s cites the class.
got=$(_error_class_wall_cap_s minimax quota_cap 0)
[[ "$got" == "$SIXH" ]] || fail "G: count=0 quota_cap cap=$got, want $SIXH"
got=$(_error_class_wall_cap_s minimax spawn_fail 1)
[[ "$got" == "0" ]] || fail "G: spawn_fail cap=$got, want 0 (not this class)"
got=$(_error_class_wall_cap_s minimax quota_cap 5)
[[ "$got" == "0" ]] || fail "G: count=5 quota_cap cap=$got, want 0 (real-looking wall, #3941 park owns it)"
got=$(_error_class_wall_cap_s dailyp spawn_fail 1)
[[ "$got" == "0" ]] || fail "G: spawn_fail on a windowed provider cap=$got, want 0 (#3941 park owns it)"
got=$(_error_class_wall_cap_s dailyp quota_cap 0)
[[ "$got" == "86400" ]] || fail "G: count=0 quota_cap on daily quota_window cap=$got, want 86400 (window wins)"
got=$(_error_class_wall_cap_s dailyp quota_exhausted 9)
[[ "$got" == "0" ]] || fail "G: count>0 quota_exhausted on a windowed provider cap=$got, want 0 (live Cline 402s keep their own clock)"
ok "G: cap is 6h only for count=0 quota_cap/quota_exhausted with no quota_window"

echo "ALL OK: seat spawn-bench horizon cap (fleet-ops#4640)"
