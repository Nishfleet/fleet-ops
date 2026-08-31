#!/usr/bin/env bash
# tests/fleet-seat-corpse-retire-gc.test.sh
#
# fleet-ops#2540: daily GC organ for the append-only seats-corpse-retired-*
# audit dirs. The fleet-ops#2469 retirement bin (PR #2511) moves corpse seat
# ledgers into dated seats-corpse-retired-<UTC-ts>/ dirs and never deletes
# them (they are the post-mortem audit trail); with no GC the dir count
# grows unbounded (observed 2026-08-31: 9 dirs in 5h18m). This bin prunes
# dirs STRICTLY older than the 30-day retention floor and has a hard guard
# that never deletes anything newer than 30d, regardless of count.
#
# What we prove (hermetic, scratch-rooted, deterministic NOW seam):
#   1. Empty lanes root -> noop (scanned=0 kept=0 pruned=0, exit 0).
#   2. 3 fresh dirs (<30d) -> noop (scanned=3 kept=3 pruned=0; dirs exist).
#   3. 3 stale dirs (>30d) -> 3 pruned (scanned=3 kept=0 pruned=3; gone).
#   4. Mixed -> ONLY stale pruned (scanned=4 kept=2 pruned=2).
#   5. --dry-run reports pruned=N but deletes nothing.
#   6. Over-cap (max-dirs 10, 11 fresh + 2 stale): stale pruned, fresh
#      NEVER pruned even over cap, LOUD cap line emitted.
#   7. Metric file: last_run_seconds + total{dir,outcome} written every
#      run incl. no-op sweeps (absent() rule catches a missing file).
#   8. Unit shape: service + timer exist, ExecStart first token is
#      runner-safe /bin/bash (no ci.yml stub needed), timer fires
#      04:45 UTC daily.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-seat-corpse-retire-gc"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-seat-corpse-retire-gc not found: $bin"
command -v find >/dev/null || fail "find required"
command -v stat >/dev/null || fail "stat required"

scratch="$(mktemp -d -t seatcorpsegc.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

lanes="$scratch/lanes"
mkdir -p "$lanes"
prom="$scratch/gc.prom"

# Deterministic clock: everything is measured against this fixed instant.
NOW_ISO="2026-08-31T12:00:00Z"
now_e="$(date -u -d "$NOW_ISO" +%s)"
fresh_e=$(( now_e - 10 * 86400 ))   # 10 days old  -> kept (< 30d)
stale_e=$(( now_e - 40 * 86400 ))   # 40 days old -> pruned (> 30d)
fresh_ts="$(date -u -d "@$fresh_e" +%Y-%m-%dT%H:%M:%SZ)"
stale_ts="$(date -u -d "@$stale_e" +%Y-%m-%dT%H:%M:%SZ)"

mkdir_fresh() { # $1 = UTC-ts suffix parts are in the name; mtime = fresh
    mkdir -p "$lanes/seats-corpse-retired-$1Z"
    touch -d "$fresh_ts" "$lanes/seats-corpse-retired-$1Z"
}
mkdir_stale() {
    mkdir -p "$lanes/seats-corpse-retired-$1Z"
    touch -d "$stale_ts" "$lanes/seats-corpse-retired-$1Z"
}

run_bin() { # $@ = extra args; env already pinned via env_shim
    local opts=("$@")
    FLEET_SEAT_CORPSE_RETIRE_GC_ROOT="$lanes" \
    FLEET_SEAT_CORPSE_RETIRE_GC_PROM="$prom" \
    FLEET_SEAT_CORPSE_RETIRE_GC_NOW="$NOW_ISO" \
    FLEET_SEAT_CORPSE_RETIRE_GC_RETENTION_S=2592000 \
    "$bin" "${opts[@]}" >"$scratch/run.out" 2>&1 || {
        cat "$scratch/run.out" >&2
        fail "run_bin failed rc=$? args=${opts[*]}"
    }
}

count_dirs() {
    find "$lanes" -maxdepth 1 -type d -name 'seats-corpse-retired-*' | wc -l
}

expect_metric() { # $1 = outcome, $2 = expected value
    local outcome="$1" want="$2" got
    got="$(grep -oE "fleet_seat_corpse_retire_gc_total\{dir=\"seats-corpse-retired\",outcome=\"$outcome\"\} [0-9]+" "$prom" | awk '{print $NF}')"
    [[ "$got" == "$want" ]] || fail "metric $outcome: want $want got '$got'"
}

# --- 1. empty root -> noop ---------------------------------------------------
run_bin
expect_metric scanned 0
expect_metric kept 0
expect_metric pruned 0
grep -q 'fleet_seat_corpse_retire_gc_last_run_seconds [0-9]' "$prom" \
  || fail "last_run_seconds missing after noop sweep"
ok "1. empty lanes root -> noop (scanned=0 kept=0 pruned=0, metric written)"

# --- 2. fresh dirs (<30d) -> noop --------------------------------------------
mkdir_fresh 2026-08-21T00:00:00
mkdir_fresh 2026-08-21T01:00:00
mkdir_fresh 2026-08-21T02:00:00
[[ "$(count_dirs)" == 3 ]] || fail "setup: expected 3 dirs"
run_bin
expect_metric scanned 3
expect_metric kept 3
expect_metric pruned 0
[[ "$(count_dirs)" == 3 ]] || fail "fresh dirs must survive a noop sweep (got $(count_dirs))"
ok "2. 3 fresh dirs (<30d) -> noop (scanned=3 kept=3 pruned=0, dirs remain)"

# --- 3. 3 stale dirs (>30d) -> 3 pruned --------------------------------------
rm -rf "$lanes"/seats-corpse-retired-*
mkdir_stale 2026-07-01T00:00:00
mkdir_stale 2026-07-01T01:00:00
mkdir_stale 2026-07-01T02:00:00
[[ "$(count_dirs)" == 3 ]] || fail "setup: expected 3 stale dirs"
run_bin
expect_metric scanned 3
expect_metric kept 0
expect_metric pruned 3
[[ "$(count_dirs)" == 0 ]] || fail "stale dirs must be pruned (got $(count_dirs) remaining)"
ok "3. 3 stale dirs (>30d) -> 3 pruned (scanned=3 kept=0 pruned=3, dirs gone)"

# --- 4. mixed -> only stale pruned -------------------------------------------
rm -rf "$lanes"/seats-corpse-retired-*
mkdir_stale 2026-06-01T00:00:00
mkdir_stale 2026-06-15T12:00:00
mkdir_fresh 2026-08-22T00:00:00
mkdir_fresh 2026-08-23T00:00:00
[[ "$(count_dirs)" == 4 ]] || fail "setup: expected 4 dirs"
run_bin
expect_metric scanned 4
expect_metric kept 2
expect_metric pruned 2
[[ "$(count_dirs)" == 2 ]] || fail "expected 2 survivors (fresh only); got $(count_dirs)"
ok "4. mixed -> only stale pruned (scanned=4 kept=2 pruned=2, fresh survive)"

# --- 5. --dry-run deletes nothing --------------------------------------------
# Re-create the mixed set (scenario 4 already pruned the stale dirs) so the
# dry-run reports the same 4/2/2 shape but deletes nothing.
rm -rf "$lanes"/seats-corpse-retired-*
mkdir_stale 2026-06-01T00:00:00
mkdir_stale 2026-06-15T12:00:00
mkdir_fresh 2026-08-22T00:00:00
mkdir_fresh 2026-08-23T00:00:00
[[ "$(count_dirs)" == 4 ]] || fail "setup: expected 4 dirs"
before="$(count_dirs)"
run_bin --dry-run
expect_metric scanned 4
expect_metric kept 2
expect_metric pruned 2
[[ "$(count_dirs)" == "$before" ]] || fail "dry-run must not delete (before=$before after=$(count_dirs))"
ok "5. --dry-run reports pruned=2 but deletes nothing"

# --- 6. over-cap: fresh dirs NEVER pruned even past max-dirs=10 --------------
rm -rf "$lanes"/seats-corpse-retired-*
for n in $(seq -w 1 11); do
    mkdir_fresh "2026-08-2${n}T00:00:00"
done
mkdir_stale 2026-06-02T00:00:00
mkdir_stale 2026-06-03T00:00:00
[[ "$(count_dirs)" == 13 ]] || fail "setup: expected 13 dirs"
# Note: {1..11} -> 01..11; suffix 2026-08-201...205 are valid-ish strings but
# the mtime (not the name) drives retention, so this is hermetic regardless.
run_bin --max-dirs 10
expect_metric scanned 13
expect_metric kept 11
expect_metric pruned 2
[[ "$(count_dirs)" == 11 ]] || fail "over-cap must prune only stale (got $(count_dirs) remaining, want 11)"
grep -q 'LOUD: scanned=13 exceeds max-dirs cap=10' "$scratch/run.out" \
  || fail "over-cap LOUD line missing"
ok "6. over-cap 10: 13 dirs (11 fresh + 2 stale) -> stale pruned, fresh kept, LOUD line"

# --- 7. metric shape: last_run + all three outcomes present ------------------
grep -q '^# HELP fleet_seat_corpse_retire_gc_last_run_seconds' "$prom" \
  || fail "HELP line missing for last_run_seconds"
grep -q '^# TYPE fleet_seat_corpse_retire_gc_last_run_seconds gauge' "$prom" \
  || fail "TYPE line missing for last_run_seconds"
grep -q 'fleet_seat_corpse_retire_gc_last_run_seconds [0-9]' "$prom" \
  || fail "last_run_seconds value missing"
expect_metric scanned 13
ok "7. metric file shape correct (last_run_seconds + total{dir,outcome})"

# --- 8. unit shape -----------------------------------------------------------
svc="$repo_root/systemd/fleet-seat-corpse-retire-gc.service"
tmr="$repo_root/systemd/fleet-seat-corpse-retire-gc.timer"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$tmr" ]] || fail "missing $tmr"
# ExecStart first token must be runner-safe (/bin/*) so the CI unit-verify
# job needs no VPS stub (p14-unstubbed-unit-verify class).
grep -qE '^ExecStart=/bin/bash' "$svc" || fail "ExecStart must be /bin/bash form"
grep -q '^OnCalendar=\*-\*-\* 04:45:00 UTC' "$tmr" || fail "timer must fire 04:45 UTC daily"
grep -q '^Persistent=true' "$tmr" || fail "timer must be Persistent (missed-day catch-up)"
ok "8. unit shape: service ExecStart=/bin/bash (runner-safe), timer 04:45 UTC Persistent"

echo "OK: fleet-seat-corpse-retire-gc.test.sh: 8 scenarios green"