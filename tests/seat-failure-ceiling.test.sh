#!/usr/bin/env bash
# tests/seat-failure-ceiling.test.sh
#
# fleet-ops#1362: the seat prober kept hammering seats past 60 consecutive
# failures. The escalated backoff capped at 1h (spawn) / 2h (empty) and the
# quota/overload/hang benches used a FLAT provider default every cycle, so a
# chronically failing seat re-entered rotation every cap/flat interval forever
# — consecutive_failure_count climbed to 72 on devin/glm-5-2 (HTTP 429), 64 on
# opencode/muse-spark-1.2-contributor-free (HTTP 500), 63 on
# opencode/mimo-v2.5-free (HTTP 429) while the bench never grew past ~15min.
#
# The fix: a failure-count ceiling (SEAT_FAILURE_CEILING, default 60) parks a
# seat behind a long wall (SEAT_PARK_WALL_S, default 24h) once its
# consecutive_failure_count crosses the ceiling, and emits one metric
# (fleet_seat_failure_ceiling_parked{provider,model}) so the park is observable.
#
# This test proves against the THREE live seat ids from the snapshot:
#   (1) a seat one failure below the ceiling is NOT parked (base backoff holds).
#   (2) the next failure crosses the ceiling -> wall jumps to the park wall
#       across all five marker types (spawn-fail, empty-run, quota-bench,
#       overload-bench, hang-bench), seat_usable holds it, and the metric is
#       emitted with the right provider/model labels.
#   (3) a seat already PAST the ceiling (the live 72/64/63 state) is parked on
#       its very next failure — the ceiling is >=, not ==, so already-high
#       seats are caught without waiting for a fresh climb from 0.
#   (4) the metric file merges multiple parked seats (no clobber).
#   (5) fail-open still holds: after the park wall expires the seat is usable
#       again (a recovered seat is re-eligible; the park is a long cooldown,
#       not a permanent wall).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-failure-ceiling.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export SEAT_FAILURE_CEILING_PROM="$scratch/fleet-seat-failure-ceiling.prom"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
# Use a small ceiling so the test does not need 60 iterations to cross it.
export SEAT_FAILURE_CEILING=60
export SEAT_PARK_WALL_S=86400
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": { "models": [ { "id": "glm-5-2" } ] },
    "opencode": { "models": [ { "id": "muse-spark-1.2-contributor-free" }, { "id": "mimo-v2.5-free" } ] }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "glm-5-2": 4 } },
    "opencode": { "cap": 6, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "muse-spark-1.2-contributor-free": 3, "mimo-v2.5-free": 3 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

# Seed a ledger with a given consecutive_failure_count + health_class so the
# next marker call merges from that count (simulates the live 72/64/63 state).
seed_ledger() {
    local p="$1" m="$2" count="$3" hc="$4"
    local lf
    lf=$(ledger_file "$p" "$m")
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg observed "$now_utc" \
        --arg hc "$hc" --argjson count "$count" \
        '{provider:$provider,model:$model,http_status:429,retry_after:null,
          health_class:$hc,seat_dead:false,poison_ladder:false,retryable:true,
          observed_at:$observed,consecutive_failure_count:$count}' \
        >"$lf" 2>/dev/null || fail "seed_ledger jq failed"
}

wall_s_of() {
    # Echo the bench/usable wall in seconds (now -> usable_at or bench_until).
    local lf="$1" field="${2:-usable_at}"
    local u
    u=$(jq -r ".${field} // empty" "$lf" 2>/dev/null || true)
    [[ -n "$u" ]] || { echo 0; return; }
    local now_s u_s
    now_s=$(date -u +%s)
    u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
    echo $((u_s - now_s))
}

metric_has() {
    local p="$1" m="$2" count="$3"
    local sp sm
    sp="${p//[^A-Za-z0-9._/-]/_}"
    sm="${m//[^A-Za-z0-9._/-]/_}"
    grep -qE "fleet_seat_failure_ceiling_parked\\{provider=\"${sp}\",model=\"${sm}\"\\} ${count}\$" \
        "$SEAT_FAILURE_CEILING_PROM" 2>/dev/null
}

ceil="${SEAT_FAILURE_CEILING}"
park="${SEAT_PARK_WALL_S}"

# --- (1) below the ceiling: base backoff holds, no park, no metric ---------
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
seed_ledger "$p" "$m" $((ceil - 2)) "transient_fault"
mark_seat_spawn_fail "$p" "$m" "test:below" >/dev/null 2>&1 || fail "mark_seat_spawn_fail below-ceiling failed"
c=$(jq -r '.consecutive_failure_count' "$lf")
[[ "$c" == $((ceil - 1)) ]] || fail "count below ceiling = $c, want $((ceil - 1))"
w=$(wall_s_of "$lf")
# spawn-fail base=300, escalated by count (~cap 3600) but NOT parked.
(( w < park )) || fail "below-ceiling wall = ${w}s, should be < park ${park}s (no park yet)"
! _seat_parked_by_ceiling "$c" || fail "below-ceiling count $c should NOT be parked"
[[ ! -f "$SEAT_FAILURE_CEILING_PROM" ]] || ! metric_has "$p" "$m" "$c" \
    || fail "below-ceiling seat should NOT emit a park metric"
ok "below ceiling (count=$c): base backoff ${w}s holds, no park, no metric"

# --- (2) crossing the ceiling: all five marker types park + emit metric -----
# Use a fresh seat per marker so each starts from count = ceiling-1.
run_park_case() {
    local label="$1" p="$2" m="$3" marker_fn="$4" field="${5:-usable_at}"
    local lf
    lf=$(ledger_file "$p" "$m")
    rm -f "$lf"
    seed_ledger "$p" "$m" $((ceil - 1)) "transient_fault"
    "$marker_fn" "$p" "$m" "test:cross:${label}" >/dev/null 2>&1 \
        || fail "$marker_fn crossing ceiling failed"
    local c w
    c=$(jq -r '.consecutive_failure_count' "$lf")
    [[ "$c" == "$ceil" ]] || fail "$label count = $c, want $ceil"
    w=$(wall_s_of "$lf" "$field")
    (( w >= park - 120 && w <= park + 120 )) \
        || fail "$label wall = ${w}s, want ~${park}s (parked)"
    _seat_parked_by_ceiling "$c" || fail "$label count $c should be parked"
    metric_has "$p" "$m" "$c" || fail "$label metric NOT emitted for $p/$m"
    # seat_usable must hold the parked seat.
    if seat_usable "$p" "$m"; then
        fail "$label: seat_usable returned usable on a freshly-parked seat"
    fi
    ok "$label: $p/$m parked at count=$c, wall=${w}s, metric emitted, seat_usable holds"
}

run_park_case "spawn-fail"   "devin"    "glm-5-2"                       mark_seat_spawn_fail
run_park_case "empty-run"    "devin"    "glm-5-2"                       mark_seat_empty_run
run_park_case "quota-bench"  "opencode" "mimo-v2.5-free"                mark_seat_quota_bench  bench_until
run_park_case "overload-bench" "opencode" "muse-spark-1.2-contributor-free" mark_seat_overload_bench bench_until
run_park_case "hang-bench"   "devin"    "glm-5-2"                       mark_seat_hang_bench   bench_until

# --- (3) already past the ceiling (live 72/64/63 state): parked on next fail
# The ceiling is >=, so a seat already at 72 is parked immediately when its
# next failure lands — it does NOT have to climb from 0 to 60 again.
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
rm -f "$lf"
seed_ledger "$p" "$m" 72 "quota_bench"
mark_seat_quota_bench "$p" "$m" "test:live:72" >/dev/null 2>&1 \
    || fail "mark_seat_quota_bench on live-72 seat failed"
c=$(jq -r '.consecutive_failure_count' "$lf")
[[ "$c" == "73" ]] || fail "live-72 count = $c, want 73"
w=$(wall_s_of "$lf" bench_until)
(( w >= park - 120 && w <= park + 120 )) \
    || fail "live-72 wall = ${w}s, want ~${park}s (parked on next fail)"
metric_has "$p" "$m" "$c" || fail "live-72 metric NOT emitted"
ok "live state (72 -> 73): parked on next failure, wall=${w}s, metric emitted"

# --- (4) metric file merges multiple parked seats (no clobber) -------------
# After (2) and (3) several seats are parked; the prom file must carry a line
# for each without one clobbering another.
lines=$(grep -cE '^fleet_seat_failure_ceiling_parked' "$SEAT_FAILURE_CEILING_PROM" 2>/dev/null || echo 0)
(( lines >= 3 )) \
    || fail "metric file has $lines park lines, want >=3 (merge broken; seats clobbered)"
ok "metric file merges $lines parked seats (no clobber)"

# --- (5) fail-open: after the park wall expires the seat is usable again ---
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
# Force the park wall into the past.
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" --arg b "$past_iso" '.usable_at = $u | .bench_until = $b' "$lf" >"$tmp" 2>/dev/null \
    && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "seat_usable returned unusable after park wall expired — fail-open is broken (recovered seat walled)"
fi
ok "expired park wall fail-opens — a recovered seat is re-eligible (park is a cooldown, not a permanent wall)"

ok "seat failure ceiling: parks past 60 consecutive failures, emits one metric, fail-opens on recovery"
