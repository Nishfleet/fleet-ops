#!/usr/bin/env bash
# tests/seat-empty-run-sticky-floor.test.sh
#
# fleet-ops#3781: the empty-run bench is STICKY. A seat with repeated
# stdout=0B (a provider no-op: pi exits 0 with 0-byte stdout, http 200,
# ledger healthy) must not be re-offered to work items within the same 2h
# window the fleet measures churn in. Live 2026-09-06 snapshot:
# waste.empty_runs_last_2h doubled 9 -> 18, and ollama/deepseek-v4-flash:0731
# was re-benched 4x in 2h (900s -> 1800s -> 14400s -> 7200s) — the geometric
# cooldown kept expiring and each re-offer burned a pi-issue attempt.
#
# The geometric ladder (fleet-ops#3531) grows 900 -> 1800 -> 3600 -> 7200s on
# counts 1-4, so a repeat no-op'er re-enters rotation inside the 2h window up
# to the 4th no-op before the 24h park (count >= EMPTY_RUN_FAILURE_CEILING)
# ever engages. This test pins the sticky-floor contract that closes that
# gap: once a seat has REPEATED no-ops (merged_count >=
# EMPTY_RUN_STICKY_MIN_COUNT, default 3) its bench floors at
# EMPTY_RUN_STICKY_FLOOR_S (default 7200s = the 2h observation window) so it
# is not re-offered within the window. The first two no-ops keep their short
# geometric cooldowns (900s / 1800s) so a transient no-op'er gets two chances
# to recover (fleet-ops#2343: a single flake does not wall a seat); the 24h
# failure-ceiling park still wins on top of the floor.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness shape of tests/seat-empty-run-ceiling-default.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-sticky-floor.XXXXXX)"
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
export PI_SEAT_CREDENTIAL_PRECHECK=0
# Keep the 24h park from firing inside this test: EMPTY_RUN_FAILURE_CEILING
# stays at its production default 5, so the 3rd no-op that this test isolates
# is BELOW the ceiling and must NOT park — the sticky floor is what holds it.
export EMPTY_RUN_FAILURE_CEILING=5
export SEAT_FAILURE_CEILING=20
export SEAT_PARK_WALL_S=86400
export EMPTY_RUN_MARKER_FRESH_S=1800
export EMPTY_RUN_COUNT_WINDOW_S=7200
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

# Two free seats on one provider so pick_seat reroutes off the stuck bench.
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "nemotron-3-ultra-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "muse-spark-1.2-contributor-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": { "cap": 6, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "nemotron-3-ultra-free": 3, "muse-spark-1.2-contributor-free": 3 } }
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

p="opencode"; m="nemotron-3-ultra-free"
other_m="muse-spark-1.2-contributor-free"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")
other_lf=$(ledger_file "$p" "$other_m")
other_mf=$(marker_file "$p" "$other_m")
rm -f "$lf" "$mf" "$other_lf" "$other_mf"
# Seed a healthy companion so pick_seat has somewhere to reroute.
clobber_with_healthy "$p" "$other_m" "$other_lf"

# --- (a) 1st no-op: base 900s cooldown, NOT floored ------------------------
mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3781:noop:1" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #1 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(a) marker count after 1st no-op = $(count_of "$mf"), want 1"
w1=$(wall_s_of_marker "$mf")
(( w1 >= 900 - 120 && w1 <= 900 + 120 )) \
    || fail "(a) 1st no-op wall = ${w1}s, want ~900s (base cooldown, count=1 < sticky min 3 — a transient hiccup is not walled)"
ok "(a) 1st no-op: count=1, ~900s cooldown (not floored — a single flake is not walled)"

# --- (b) 2nd no-op: geometric 1800s, NOT floored -----------------------------
mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3781:noop:2" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #2 failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "2" ]] \
    || fail "(b) marker count after 2nd no-op = $(count_of "$mf"), want 2"
w2=$(wall_s_of_marker "$mf")
(( w2 >= 1800 - 120 && w2 <= 1800 + 120 )) \
    || fail "(b) 2nd no-op wall = ${w2}s, want ~1800s (geometric cooldown, count=2 < sticky min 3 — one repeat is still a recoverable flake)"
ok "(b) 2nd no-op: count=2, ~1800s cooldown (not floored — two chances to recover, fleet-ops#2343)"

# --- (c) 3rd no-op: STICKY FLOOR engages at ~7200s (the 2h window) ----------
# The 3rd no-op is unambiguous chronic churn. The geometric ladder alone would
# bench 3600s (still inside the 2h window); the sticky floor raises it to the
# full 2h window so the seat is not re-offered within it. count=3 is below
# EMPTY_RUN_FAILURE_CEILING=5, so the 24h park must NOT fire here — isolating
# the floor from the ceiling.
mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3781:noop:3" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run #3 (sticky floor) failed"
[[ "$(count_of "$mf")" == "3" ]] \
    || fail "(c) marker count after 3rd no-op = $(count_of "$mf"), want 3"
w3=$(wall_s_of_marker "$mf")
(( w3 >= 7200 - 120 && w3 <= 7200 + 120 )) \
    || fail "(c) 3rd no-op wall = ${w3}s, want ~7200s (sticky floor = 2h observation window; geometric alone would be 3600s — a repeat no-op'er must not be re-offered within the window, fleet-ops#3781)"
ok "(c) 3rd no-op: count=3, bench floored to ~7200s (the 2h observation window) — repeat no-op'er is not re-offered within the window"

# --- (d) seat_usable holds the floored seat out of rotation -----------------
if seat_usable "$p" "$m"; then
    fail "(d) seat_usable returned usable on the 3rd-no-op floored seat — the 2h sticky floor must hold the seat out of rotation (fleet-ops#3781)"
fi
ok "(d) seat_usable holds the 3rd-no-op seat UNUSABLE for the 2h sticky floor — not re-offered within the window"

# --- (e) pick_seat never returns the floored seat (reroutes to companion) ---
saw_stuck=0
for i in 1 2 3 4 5; do
    : >"$STATE_DIR/attempts/pi-issue-fleet-ops-3781.tried-seats" 2>/dev/null || true
    picked=$(pick_seat "" "" 0 "" "light" "public" || true)
    [[ -n "$picked" ]] || fail "(e) pick_seat returned empty (iteration $i) — no reroute target available"
    picked_p=$(printf '%s' "$picked" | cut -f1)
    picked_m=$(printf '%s' "$picked" | cut -f2)
    if [[ "$picked_p/$picked_m" == "$p/$m" ]]; then
        saw_stuck=1
        break
    fi
    [[ "$picked_p/$picked_m" == "$p/$other_m" ]] \
        || fail "(e) pick_seat rerouted to unexpected $picked_p/$picked_m (expected $p/$other_m)"
done
[[ "$saw_stuck" == "1" ]] \
    && fail "(e) pick_seat returned the 2h-floored seat — the sticky floor did NOT hold it out of rotation (fleet-ops#3781)"
ok "(e) pick_seat never returns the 2h-floored seat across 5 work-item picks — it reroutes to a healthy companion"

# --- (f) the 24h failure-ceiling park still wins on top of the floor --------
# The floor must not blunt the park: once a chronic no-op'er reaches
# EMPTY_RUN_FAILURE_CEILING (5), the wall is 24h, not the 7200s floor.
for i in 4 5; do
    mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3781:noop:${i}" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run #${i} (park) failed"
done
[[ "$(count_of "$mf")" == "5" ]] \
    || fail "(f) marker count after 5th no-op = $(count_of "$mf"), want 5"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= SEAT_PARK_WALL_S - 120 && park_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(f) park wall = ${park_wall}s, want ~${SEAT_PARK_WALL_S}s — the 24h failure-ceiling park must win over the 2h sticky floor (fleet-ops#3727)"
ok "(f) 5th no-op: park wall = ~24h (count=5 >= EMPTY_RUN_FAILURE_CEILING) — the floor does not blunt the park"

ok "fleet-ops#3781: the empty-run bench is sticky — a seat with repeated stdout=0B (>= EMPTY_RUN_STICKY_MIN_COUNT no-ops) benches for the full 2h observation window and is not re-offered within it; a transient no-op'er keeps two short geometric cooldowns; the 24h park still wins above the floor"
