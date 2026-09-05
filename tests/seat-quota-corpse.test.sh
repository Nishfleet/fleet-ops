#!/usr/bin/env bash
# tests/seat-quota-corpse.test.sh
#
# fleet-ops#2594: the bash quota_bench writer (mark_seat_quota_bench) was
# excluded from the seat-health.ts corpse logic (#2145). That path covers
# transient_http / rate_limit / cli_timeout / transient_other / empty_run
# by count (seat_dead_consecutive_threshold, default 25) and quota_exhausted
# by age (seat_dead_quota_age_s, default 24h), but the bash writer's
# failure_mode="quota_cap" was in NEITHER branch. Consequence: opencode/
# mimo-v2.5-free at 42 consecutive 429s sat at health_class=quota_bench
# forever — the bench expired after the 24h park wall, the prober retried,
# the seat failed again, the cycle repeated, count kept climbing on a seat
# that was clearly dead. The 2594 audit's snapshot called out the gap.
#
# The fix (lib/seat-lib.sh):
#   - New SEAT_DEAD_CONSECUTIVE_THRESHOLD env var (default 25, matching
#     seat-health.ts's seat_dead_consecutive_threshold so both writers agree
#     on the corpse boundary).
#   - mark_seat_quota_bench now writes seat_dead=true into the ledger when
#     merged_count >= the threshold. seat_usable already holds seat_dead=true
#     TERMINALLY (fleet-ops#2327 — no auto fail-open by aging for a corpse;
#     only a healthy observation clears it), so the existing corpse machinery
#     takes over once the writer flags the seat.
#
# Invariants:
#   Q1  c=1  -> seat_dead=false (below threshold; unchanged behaviour).
#   Q2  c=24 -> seat_dead=false (one below threshold).
#   Q3  c=25 -> seat_dead=true (corpse — at the threshold).
#   Q4  c=42 -> seat_dead=true (the live opencode/mimo-v2.5-free snapshot).
#   Q5  seat_usable on a corpse ledger returns unusable (terminal exclusion).
#   Q6  the writer keeps a concrete bench_until/usable_at (comeback clock) on
#       a quota_cap corpse (fleet-ops#3377: a quota wall is time-based and
#       resets — clearing the clock made the seat permanently dead instead of
#       cooling down). A corpse ledger's bench_until is non-empty and future;
#       once the clock passes, seat_usable fail-opens and the seat is offered
#       again (cooling-down re-release), and a healthy observation clears
#       seat_dead=false.
#   Q7  a corpse is cleared by a healthy observation (seat_dead=false,
#       health_class=healthy, count=0 — the recovery contract).
#   Q8  seat_dead reclassification is independent of the failure-ceiling
#       park — a corpse can be parked at c=25 (above threshold, below
#       ceiling) AND written seat_dead=true (the long wall holds the seat
#       for 24h via the bench window, the corpse holds it past that until
#       manual recovery).
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-quota-corpse.XXXXXX)"
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
# Use the production defaults: ceiling 20 (fleet-ops#2594), corpse threshold 25.
unset SEAT_FAILURE_CEILING
unset SEAT_DEAD_CONSECUTIVE_THRESHOLD
export SEAT_PARK_WALL_S=86400
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "opencode": { "models": [ { "id": "mimo-v2.5-free" } ] }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": { "cap": 1, "class": "free", "quota_bench_default_s": 900, "models": { "mimo-v2.5-free": 1 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

# Verify the defaults the test is pinning match the production ones.
[[ "${SEAT_FAILURE_CEILING:-20}" == "20" ]] \
    || fail "test premise: SEAT_FAILURE_CEILING default must be 20 (fleet-ops#2594), got '${SEAT_FAILURE_CEILING:-<unset>}'"
[[ "${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-25}" == "25" ]] \
    || fail "test premise: SEAT_DEAD_CONSECUTIVE_THRESHOLD default must be 25 (matching seat-health.ts), got '${SEAT_DEAD_CONSECUTIVE_THRESHOLD:-<unset>}'"

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

# Seed a ledger with a given consecutive_failure_count + health_class so the
# next mark_seat_quota_bench merges from that count (simulates a chronically
# walled seat). observed_at is fresh so the seat-observed_fresh branch in
# seat_usable does not fail-open the test.
seed_ledger() {
    local p="$1" m="$2" count="$3" hc="${4:-quota_bench}"
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

# Run mark_seat_quota_bench on a FRESH ledger and return the seat_dead value.
#   $1 = starting count to seed (call adds 1)
fresh_quota_dead() {
    local p="$1" m="$2" count="$3"
    local lf
    lf=$(ledger_file "$p" "$m")
    rm -f "$lf"
    if (( count > 1 )); then
        seed_ledger "$p" "$m" $((count - 1))
    fi
    mark_seat_quota_bench "$p" "$m" "429: FreeUsageLimitError" >/dev/null 2>&1 \
        || fail "mark_seat_quota_bench (count=$count) failed"
    jq -r '.seat_dead' "$lf" 2>/dev/null || echo "false"
}

p="opencode"; m="mimo-v2.5-free"
dead_at_1=$(fresh_quota_dead "$p" "$m" 1)
[[ "$dead_at_1" == "false" ]] || fail "Q1: c=1 seat_dead=$dead_at_1, want false (below threshold; unchanged behaviour)"
ok "Q1: c=1 -> seat_dead=false (below threshold, unchanged)"

dead_at_24=$(fresh_quota_dead "$p" "$m" 24)
[[ "$dead_at_24" == "false" ]] || fail "Q2: c=24 seat_dead=$dead_at_24, want false (one below threshold)"
ok "Q2: c=24 -> seat_dead=false (one below threshold; corpse still parked-but-recoverable)"

dead_at_25=$(fresh_quota_dead "$p" "$m" 25)
[[ "$dead_at_25" == "true" ]] || fail "Q3: c=25 seat_dead=$dead_at_25, want true (at the threshold — corpse)"
ok "Q3: c=25 -> seat_dead=true (at threshold; seat is now a CORPSE — terminal exclusion)"

# Q4: the live opencode/mimo-v2.5-free snapshot (c=42).
dead_at_42=$(fresh_quota_dead "$p" "$m" 42)
[[ "$dead_at_42" == "true" ]] || fail "Q4: c=42 seat_dead=$dead_at_42, want true (live mimo snapshot — corpse)"
ok "Q4: c=42 -> seat_dead=true (the live mimo snapshot — corpse reclassification engages)"

# Q5: a corpse ledger makes seat_usable return 1.
lf=$(ledger_file "$p" "$m")
if seat_usable "$p" "$m"; then
    fail "Q5: seat_usable returned usable for a quota_bench corpse ledger (terminal exclusion broken)"
fi
ok "Q5: seat_usable on a corpse ledger returns unusable (terminal exclusion holds)"

#   Q6: the writer keeps a concrete bench_until/usable_at on a quota_cap
#   corpse (fleet-ops#3377) so the seat has a comeback clock and cools down
#   instead of being permanently dead. The bench_until must be non-empty and
#   in the future; once it passes, seat_usable fail-opens (the quota wall may
#   have reset), and a later healthy observation clears seat_dead=false.
rm -f "$lf"
seed_ledger "$p" "$m" 24   # next mark_seat_quota_bench -> count=25 -> corpse
mark_seat_quota_bench "$p" "$m" "429: FreeUsageLimitError" >/dev/null 2>&1 \
    || fail "Q6: mark_seat_quota_bench at corpse threshold failed"
dead=$(jq -r '.seat_dead' "$lf" 2>/dev/null || echo false)
bench_until=$(jq -r '.bench_until // empty' "$lf" 2>/dev/null || echo "")
usable_at=$(jq -r '.usable_at // empty' "$lf" 2>/dev/null || echo "")
[[ "$dead" == "true" ]] || fail "Q6: corpse seat_dead=$dead, want true (still a corpse)"
[[ -n "$bench_until" ]] || fail "Q6: corpse bench_until is EMPTY — the fleet-ops#3377 comeback clock was dropped (must be concrete)"
[[ -n "$usable_at" ]] || fail "Q6: corpse usable_at is EMPTY — the fleet-ops#3377 comeback clock was dropped (must be concrete)"
bu_s=$(date -u -d "$bench_until" +%s 2>/dev/null || echo 0)
now_s=$(date -u +%s)
(( bu_s > now_s )) || fail "Q6: corpse bench_until=$bench_until is NOT in the future (need a future comeback clock)"
# seat_usable must still hold the fresh corpse benched (future clock).
if seat_usable "$p" "$m"; then
    fail "Q6: fresh corpse ledger (future bench_until) fail-opened — quota_bench branch must hold it benched"
fi
# Age the bench_until into the PAST (past the would-be park wall) to prove the
# seat cools down and fail-opens again instead of being terminally dead.
tmp=$(mktemp)
old_bench=$(date -u -d '@'$(( $(date -u +%s) - 90000 ))' ' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
jq --arg o "$old_bench" '.bench_until = $o | .usable_at = $o | .observed_at = $o' "$lf" >"$tmp" 2>/dev/null && mv "$tmp" "$lf"
if ! seat_usable "$p" "$m"; then
    fail "Q6: aged corpse ledger did NOT fail-open — quota_cap corpse must cool down and re-release after bench_until passes (fleet-ops#3377)"
fi
ok "Q6: quota_cap corpse keeps a concrete future bench_until (comeback clock, fleet-ops#3377); held benched while future, fail-opens once passed"

# Q7: a healthy observation clears the corpse (recovery contract).
rm -f "$lf"
jq -nc \
    --arg provider "$p" --arg model "$m" \
    '{provider:$provider,model:$model,http_status:200,retry_after:null,
      health_class:"healthy",seat_dead:false,poison_ladder:false,
      retryable:true,observed_at:"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
      consecutive_failure_count:0}' \
    >"$lf" 2>/dev/null || fail "Q7: seed healthy ledger failed"
if ! seat_usable "$p" "$m"; then
    fail "Q7: healthy ledger with seat_dead=false is unusable — recovery contract broken"
fi
ok "Q7: a healthy observation clears the corpse (seat_dead=false; seat re-eligible)"

# Q8: seat_dead reclassification is independent of the failure-ceiling park.
# At c=25 (above the corpse threshold=25, above the ceiling=20) the seat is
# BOTH parked (the bench window jumps to SEAT_PARK_WALL_S via _failure_ceiling_wall)
# AND a corpse (seat_dead=true). The bench holds the seat for 24h; the corpse
# holds it past that until manual recovery.
rm -f "$lf"
seed_ledger "$p" "$m" 24   # one less than the corpse threshold
mark_seat_quota_bench "$p" "$m" "429: FreeUsageLimitError" >/dev/null 2>&1 \
    || fail "Q8: mark_seat_quota_bench at c=25 failed"
c=$(jq -r '.consecutive_failure_count' "$lf")
dead=$(jq -r '.seat_dead' "$lf")
bench_window_s=$(jq -r '.bench_window_s' "$lf")
[[ "$c" == "25" ]] || fail "Q8: count=$c, want 25"
[[ "$dead" == "true" ]] || fail "Q8: seat_dead=$dead, want true (corpse at threshold)"
[[ "$bench_window_s" == "86400" ]] || fail "Q8: bench_window_s=$bench_window_s, want 86400 (park wall, c>=ceiling=20)"
if seat_usable "$p" "$m"; then
    fail "Q8: seat_usable returned usable for a parked+corpse ledger"
fi
ok "Q8: c=25 is BOTH parked (bench_window_s=86400, ceiling=20) AND a corpse (seat_dead=true) — both fences engage"

ok "seat quota corpse: mark_seat_quota_bench reclassifies a seat to seat_dead=true at >= SEAT_DEAD_CONSECUTIVE_THRESHOLD (default 25) but keeps a concrete comeback bench_until; the seat cools down and fail-opens once the clock passes (fleet-ops#3377), and a healthy observation clears the corpse (fleet-ops#2594)"
