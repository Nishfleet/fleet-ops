#!/usr/bin/env bash
# tests/seat-empty-run-ceiling-3727.test.sh
#
# fleet-ops#3727 / #3760: ollama/deepseek-v4-flash:0731 empty-run churn — 12
# empty runs in 2h, geometric bench not converging. The generic
# SEAT_FAILURE_CEILING (default 20) let the seat churn 12 no-ops without
# parking: the geometric cap (6h) re-offered the seat every 6h and the count
# climbed too slowly. fleet-ops#3727 added a SEPARATE, lower
# EMPTY_RUN_FAILURE_CEILING; fleet-ops#3760 lowered it from 5 to 3 so a
# chronic no-op'er parks behind the 24h wall on the 3rd no-op, not the 20th
# (or 5th). The geometric bench still escalates below the ceiling
# (900s -> 1800s).
#
# This test proves, end to end against the live wrapper with PRODUCTION DEFAULTS
# (no ceiling pin, no park-wall pin):
#   (a) the production default EMPTY_RUN_FAILURE_CEILING is 3 (lower than the
#       generic SEAT_FAILURE_CEILING of 20).
#   (b) a seat that no-ops 2 times (below the empty-run ceiling) is NOT parked
#       — the geometric bench holds it (900s -> 1800s).
#   (c) on the 3rd no-op the empty-run failure ceiling engages: the seat is
#       parked behind the 24h wall (SEAT_PARK_WALL_S), and seat_usable holds it.
#   (d) the generic SEAT_FAILURE_CEILING (20) is NOT what parked the seat —
#       count=3 < 20, so the generic ceiling would NOT have parked. The
#       empty-run-specific ceiling is what fires.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness of tests/seat-empty-run-ceiling-default.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-ceiling-3727.XXXXXX)"
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
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
# PRODUCTION DEFAULTS — do NOT pin the ceilings. The test proves the production
# default EMPTY_RUN_FAILURE_CEILING (3, fleet-ops#3760) parks a chronic no-op'er
# on the 3rd no-op, while the generic SEAT_FAILURE_CEILING (20) would NOT have
# parked it until the 20th. SEAT_PARK_WALL_S stays at its default (86400 = 24h).
# Disable the corpse reclassification so the parked seat is not also written
# seat_dead=true — this test proves the parking behaviour in isolation.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 128000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": { "cap": 1, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "deepseek-v4-flash:0731": 1 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

# --- (a) production defaults: EMPTY_RUN_FAILURE_CEILING=3, SEAT_FAILURE_CEILING=20 ---
[[ "${EMPTY_RUN_FAILURE_CEILING:-3}" == "3" ]] \
    || fail "(a) EMPTY_RUN_FAILURE_CEILING = ${EMPTY_RUN_FAILURE_CEILING:-3}, want 3 (production default, fleet-ops#3760)"
[[ "${SEAT_FAILURE_CEILING:-20}" == "20" ]] \
    || fail "(a) SEAT_FAILURE_CEILING = ${SEAT_FAILURE_CEILING:-20}, want 20 (production default, fleet-ops#3531)"
ok "(a) production defaults: EMPTY_RUN_FAILURE_CEILING=3, SEAT_FAILURE_CEILING=20 — empty runs park at 3, not 20"

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

clobber_with_healthy() {
    local p="$1" m="$2" lf="$3"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp="$lf.clobber.$$.$RANDOM.tmp"
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg obs "$now_utc" \
        '{provider:$provider, model:$model, http_status:200,
          health_class:"healthy", retryable:false, seat_dead:false,
          poison_ladder:false, observed_at:$obs,
          source:"after_provider_response", failure_mode:"none",
          usable_at:null, consecutive_failure_count:0}' \
        > "$tmp" 2>/dev/null
    mv "$tmp" "$lf" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

count_of() { jq -r '.consecutive_failure_count // 0' "$1" 2>/dev/null || echo 0; }
wall_s_of_marker() {
    local u now_s u_s
    u=$(jq -r '.usable_at // ""' "$1" 2>/dev/null || true)
    [[ -n "$u" ]] || { echo 0; return; }
    now_s=$(date -u +%s)
    u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
    echo $((u_s - now_s))
}

# Live shape: ollama/deepseek-v4-flash:0731 no-op'ed 12 times in 2h on
# pi-issue runs (fleet-ops#3727). With the generic ceiling at 20, the seat
# churned 12 no-ops without parking. With EMPTY_RUN_FAILURE_CEILING=3
# (fleet-ops#3760), the 3rd no-op parks the seat behind the 24h wall.
p="ollama"; m="deepseek-v4-flash:0731"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"

# --- (b) 2 no-ops below the empty-run ceiling: NOT parked, geometric bench ---
for i in 1 2; do
    mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3760:noop:${i}" >/dev/null 2>&1 \
        || fail "(b) mark_seat_empty_run #${i} failed"
    clobber_with_healthy "$p" "$m" "$lf"
    c=$(count_of "$mf")
    [[ "$c" == "$i" ]] \
        || fail "(b) marker count after no-op #${i} = $c, want $i"
    w=$(wall_s_of_marker "$mf")
    # count < 3 (EMPTY_RUN_FAILURE_CEILING) -> NOT parked. The geometric bench
    # grows (900 -> 1800) but stays below the 24h park wall.
    (( w < ${SEAT_PARK_WALL_S:-86400} - 120 )) \
        || fail "(b) no-op #${i} wall = ${w}s, should be < park wall ${SEAT_PARK_WALL_S:-86400}s (count=$i < ceiling=3, NOT parked yet)"
done
ok "(b) 2 no-ops below EMPTY_RUN_FAILURE_CEILING=3: NOT parked, geometric bench holds (900->1800)"

# --- (c) 3rd no-op: empty-run failure ceiling engages, 24h park ---
mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3760:noop:3" >/dev/null 2>&1 \
    || fail "(c) mark_seat_empty_run #3 (park) failed"
park_count=$(count_of "$mf")
[[ "$park_count" == "3" ]] \
    || fail "(c) marker count after 3rd no-op = $park_count, want 3"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} - 120 && park_wall <= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} + 120 )) \
    || fail "(c) park wall = ${park_wall}s, want ~${SEAT_NON_MONEY_WALL_MAX_S:-21600}s — empty-run ceiling fires on the 3rd no-op; #4640 clamps the non-money park at 6h"
if seat_usable "$p" "$m"; then
    fail "(c) seat_usable returned usable on the 3rd-no-op parked seat — the park wall must hold it out of rotation"
fi
ok "(c) 3rd no-op: count=3, park wall = ${park_wall}s (~6h), seat HELD UNUSABLE — empty-run ceiling parks at 3, not 20 (fleet-ops#3760/#4640)"

# --- (d) the generic SEAT_FAILURE_CEILING (20) did NOT park the seat ---
# count=3 < 20 (SEAT_FAILURE_CEILING), so the generic ceiling would NOT have
# parked. The empty-run-specific ceiling (3) is what fired. Prove it: the
# generic _seat_parked_by_ceiling at count=3 with the generic ceiling returns
# false, but with the empty-run ceiling returns true.
if _seat_parked_by_ceiling 3 20; then
    fail "(d) _seat_parked_by_ceiling(3, 20) returned true — the generic ceiling should NOT park at count=3"
fi
if ! _seat_parked_by_ceiling 3 3; then
    fail "(d) _seat_parked_by_ceiling(3, 3) returned false — the empty-run ceiling should park at count=3"
fi
ok "(d) generic ceiling (20) does NOT park at count=3; empty-run ceiling (3) does — the separate ceiling is what fires (fleet-ops#3760)"

ok "fleet-ops#3760: repeated empty runs park at EMPTY_RUN_FAILURE_CEILING=3 (not the generic 20) — chronic no-op churn parks on the 3rd no-op (#4640 clamps the non-money park at 6h)"
