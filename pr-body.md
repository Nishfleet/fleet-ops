fix(seat): escalate the failure-ceiling park wall with the count (fleet-ops#3941)

## Problem

`xkiro/deepseek-v4-flash` failed its spawn 47 times straight (`failure_mode=spawn_fail`, `bench_reason=no_block:rc=1`). It crossed the failure ceiling (`SEAT_FAILURE_CEILING`), parked behind the 24h wall (`SEAT_PARK_WALL_S`), and when that wall lapsed within the hour it was re-offered to a work item, spawn-failed again, and got **the same flat 24h wall once more**. The wall never grew, so a chronically-dead seat was probed once per day forever while the ledger stayed `health_class=healthy` / http 200.

## Root cause of the spawn rc=1

The rc=1 is pi's exit when the provider spawn times out (spawn `ETIMEDOUT`, `is_spawn_etimeout`, `elapsed < SPAWN_FAIL_MAX_S`) — the seat is genuinely not producing output. seat-health.ts logs a transport 200 as healthy during the very run that then exits rc=1 with no body, so its "healthy" write is false-healthy, not recovery (fleet-ops#3737/#3826). The bench escalation is the missing piece: the park wall kept resetting to 24h regardless of how many times the seat had already failed.

## Fix

New `_park_wall_s`: the park wall **escalates one `SEAT_PARK_WALL_S` per failure past the ceiling**, capped at `SEAT_PARK_WALL_MAX_S` (new, default 7 days).

- `count == ceiling` -> first park stays 24h (unchanged).
- `count > ceiling` -> grows 24h, 48h, 72h, ... capped at 7 days.
- `count < ceiling` -> 0 (caller keeps the base backoff; unchanged).
- A healthy observation still resets the count and a recovered seat still fail-opens after the (longer) wall — the park stays a cooldown, never a permanent wall.

Wired into all four surfaces so the count-scaled wall is consistent:
1. write side — `_failure_ceiling_wall` (shared by every writer: spawn-fail, empty-run, quota, overload, hang);
2. read side — `seat_usable`'s transient_fault / rate_limited park fence (fleet-ops#3586);
3. read side — `_seat_floor_remaining_s` park wall;
4. comeback organ — `bin/fleet-seat-comeback-release` `rebench_wrapper_marker` (with a fallback to the flat 24h if the seat-lib helper is not sourced).

## Verification

```
$ bash tests/seat-failure-ceiling.test.sh
OK: spawn-fail: devin/glm-5-2 parked at count=60, wall=86400s, metric emitted
OK: live state (72 -> 73): parked on next failure, wall=1209600s (escalated)
OK: 8a: write-side park wall escalates with count past the ceiling, capped
OK: 8b: _failure_ceiling_wall escalates a parked count, base below ceiling
OK: 8c: xkiro/deepseek-v4-flash c=47 transient_fault -> parked behind escalated wall (read side)
EXIT: 0
```

```
$ bash tests/seat-noop-escalation.test.sh        # EXIT 0
$ bash tests/seat-quota-corpse.test.sh           # EXIT 0
$ bash tests/seat-empty-run-park-persists.test.sh# EXIT 0
```

```
_escalated ladder (SEAT_FAILURE_CEILING=20, SEAT_PARK_WALL_S=86400):
  count 19 -> 0          (below ceiling, not parked)
  count 20 -> 86400s     (first park = 24h)
  count 21 -> 172800s    (48h)
  count 22 -> 259200s    (72h)
  count 47 -> 604800s    (capped at SEAT_PARK_WALL_MAX_S = 7 days)
```

## Test plan

- 4 previously-flat park-wall tests updated to assert the escalated wall (live-47 and live-72 replays included), and section (8) added to `seat-failure-ceiling` proving the write and read-side escalation directly.
- Full seat/comeback suite exercises no new failures in CI (the 4 pre-existing failures — `fleet-seat-recovery`, `fleet-seat-comeback-release` overdue-clears, `fleet-researcher`, `rule-enforcement` timer-manifest — fail identically on `origin/main` and are environment/live-state related, verified on a base worktree).
- `bin/sgscan`: No new security findings. `shellcheck`: clean.

## run-proof

- `bin/sgscan` -> exit 0 (no new security findings) on the change range.
- Repo test harness: `tests/seat-failure-ceiling.test.sh`, `tests/seat-noop-escalation.test.sh`, `tests/seat-quota-corpse.test.sh`, `tests/seat-empty-run-park-persists.test.sh` all exit 0.
- No new systemd units/timers/workflows added by this PR.

net-positive-because: the +114-line diff is almost entirely new/escalated-wall assertions across four seat-benchmark test files (proving the count-scaled bench) plus a ~40-line documented helper and a 7-day cap constant in `lib/seat-lib.sh`; the behavioral surface it replaces (one flat `SEAT_PARK_WALL_S` fallback in the comeback bin) shrinks.

Relates to #3826
Closes #3941
