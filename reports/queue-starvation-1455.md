# Queue starvation closeout — dispatches happened but both no-oped, claims read 0 (fleet-ops#1455)

Report date: 2026-08-29
Issue: fleet-ops#1455 — "Intake starvation: 229 ready items, 0 claims in 2h"
Host: netcup-rs2000

## The reported snapshot (2026-08-28T04:30:18Z)

- `ready_work = 229`
- `claims_last_2h = 0`
- `dispatches_last_2h = 2`
- `empty_runs_last_2h = 2`
- `redispatches = 1`
- No failed units, CI green on all 9 repos, `load1 = 0.98`.

Both dispatches in the window were no-ops:
`pi-issue-run: 0509-1287 pi exited 0 but stdout=0B (< 20B) - no-op, exiting 1 so systemd re-seats`,
then `spawn-fail: marked commandcode/minimax/minimax-m3-free unusable until 2026-08-28T02:38:51Z
(backoff=300s, count=1)`.

## Diagnosis — dispatch vs complete: the seat-level no-op wall

Unlike #1418/#1442 (an at-capacity wall with **0** dispatches) and #1421
(a surge hold), this window shows the intake tick **did** dispatch: `dispatches_last_2h = 2`.
Two independent defects produced the reading, neither a resource or claim-loop fault:

1. **Successful claims were never recorded — the `claims_last_2h = 0` false reading.**
   The deterministic intake tick printed `claimed+spawned` to stdout/journal but never
   wrote `/home/nish/workspaces/agent-state/ready-work-claims.log`, the file
   `opus-heartbeat-gather` counts for `claims_last_2h`. The two dispatched issues were
   genuinely claimed (branch + packet + unit spawned), yet the heartbeat read 0 claims
   — so a **working** dispatcher looked starved. This is a recording gap, not an absence
   of claims.

2. **Both dispatched runs failed at the seat level, so no work completed and the queue
   never drained.** One run was a provider no-op (pi exited 0, 0B stdout on
   `0509-1287`); the other was a spawn-fail that benched `commandcode/minimax-m3-free`
   for 300 s. With `empty_runs_last_2h = 2` matching `dispatches_last_2h = 2`, every
   dispatch was an empty run. The reaped issues went back to `agent-ready` and were
   re-dispatched (`redispatches = 1`), so `ready_work` stayed pinned at ~229 while the
   seats churned. The dispatcher was healthy; the **seated work** no-oped and never
   finished, which is exactly the empty-run starvation shape.

## Mechanical fixes (already landed on main)

The two halves of this class are each mechanically prevented by an already-merged PR;
no new machinery is added here (deletion-first closeout, same as #1442).

- **#2010** (merged 2026-08-29 12:02 UTC) — **claims-log recording** (fleet-ops#1455).
  The intake tick now appends a `YYYY-MM-DDTHH:MM:SSZ claimed line=<N> repo=<repo>`
  record to `ready-work-claims.log` **after** all post-condition guards (unit active,
  packet exists, claim branch on remote) pass. `claims_last_2h` now reflects real
  claims instead of 0, killing the false "Intake starvation" reading that filed this
  issue. This is the direct fix for defect 1.
- **#1961 / fleet-ops#1298** (merged 2026-08-29 12:23 UTC) — **zero-stdout no-op bench**.
  A provider no-op (`pi` exits 0, stdout < 20 B) is now benched via
  `mark_seat_empty_run` (same class as the verdict `tools=0` empty run, fleet-ops#902)
  so `pick_seat` reroutes an intake re-spawn away from the no-op'ing seat instead of
  re-selecting it. This breaks the re-seat loop — the direct fix for defect 2.
- **#1408** (already landed) — **escalating bench backoff**. Empty-run benches escalate
  (900 → 1800 → 3600 s, capped 7200 s) and spawn-fail benches escalate (300 → 600 →
  1200 s, capped 3600 s) by `consecutive_failure_count`, capped and fail-open after
  `usable_at` so a recovered seat is re-tried at the base backoff. A repeat no-op'ing
  seat stays benched longer each cycle.

## Regression pinning the class (all green on current main)

The class is pinned, not just fixed:

- `tests/pi-intake-tick-claims-log.test.sh` — the **#1455-specific** pin: the intake
  tick MUST append a claim record (so `claims_last_2h` reflects real claims) and only
  after verified spawns (no false records on failed spawns).
- `tests/pi-issue-run-noop-bench.test.sh` — a zero-stdout provider no-op benches the
  seat (empty_run, escalating) and reroutes the next pick, while the #1378 in-process
  retry still succeeds (item never charged a StartLimitBurst slot).
- `tests/seat-noop-escalation.test.sh` — repeated no-op/spawn-fail benches escalate,
  cap, and fail-open on recovery.

## Throughput proof after the fixes (live 2026-08-29T12:33Z)

- `fleet_ready_work = 70` (down from the reported **229**; ~69% reduction).
- `ready-work-claims.log` continuously populated — records appended every few seconds,
  e.g. `2026-08-29T12:33:34Z claimed line=1672 repo=fleet-ops` — so `claims_last_2h`
  now reads real claims instead of 0.
- 149 PRs merged across the fleet since `2026-08-28` (the snapshot date), i.e. the
  queue is being consumed, not starved.

## Scope note

No new retry/poll/dispatch machinery was added, per the issue's framing and the
deletion-first mandate. The fixes were already landed in #2010, #1961/#1298 and #1408;
this PR is the closeout record. Net machinery trend is negative (one new claims-log
write + one bench on an existing failure path), not a new organ.
