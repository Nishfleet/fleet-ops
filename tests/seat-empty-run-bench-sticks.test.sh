#!/usr/bin/env bash
# tests/seat-empty-run-bench-sticks.test.sh
#
# fleet-ops#3602: an empty-run bench must SURVIVE a subsequent successful
# (HTTP 200) probe until its wall_end, and a seat with an unexpired empty-run
# bench can NEVER be returned by pick-seat.
#
# Incident 2026-09-05T11:30:03Z: ollama/deepseek-v4-flash:0731 was re-benched
# 8x in 2h (count=6,7,8 at 09:33/09:37/09:47Z, backoff=86400s) yet the
# seat-health sidecar still showed health_class=healthy / http 200 /
# consecutive_failure_count=0 at 11:30:02Z — the seat kept re-entering
# rotation and burning issues on guaranteed no-ops. The clobber-proof
# spawn-bench marker (fleet-ops#1512) is the survival mechanism: seat_usable
# checks it BEFORE the ledger, so a healthy ledger clobber does not re-admit
# the seat. This test proves the contract end-to-end through pick-seat (not
# just seat_usable), which is the routing authority that hands seats to
# workers.
#
# This test proves:
#   (1) After ONE empty run (mark_seat_empty_run), pick-seat with empty
#       tried-seats (the intake re-spawn case) NEVER returns the benched
#       seat — it reroutes to a healthy seat. (the "replay showing the seat
#       excluded after one empty run" the issue asks for)
#   (2) After a healthy 200-probe clobbers the ledger to
#       health_class=healthy / count=0 / usable_at=null (exactly what
#       seat-health.ts writes on a later simple packet's 200), pick-seat
#       STILL never returns the benched seat — the spawn-bench marker holds
#       the bench until wall_end.
#   (3) After the marker's wall_end passes, a FRESH marker that is still
#       the seat's latest evidence is held for pick-seat (probe-gated
#       re-admission, fleet-ops#3737 — a dead-weight seat never costs a work
#       item a turn); a POST-bench healthy observation (real recovery) or
#       marker age >24h releases the hold so a recovered seat is never
#       walled permanently. This is the probe-gated successor to the old
#       clock-gated fail-open (#3737 supersedes the naive wall_end
#       re-admission #3602 step (3) asserted).
#   (4) The marker write is NOT best-effort: if the spawn-bench marker
#       cannot be written, mark_seat_empty_run fails loud (returns 1) so
#       the bench is never silently lost to a clobberable ledger.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-bench-sticks.XXXXXX)"
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
# Credential precheck off: test fixtures have no apiKey; the reactive ledger
# is the backstop (same as the rest of the seatlib test suite).
export PI_SEAT_CREDENTIAL_PRECHECK=0
mkdir -p "$XDG_RUNTIME_DIR"

# Two seats on one provider so pick-seat has somewhere to reroute after the
# empty-run seat is benched. Both are free-class (no privacy gate), cap 4.
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 128000 },
        { "id": "qwen3:32b", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 128000 }
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
    "ollama": { "cap": 4, "class": "free", "models": { "deepseek-v4-flash:0731": 4, "qwen3:32b": 4 } }
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

# Simulate seat-health.ts writing a healthy HTTP-200 observation to the
# per-seat ledger (the clobber that re-admits a benched seat when there is no
# clobber-proof marker). This is exactly writeSeatLedgerEntry on an
# after_provider_response 200 with a non-empty body: health_class flips to
# "healthy", usable_at to null, consecutive_failure_count to 0.
clobber_with_healthy_200() {
    local p="$1" m="$2" lf="$3"
    local now_utc tmp
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp="$lf.clobber.$$.$RANDOM.tmp"
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

bench_p="ollama"
bench_m="deepseek-v4-flash:0731"
other_m="qwen3:32b"
bench_lf=$(ledger_file "$bench_p" "$bench_m")
bench_mf=$(marker_file "$bench_p" "$bench_m")
other_lf=$(ledger_file "$bench_p" "$other_m")
other_mf=$(marker_file "$bench_p" "$other_m")

# Helper: assert pick-seat never returns the benched seat. Runs pick-seat
# several times (the intake re-spawn case: empty tried-seats each call) and
# fails if the benched seat is ever selected.
assert_pick_skips_benched() {
    local label="$1" expect_other="${2:-1}"
    local i picked_p picked_m
    for i in 1 2 3 4 5; do
        # Empty tried-seats = a fresh intake re-spawn (the exact path that
        # re-picked the no-op'ing ollama seat 8x in 2h, fleet-ops#3602).
        : >"$STATE_DIR/attempts/pi-issue-fleet-ops-3602.tried-seats" 2>/dev/null || true
        picked=$(pick-seat "" "" 0 "" "light" "public" || true)
        [[ -n "$picked" ]] || fail "$label: pick-seat returned empty (iteration $i)"
        picked_p=$(printf '%s' "$picked" | cut -f1)
        picked_m=$(printf '%s' "$picked" | cut -f2)
        if [[ "$picked_p/$picked_m" == "$bench_p/$bench_m" ]]; then
            fail "$label: pick-seat returned the benched seat $bench_p/$bench_m on iteration $i — empty-run bench did NOT survive (fleet-ops#3602)"
        fi
        if [[ "$expect_other" == "1" ]]; then
            [[ "$picked_p/$picked_m" == "$bench_p/$other_m" ]] \
              || fail "$label: pick-seat rerouted to $picked_p/$picked_m, expected $bench_p/$other_m"
        fi
    done
    ok "$label: pick-seat never returned the benched seat across 5 intake re-spawns"
}

# --- (1) ONE empty run -> pick-seat excludes the seat (the replay) ---------
rm -f "$LEDGER"/*.json "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
# Seed the other seat healthy so pick-seat has somewhere to reroute.
clobber_with_healthy_200 "$bench_p" "$other_m" "$other_lf"
# ONE empty run on the bench seat.
mark_seat_empty_run "$bench_p" "$bench_m" "test:empty-run:tools=0" >/dev/null 2>&1 \
  || fail "mark_seat_empty_run failed for $bench_p/$bench_m"
[[ -f "$bench_mf" ]] \
  || fail "empty-run did not write the clobber-proof spawn-bench marker at $bench_mf"
marker_usable=$(jq -r '.usable_at // ""' "$bench_mf")
[[ -n "$marker_usable" ]] || fail "spawn-bench marker has no usable_at"
# The ledger was also written (transient_fault / empty_run); seat_usable would
# block even without the marker. The real test is AFTER the clobber below.
assert_pick_skips_benched "(1) after one empty run (ledger+marker)"
ok "(1) replay: one empty run excludes the seat from pick-seat (fleet-ops#3602)"

# --- (2) healthy 200-probe clobber -> pick-seat STILL excludes the seat ----
# This is the core fleet-ops#3602 regression: a later simple packet's 200
# clobbers the ledger to healthy (count=0, usable_at=null). Before the
# clobber-proof marker, pick-seat re-admitted the seat and burned 8 runs/2h.
clobber_with_healthy_200 "$bench_p" "$bench_m" "$bench_lf"
ledger_hc=$(jq -r '.health_class' "$bench_lf")
[[ "$ledger_hc" == "healthy" ]] \
  || fail "clobber did not flip ledger to healthy (hc=$ledger_hc)"
ledger_count=$(jq -r '.consecutive_failure_count // 0' "$bench_lf")
[[ "$ledger_count" == "0" ]] \
  || fail "clobber did not reset count to 0 (count=$ledger_count)"
# The marker must STILL be in the future (wall_end not reached).
_seat_in_future "$marker_usable" \
  || fail "spawn-bench marker usable_at ($marker_usable) is no longer in the future — wall_end passed mid-test"
assert_pick_skips_benched "(2) after healthy 200-probe clobber (marker held)"
ok "(2) empty-run bench SURVIVES a healthy 200-probe clobber — pick-seat still excludes the seat until wall_end (fleet-ops#3602)"

# --- (3) wall_end passes: fresh marker held as latest evidence (probe-gate) --
# fleet-ops#3737: an expired wrapper bench no longer fails open. While the
# marker is fresh (< EMPTY_RUN_COUNT_WINDOW_S) and still the seat's latest
# evidence, pick-seat holds it for the comeback organ's tool-using probe —
# so a dead-weight seat never costs a work item a turn. The clobber's
# healthy observed_at corresponds to the SAME run as the marker write (the
# mid-run 200 the extension logged during the empty run), so it is NOT
# post-bench recovery evidence; pin it to the marker's written_at.
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$bench_mf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_mf"
marker_written=$(jq -r '.written_at // ""' "$bench_mf")
[[ -n "$marker_written" ]] || fail "spawn-bench marker has no written_at"
tmp=$(mktemp)
jq --arg o "$marker_written" '.observed_at = $o' "$bench_lf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_lf"
assert_pick_skips_benched "(3) after wall_end, fresh expired marker held as latest evidence (probe-gated re-admission)"
ok "(3) expired fresh marker is held as latest evidence — probe-gated re-admission (fleet-ops#3737)"

# --- (3b) post-bench recovery observation releases the hold ----------------
# A ledger observation NEWER than the marker's written_at means a real run
# produced output after the bench — recovery evidence, so the seat is
# re-eligible (fail-open). The comeback organ's successful probe writes
# exactly this. It may or may not be picked first (free-bucket order), but
# it must NOT be excluded — at least one of the 5 picks must be the seat.
later_iso=$(date -u -d "@$(( $(date -u -d "$marker_written" +%s) + 120 ))" +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg o "$later_iso" '.observed_at = $o' "$bench_lf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_lf"
saw_bench=0
for i in 1 2 3 4 5; do
    : >"$STATE_DIR/attempts/pi-issue-fleet-ops-3602.tried-seats" 2>/dev/null || true
    picked=$(pick-seat "" "" 0 "" "light" "public" || true)
    [[ -n "$picked" ]] || fail "pick-seat returned empty after post-bench recovery (iter $i)"
    picked_p=$(printf '%s' "$picked" | cut -f1)
    picked_m=$(printf '%s' "$picked" | cut -f2)
    [[ "$picked_p/$picked_m" == "$bench_p/$bench_m" ]] && saw_bench=1
done
[[ "$saw_bench" == "1" ]] \
  || fail "pick-seat never returned the recovered seat after post-bench evidence — recovery release broken"
ok "(3b) post-bench healthy observation releases the hold — recovered seat re-eligible (not walled permanently)"

# --- (3c) archaeology: a stale marker (>24h) fail-opens --------------------
# A marker older than the count window is archaeology — fail-open so a
# stalled comeback organ cannot strand the seat forever.
old_iso=$(date -u -d "@$(( $(date -u +%s) - 90000 ))" +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
jq --arg w "$old_iso" '.written_at = $w' "$bench_mf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_mf"
tmp=$(mktemp)
jq --arg o "$old_iso" '.observed_at = $o' "$bench_lf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_lf"
saw_bench=0
for i in 1 2 3 4 5; do
    : >"$STATE_DIR/attempts/pi-issue-fleet-ops-3602.tried-seats" 2>/dev/null || true
    picked=$(pick-seat "" "" 0 "" "light" "public" || true)
    [[ -n "$picked" ]] || fail "pick-seat returned empty for stale marker (iter $i)"
    picked_p=$(printf '%s' "$picked" | cut -f1)
    picked_m=$(printf '%s' "$picked" | cut -f2)
    [[ "$picked_p/$picked_m" == "$bench_p/$bench_m" ]] && saw_bench=1
done
[[ "$saw_bench" == "1" ]] \
  || fail "pick-seat walled a stale (>24h) marker — dead-organ escape hatch broken"
ok "(3c) stale marker (>24h) fail-opens — dead-organ escape hatch intact"

# --- (4) marker write is NOT best-effort: failure is loud ------------------
# If the spawn-bench marker cannot be written, mark_seat_empty_run must
# return 1 so the bench is never silently lost to a clobberable ledger.
# Simulate by making the ledger dir read-only after the ledger write
# succeeds but before the marker write — no, that races. Instead, point the
# marker path at an unwritable location by making LEDGER_DIR a file (so
# seat_spawn_bench_path's parent is not a dir and mv fails). We do this in a
# subshell with a fresh seat so it does not poison the rest of the test.
(
    set -euo pipefail
    # Re-source into a fresh scratch where the ledger dir is a FILE, so the
    # marker tmp file cannot be created in it. The ledger write also fails,
    # so we instead test the contract directly: mark_seat_empty_run returns
    # nonzero when its writes cannot land.
    sub="$(mktemp -d -t seat-empty-run-marker-loud.XXXXXX)"
    trap 'rm -rf "$sub"' EXIT INT TERM
    export HOME="$sub/home"; mkdir -p "$HOME"
    export PI_PACKET_STATE="$sub/state"; mkdir -p "$sub/state/attempts" "$sub/state/active-seats"
    export PI_SEAT_HEALTH_LEDGER_DIR="$sub/ledger"
    export PI_SEAT_HEALTH_SIDECAR="$sub/pi-seat-health.json"
    export PI_MODELS_JSON="$PI_MODELS_JSON"
    export SEAT_CAPS_JSON="$SEAT_CAPS_JSON"
    export XDG_RUNTIME_DIR="$sub/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export PI_SEAT_LIB_CHECK_SYSTEMD=0
    export PI_SEAT_CREDENTIAL_PRECHECK=0
    # Make the ledger dir a FILE so no file can be created inside it.
    : >"$sub/ledger"
    # shellcheck disable=SC1091
    source "$seat_lib"
    if mark_seat_empty_run "ollama" "deepseek-v4-flash:0731" "test:loud-fail" >/dev/null 2>&1; then
        echo "FAIL: (4) mark_seat_empty_run returned 0 when the marker/ledger write could not land — best-effort marker silently lost the bench (fleet-ops#3602)" >&2
        exit 1
    fi
    echo "OK: (4) mark_seat_empty_run fails loud when the marker write cannot land — bench is never silently lost to a clobberable ledger"
)
sub_rc=$?
[[ "$sub_rc" == "0" ]] || fail "(4) subshell failed (rc=$sub_rc)"

ok "seat empty-run bench sticks: survives a healthy 200-probe clobber until wall_end, pick-seat never returns it (fleet-ops#3602)"
