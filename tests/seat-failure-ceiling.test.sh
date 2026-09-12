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
#   (6) fleet-ops#2288 read-side park: an EXTENSION-WRITTEN transient_fault
#       ledger (flat usable_at window, no bash marker) past the ceiling is
#       not re-offered on the flat cadence — seat_usable holds it behind the
#       long wall anchored at observed_at, then fail-opens after the wall
#       (even while the ledger is still fresh). This is the fence that would
#       have stopped the live opencode/muse-spark-1.2-contributor-free
#       re-offer loop (149 straight HTTP 500s) from a stale pre-fix ledger.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-failure-ceiling.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
# fleet-ops#4217: hermetic live-quota lookup — real fleet_seat_quota_* rows in
# the VPS node_exporter textfile must not leak into the wall-escalation tests.
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"

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
# Use a small ceiling so the test does not need 60 iterations to cross it.
export SEAT_FAILURE_CEILING=60
export SEAT_PARK_WALL_S=86400
# fleet-ops#3941: the park wall ESCALATES with the count past the ceiling.
# Pin the cap high so the escalation is not truncated in this test and the
# assertions below can check the exact escalated wall.
export SEAT_PARK_WALL_MAX_S=999999999
# Disable the corpse reclassification threshold (fleet-ops#2594) so this test
# proves the parking behaviour in isolation. The quota_bench case seeds
# count=59 -> 60 which would otherwise trip the corpse branch (default 25)
# and clear bench_until, breaking the wall assertion. The corpse path is
# covered by tests/seat-quota-corpse.test.sh.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
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

marker_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.spawn-bench.json' "$LEDGER" \
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
mf=$(marker_file "$p" "$m")
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
    local case_ceil="${6:-$ceil}"
    local lf mf
    lf=$(ledger_file "$p" "$m")
    mf=$(marker_file "$p" "$m")
    rm -f "$lf" "$mf"
    seed_ledger "$p" "$m" $((case_ceil - 1)) "transient_fault"
    "$marker_fn" "$p" "$m" "test:cross:${label}" >/dev/null 2>&1 \
        || fail "$marker_fn crossing ceiling failed"
    local c w
    c=$(jq -r '.consecutive_failure_count' "$lf")
    [[ "$c" == "$case_ceil" ]] || fail "$label count = $c, want $case_ceil"
    w=$(wall_s_of "$lf" "$field")
    # fleet-ops#4640: writers clamp non-money parks at 6h.
    (( w >= 21600 - 120 && w <= 21600 + 120 )) \
        || fail "$label wall = ${w}s, want ~21600s (6h clamp, fleet-ops#4640)"
    _seat_parked_by_ceiling "$c" "$case_ceil" || fail "$label count $c should be parked"
    metric_has "$p" "$m" "$c" || fail "$label metric NOT emitted for $p/$m"
    # seat_usable must hold the parked seat.
    if seat_usable "$p" "$m"; then
        fail "$label: seat_usable returned usable on a freshly-parked seat"
    fi
    ok "$label: $p/$m parked at count=$c, wall=${w}s, metric emitted, seat_usable holds"
}

run_park_case "spawn-fail"   "devin"    "glm-5-2"                       mark_seat_spawn_fail
run_park_case "empty-run"    "devin"    "glm-5-2"                       mark_seat_empty_run "" "${EMPTY_RUN_FAILURE_CEILING:-3}"
run_park_case "quota-bench"  "opencode" "mimo-v2.5-free"                mark_seat_quota_bench  bench_until
run_park_case "overload-bench" "opencode" "muse-spark-1.2-contributor-free" mark_seat_overload_bench bench_until
run_park_case "hang-bench"   "devin"    "glm-5-2"                       mark_seat_hang_bench   bench_until

# --- (3) already past the ceiling (live 72/64/63 state): parked on next fail
# The ceiling is >=, so a seat already at 72 is parked immediately when its
# next failure lands — it does NOT have to climb from 0 to 60 again.
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 72 "quota_bench"
mark_seat_quota_bench "$p" "$m" "test:live:72" >/dev/null 2>&1 \
    || fail "mark_seat_quota_bench on live-72 seat failed"
c=$(jq -r '.consecutive_failure_count' "$lf")
[[ "$c" == "73" ]] || fail "live-72 count = $c, want 73"
w=$(wall_s_of "$lf" bench_until)
# fleet-ops#4640: non-money quota park is clamped at 6h even when the
# ceiling formula escalates past that.
(( w >= 21600 - 120 && w <= 21600 + 120 )) \
    || fail "live-72 wall = ${w}s, want ~21600s (6h clamp, fleet-ops#4640)"
metric_has "$p" "$m" "$c" || fail "live-72 metric NOT emitted"
ok "live state (72 -> 73): parked on next failure, wall=${w}s (escalated), metric emitted"

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
mf=$(marker_file "$p" "$m")
# Force the park wall into the past.
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" --arg b "$past_iso" '.usable_at = $u | .bench_until = $b' "$lf" >"$tmp" 2>/dev/null \
    && mv "$tmp" "$lf"
# fleet-ops#1512: the bench now also lives in the clobber-proof spawn-bench
# marker, so age that surface too (in production real time passing ages both).
sb_marker="$LEDGER/${p//[^A-Za-z0-9._-]/_}__${m//[^A-Za-z0-9._-]/_}.spawn-bench.json"
if [[ -f "$sb_marker" ]]; then
    tmp=$(mktemp)
    jq --arg u "$past_iso" '.usable_at = $u' "$sb_marker" >"$tmp" 2>/dev/null && mv "$tmp" "$sb_marker"
fi
if ! seat_usable "$p" "$m"; then
    fail "seat_usable returned unusable after park wall expired — fail-open is broken (recovered seat walled)"
fi
ok "expired park wall fail-opens — a recovered seat is re-eligible (park is a cooldown, not a permanent wall)"

# --- (6) fleet-ops#2288 read-side park for extension-written transient_fault -
# The extension (seat-health.ts) writes transient_fault markers with a FLAT
# usable_at window; the write-side escalation lives in that out-of-repo file.
# This is the in-repo fence: seat_usable itself holds a transient_fault ledger
# past SEAT_FAILURE_CEILING behind the long wall anchored at observed_at, so
# even a stale/pre-fix ledger (the live muse-spark c=149 state) is never
# re-offered on the flat 30s cadence. Cases:
#   6a live replay: c=149 transient_fault, fresh -> parked (unusable)
#   6b below the ceiling (c=59) -> usable
#   6c stale observed (past the park wall too) -> usable (fail-open)
#   6d short wall, observed OLDER than the wall (still fresh) -> usable
#      (the park branch itself fail-opens, not the stale branch)
#   6e short wall, observed NEWER than the wall -> parked
#   6f healthy ledger with a high count (extension reset) -> usable
p="opencode"; m="muse-spark-1.2-contributor-free"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# 6a: the exact live snapshot shape (c=149, transient_fault, fresh).
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 149 "transient_fault"
if seat_usable "$p" "$m"; then
    fail "6a: seat_usable returned USABLE for a c=149 transient_fault ledger (read-side park missing)"
fi
ok "6a: c=149 transient_fault ledger is parked (read-side long wall holds)"

# 6b: one below the ceiling is not parked (flat behaviour unchanged).
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" $((ceil - 1)) "transient_fault"
if ! seat_usable "$p" "$m"; then
    fail "6b: seat_usable parked a c=$((ceil - 1)) transient_fault ledger (must stay below the ceiling)"
fi
ok "6b: c=$((ceil - 1)) transient_fault ledger is usable (below the ceiling, no park)"

# 6c: observed past the ESCALATED park wall fail-opens (one probe per wall,
# not forever). c=149, ceiling=60 -> wall = _park_wall_s 149 = 90 days.
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 149 "transient_fault"
_6c_wall=$(_park_wall_s 149)
old_iso=$(date -u -d '@'$(( $(date -u +%s) - _6c_wall - 3600 ))' ' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
tmp="$scratch/6c.json"
jq --arg o "$old_iso" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "6c: seat_usable held a c=149 transient_fault ledger past the escalated park wall — fail-open broken"
fi
ok "6c: observed past the escalated park wall fail-opens (one probe per wall, not forever)"

# 6d/6e: short park wall to prove the PARK branch fail-opens on its own clock
# (observed still fresh) and holds when the wall has not elapsed.
export SEAT_PARK_WALL_S=30
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 149 "transient_fault"
# c=149, ceiling=60 -> escalated wall = 90 * 30 = 2700s. Age observed past
# the escalated wall (3000s) but keep it fresh (<6h) to prove the PARK
# branch fail-opens on its own clock, not the stale branch.
mid_iso=$(date -u -d '@'$(( $(date -u +%s) - 3000 ))' ' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
tmp="$scratch/6d.json"
jq --arg o "$mid_iso" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "6d: park branch did not fail-open after the escalated short wall elapsed (fresh observed)"
fi
ok "6d: escalated short wall elapsed while observed fresh -> usable (park branch fail-open)"

rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 149 "transient_fault"
# observed 10s ago: fresh and inside the 30s wall.
now_iso=$(date -u -d '@'$(( $(date -u +%s) - 10 ))' ' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
tmp="$scratch/6e.json"
jq --arg o "$now_iso" '.observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if seat_usable "$p" "$m"; then
    fail "6e: short wall active (observed 10s ago) should be parked"
fi
ok "6e: inside the park wall -> parked even with a flat usable_at"
export SEAT_PARK_WALL_S=86400

# 6f: a healthy ledger with a high count (the extension's reset shape) is usable.
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 149 "healthy"
if ! seat_usable "$p" "$m"; then
    fail "6f: healthy ledger with high count must not park (count resets on success)"
fi
ok "6f: healthy ledger is usable regardless of count (recovered seat re-eligible)"

# --- (7) fleet-ops#3586 read-side escalation for rate_limited seats --------
# The live 2026-09-05 snapshot that filed the issue: three xkiro seats stuck
# at 48-63 consecutive http 429 (rate_limited) with usable_at ~15min out,
# re-probed and re-walled every cycle so the count kept climbing and never
# escalated. A 429 that has not cleared in 20+ re-wall cycles is not a
# transient rate limit — it is an unusable seat. seat_usable now feeds
# rate_limited through the SAME read-side park fence as transient_fault
# (fleet-ops#2288): past SEAT_FAILURE_CEILING consecutive failures it is held
# behind the long wall anchored at observed_at instead of the endless
# 15-min re-wall loop.
# This section proves the escalation FIRES on the three live seat ids from
# the snapshot, at the production threshold the issue quotes (N>=20).
# Cases:
#   7a xkiro/deepseek-v4-flash c=63 rate_limited, fresh -> parked
#   7b xkiro/deepseek-v4-pro     c=52 rate_limited, fresh -> parked
#   7c xkiro/minimax-m3:free     c=48 rate_limited, fresh -> parked
#   7d below the ceiling (c=19, N<20) -> NOT parked: the flat usable_at
#      window is still honoured (a <20-count 429 remains a transient rate
#      limit), never re-offered ahead of its own reset.
# Isolate this section at the production default the issue quotes (N>=20);
# the test body above pins 60 for its write-side replay isolation.
export SEAT_FAILURE_CEILING=20
# Fresh observed marker helper: the live shape carried usable_at ~15min out
# AND a climbing count, so seed the ledgers with the reset window too.
seed_rate_limited_ledger() {
    local p="$1" m="$2" count="$3"
    local lf use
    lf=$(ledger_file "$p" "$m")
    use=$(date -u -d "@$(( $(date -u +%s) + 900 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg observed "$now_utc" --arg use "$use" \
        --argjson count "$count" \
        '{provider:$provider,model:$model,http_status:429,retry_after:900,
          health_class:"rate_limited",seat_dead:false,poison_ladder:false,retryable:true,
          observed_at:$observed,usable_at:$use,consecutive_failure_count:$count}' \
        >"$lf" 2>/dev/null || fail "seed_rate_limited_ledger jq failed"
}
# 7a: xkiro/deepseek-v4-flash c=63 — the worst seat in the snapshot.
p="xkiro"; m="deepseek-v4-flash"
lf=$(ledger_file "$p" "$m"); mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_rate_limited_ledger "$p" "$m" 63
if seat_usable "$p" "$m"; then
    fail "7a: seat_usable returned USABLE for xkiro/deepseek-v4-flash c=63 rate_limited (escalation to long wall missing)"
fi
grep -q "UNUSABLE (rate_limited count=63 >= 20, parked until" "$PI_PACKET_STATE/watch.log" \
    || fail "7a: must log the long-wall park for xkiro/deepseek-v4-flash c=63 (got: $(grep -c 'rate_limited' "$PI_PACKET_STATE/watch.log" 2>/dev/null || echo 0) rate_limited lines)"
ok "7a: xkiro/deepseek-v4-flash c=63 rate_limited -> parked behind the long wall (fires)"
# 7b: xkiro/deepseek-v4-pro c=52.
p="xkiro"; m="deepseek-v4-pro"
lf=$(ledger_file "$p" "$m"); mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_rate_limited_ledger "$p" "$m" 52
if seat_usable "$p" "$m"; then
    fail "7b: seat_usable returned USABLE for xkiro/deepseek-v4-pro c=52 rate_limited (escalation missing)"
fi
grep -q "UNUSABLE (rate_limited count=52 >= 20, parked until" "$PI_PACKET_STATE/watch.log" \
    || fail "7b: must log the long-wall park for xkiro/deepseek-v4-pro c=52"
ok "7b: xkiro/deepseek-v4-pro c=52 rate_limited -> parked (fires)"
# 7c: xkiro/minimax-m3:free c=48.
p="xkiro"; m="minimax-m3:free"
lf=$(ledger_file "$p" "$m"); mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_rate_limited_ledger "$p" "$m" 48
if seat_usable "$p" "$m"; then
    fail "7c: seat_usable returned USABLE for xkiro/minimax-m3:free c=48 rate_limited (escalation missing)"
fi
grep -q "UNUSABLE (rate_limited count=48 >= 20, parked until" "$PI_PACKET_STATE/watch.log" \
    || fail "7c: must log the long-wall park for xkiro/minimax-m3:free c=48"
ok "7c: xkiro/minimax-m3:free c=48 rate_limited -> parked (fires)"
# 7d: below N>=20 (c=19) is NOT parked — the flat usable_at window is still
# honoured by the rate_limited branch (a sub-ceiling 429 is still transient),
# so the escalation is scoped to chronically-failing seats only.
p="xkiro"; m="deepseek-v4-flash"
lf=$(ledger_file "$p" "$m"); mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_rate_limited_ledger "$p" "$m" 19
if seat_usable "$p" "$m"; then
    fail "7d: below-ceiling rate_limited c=19 must remain excluded by the flat usable_at window, not parked (park branch leaked below N>=20)"
fi
grep -q "UNUSABLE (rate_limited until" "$PI_PACKET_STATE/watch.log" \
    || fail "7d: below-ceiling rate_limited seat must hit the flat usable_at branch (rate_limited until ...), not the park branch"
if grep -q "rate_limited count=19 >= 20, parked until" "$PI_PACKET_STATE/watch.log"; then
    fail "7d: park branch fired below the N>=20 ceiling — escalation must not trigger on c=19"
fi
ok "7d: below-ceiling rate_limited c=19 stays on the flat usable_at window (no escalation below N>=20)"
export SEAT_FAILURE_CEILING=60

# --- (8) fleet-ops#3941: the park wall ESCALATES with the count -----------
# The live snapshot that filed the issue: xkiro/deepseek-v4-flash at 47
# consecutive spawn_fail was re-offered every 24h park-wall expiry and
# re-walled at the SAME 24h — the wall never grew, so a chronically-dead
# seat was probed once per day forever. This section proves the wall now
# GROWS with the count past the ceiling (one SEAT_PARK_WALL_S per failure)
# and is capped at SEAT_PARK_WALL_MAX_S, on both the write side
# (_failure_ceiling_wall) and the read side (seat_usable's park fence).
export SEAT_FAILURE_CEILING=20
export SEAT_PARK_WALL_S=86400
export SEAT_PARK_WALL_MAX_S=604800  # 7 days — the production cap
# 8a: write-side escalation ladder (count -> wall).
[[ "$(_park_wall_s 20)" == "86400" ]]   || fail "8a: count=20 (==ceil) wall=$(_park_wall_s 20), want 86400 (first park)"
[[ "$(_park_wall_s 21)" == "172800" ]] || fail "8a: count=21 wall=$(_park_wall_s 21), want 172800 (2x park)"
[[ "$(_park_wall_s 22)" == "259200" ]] || fail "8a: count=22 wall=$(_park_wall_s 22), want 259200 (3x park)"
[[ "$(_park_wall_s 47)" == "604800" ]] || fail "8a: count=47 wall=$(_park_wall_s 47), want 604800 (capped at 7 days)"
[[ "$(_park_wall_s 19)" == "0" ]]      || fail "8a: count=19 (below ceil) wall=$(_park_wall_s 19), want 0 (not parked)"
ok "8a: write-side park wall escalates with count past the ceiling, capped at SEAT_PARK_WALL_MAX_S"
# 8b: _failure_ceiling_wall routes a parked count through the escalation.
[[ "$(_failure_ceiling_wall 21 300)" == "172800" ]] \
    || fail "8b: _failure_ceiling_wall(21,300)=$(_failure_ceiling_wall 21 300), want 172800 (escalated park)"
[[ "$(_failure_ceiling_wall 19 300)" == "300" ]] \
    || fail "8b: _failure_ceiling_wall(19,300)=$(_failure_ceiling_wall 19 300), want 300 (base backoff below ceiling)"
ok "8b: _failure_ceiling_wall escalates a parked count, keeps the base backoff below the ceiling"
# 8c: read-side park (seat_usable) escalates with the count too — a
# transient_fault ledger at c=47 is held behind the escalated wall, not the
# flat 24h. Seed c=47 fresh; the park fence must hold it (unusable).
p="xkiro"; m="deepseek-v4-flash"
lf=$(ledger_file "$p" "$m"); mf=$(marker_file "$p" "$m")
rm -f "$lf" "$mf"
seed_ledger "$p" "$m" 47 "transient_fault"
if seat_usable "$p" "$m"; then
    fail "8c: seat_usable returned USABLE for xkiro/deepseek-v4-flash c=47 transient_fault (read-side escalation missing)"
fi
grep -q "UNUSABLE (transient_fault count=47 >= 20, parked until" "$PI_PACKET_STATE/watch.log" \
    || fail "8c: must log the escalated long-wall park for xkiro/deepseek-v4-flash c=47"
ok "8c: xkiro/deepseek-v4-flash c=47 transient_fault -> parked behind the escalated long wall (read side)"
export SEAT_FAILURE_CEILING=60

ok "seat failure ceiling: parks past SEAT_FAILURE_CEILING consecutive failures (default 20 since fleet-ops#2594, this test pins 60 for isolation), emits one metric, fail-opens on recovery, fleet-ops#3586 rate_limited escalation proves on the three live xkiro seats, fleet-ops#3941 park-wall escalation proves on the write and read sides"
