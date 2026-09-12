#!/usr/bin/env bash
# tests/seat-empty-run-count-persists-new-issue.test.sh
#
# fleet-ops#3730: ollama/deepseek-v4-flash:0731 empty-run churn. Snapshot
# 2026-09-05T21:45:00Z: 12 provider no-ops in 2h (exit 0, stdout=0B); the
# geometric bench cycled 900s -> 1800s -> 7200s and then RESET (count=1 at
# 20:56:19Z after count=4 at 20:17:37Z), so the seat was re-offered within
# the hour and burned another issue run. The required fix:
#
#   1. The empty-run counter MUST persist across re-seat cycles — a NEW
#      issue picking the same seat (the intake re-spawn / fresh-claim case)
#      must NOT reset consecutive_failure_count to 1. Each fresh no-op on the
#      seat escalates the geometric backoff from the previous count.
#   2. The seat MUST be held until a non-empty run proves it — pick-seat must
#      not fail-open an expired bench while the bench marker is still the
#      seat's latest evidence (probe-gated re-admission, fleet-ops#3737).
#
# This test pins that contract END-TO-END through pick-seat, the routing
# authority workers use: two empty runs on the SAME seat from two DIFFERENT
# simulated issue ids must yield count 1 -> 2 (backoff 900 -> 1800), and
# pick-seat must never hand the seat to the second issue — neither while the
# bench is active nor after the bench expires with a still-fresh marker —
# because both seats share one provider so pick-seat always has somewhere to
# reroute. Runs offline: scratch ledger, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-count-persists.XXXXXX)"
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
count_of() { jq -r '.consecutive_failure_count // 0' "$1" 2>/dev/null || echo 0; }
backoff_of() { jq -r '.backoff_s // 0' "$1" 2>/dev/null || echo 0; }

# Seed a healthy ledger observation for the reroute seat exactly as
# seat-health.ts writes on a passing probe (fleet-ops#3602 fixture shape).
seed_healthy() {
    local p="$1" m="$2" lf="$3"
    local now_utc tmp
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp="$lf.seed.$$.$RANDOM.tmp"
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

# Run pick-seat for a FRESH issue id (empty tried-seats = the intake
# re-spawn / new-claim path that re-picked the no-op'ing seat). Asserts the
# benched seat is never returned.
assert_fresh_pick_skips_benched() {
    local label="$1" bench_p="$2" bench_m="$3" other_p="$4" other_m="$5"
    local i picked picked_p picked_m
    for i in 1 2 3 4 5; do
        : >"$STATE_DIR/attempts/pi-issue-fleet-ops-3730.tried-seats" 2>/dev/null || true
        picked=$(pick-seat "" "" 0 "" "light" "public" || true)
        [[ -n "$picked" ]] || fail "$label: pick-seat returned empty (iteration $i)"
        picked_p=$(printf '%s' "$picked" | cut -f1)
        picked_m=$(printf '%s' "$picked" | cut -f2)
        if [[ "$picked_p/$picked_m" == "$bench_p/$bench_m" ]]; then
            fail "$label: pick-seat re-offered the benched seat $bench_p/$bench_m to a fresh issue on iteration $i (fleet-ops#3730)"
        fi
        [[ "$picked_p/$picked_m" == "$other_p/$other_m" ]] \
          || fail "$label: pick-seat rerouted to $picked_p/$picked_m, expected $other_p/$other_m (iteration $i)"
    done
    ok "$label: pick-seat never re-offered the benched seat across 5 fresh-issue re-seats"
}

bench_p="ollama"
bench_m="deepseek-v4-flash:0731"
other_m="qwen3:32b"
bench_lf=$(ledger_file "$bench_p" "$bench_m")
bench_mf=$(marker_file "$bench_p" "$bench_m")
other_lf=$(ledger_file "$bench_p" "$other_m")

rm -f "$LEDGER"/*.json "$LEDGER"/*.spawn-bench.json 2>/dev/null || true

# --- (1) ISSUE A empty-runs the seat once: count=1, base backoff 900s ------
seed_healthy "$bench_p" "$other_m" "$other_lf"
mark_seat_empty_run "$bench_p" "$bench_m" "pi-issue:fleet-ops-a:noop:1" >/dev/null 2>&1 \
  || fail "mark_seat_empty_run #1 failed"
[[ -f "$bench_mf" ]] || fail "issue A empty-run did not write the spawn-bench marker"
c1=$(count_of "$bench_mf"); b1=$(backoff_of "$bench_mf")
[[ "$c1" == "1" ]] || fail "(1) first empty-run count=$c1, want 1"
[[ "$b1" == "900" ]] || fail "(1) first empty-run backoff=${b1}s, want 900s (EMPTY_RUN_BACKOFF_S)"
ok "(1) issue A empty run: marker count=$c1, backoff=${b1}s (base, geometric ladder starts at 1)"

# --- (2) NEW ISSUE B re-seat while the bench is still active: pick-seat
#     reroutes to the healthy seat, NEVER to the benched deepseek ----------
assert_fresh_pick_skips_benched "(2) new issue B, bench active" "$bench_p" "$bench_m" "$bench_p" "$other_m"

# --- (3) NEW ISSUE B empty-runs the SAME seat again AFTER an expiry: the
#     bench is forced to wall_end but the marker stays fresh and is still the
#     seat's latest evidence, so pick-seat must HOLD it (no fail-open) until
#     a non-empty probe proves the seat (probe-gated re-admission, #3737) ---
past_iso=$(date -u -d '@0' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
tmp=$(mktemp)
jq --arg u "$past_iso" '.usable_at = $u' "$bench_mf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_mf"
marker_written=$(jq -r '.written_at // ""' "$bench_mf")
[[ -n "$marker_written" ]] || fail "spawn-bench marker has no written_at"
tmp=$(mktemp)
jq --arg o "$marker_written" '.observed_at = $o' "$bench_lf" >"$tmp" 2>/dev/null && mv "$tmp" "$bench_lf"
assert_fresh_pick_skips_benched "(3) new issue B, bench expired but marker is latest evidence (probe-gated hold)" "$bench_p" "$bench_m" "$bench_p" "$other_m"

# --- (4) NEW ISSUE B empty-runs the seat AGAIN: the counter MUST persist
#     across the re-seat cycle — count 1 -> 2, backoff 900 -> 1800 — and
#     must NOT reset to count=1 (the fleet-ops#3730 churn signature) --------
mark_seat_empty_run "$bench_p" "$bench_m" "pi-issue:fleet-ops-b:noop:2" >/dev/null 2>&1 \
  || fail "mark_seat_empty_run #2 (issue B) failed"
c2=$(count_of "$bench_mf"); b2=$(backoff_of "$bench_mf")
[[ "$c2" == "2" ]] \
  || fail "(4) new-issue empty-run count=$c2, want 2 — the empty-run counter did NOT persist across the re-seat cycle (fleet-ops#3730)"
[[ "$b2" == "1800" ]] \
  || fail "(4) new-issue empty-run backoff=${b2}s, want 1800s (escalated geometric: 900 * 2^(2-1)) — the bench should not be sticking"
ok "(4) new-issue re-seat count persisted: count=$c2 (1->2), backoff=${b2}s (900->1800) — counter NOT reset on a new issue id (fleet-ops#3730)"

ok "seat empty-run counter persists across a new-issue re-seat cycle and the seat is held until a non-empty run proves it (fleet-ops#3730)"
