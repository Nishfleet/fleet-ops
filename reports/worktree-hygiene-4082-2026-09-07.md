# fleet-ops#4082 — worktree_dirs=540 hygiene incident: drain verification record

Snapshot at issue creation: 2026-09-06T21:45Z heartbeat reported
`thorough.hygiene_counts.worktree_dirs=540` on netcup with
`disk_free_pct` 55.36 and falling (55.37 -> 55.36 in one tick). Each
pi-issue worker worktree is ~440 MB.

## Resolution (verified live)

No new mechanism was needed. The standing drain —
`bin/fleet-worktree-reaper` (#2227, extended by #2637, #3023, #3945
Mode E, #3995 count bound + exit-3 escalation, #3494 webhook-fired reap
on PR close, #4118 per-worktree report) — drained the backlog under its
existing safety gates. The recorded safe cleanup order was followed: a
worktree is removed only when its branch is fully on origin, or its
claim branch has a merged PR, and in every case only when no live
worker unit owns it and the tree is clean. Dirty stale trees were
banked to origin `wip/wfr-*` refs via `pi-salvage-worktree` before
removal.

## Drain record (issue comments + run JSON)

| Run (UTC) | reaped | post_count |
|---|---|---|
| daily timer 2026-09-06T22:12Z | 214 | ~326 |
| 2026-09-07T00:39Z manual | 40 | 341 |
| 2026-09-07T02:17Z manual | 26 | 315 |
| 2026-09-07T03:xx–05:xxZ manual (4 runs) | 13 | 318 |
| 2026-09-07T05:57Z manual | 1 | 319 |
| 2026-09-07T13:33Z manual | 14 | 326 |
| 2026-09-07T13:58Z manual (this run) | 3 | 328 |

Counts rise between runs because new claim worktrees are created
continuously — the net is the drain keeping pace plus clearing backlog.
Worker-run total: 97 reaped. `worktree_dirs`: **540 -> 328**
(bound 450, `bound_breached=0`).

## Safety — no live worktree removed

Every run's skip counters show the gates holding: the final run skipped
`skipped_live=8`, `unmerged=63`, `dirty=60`, `notpushed=137`,
`notterminal=12`, `young=12`; `salvage_attempts=1` held its gate.
One persistent `REMOVE-A` failure (`0509-1731`, branch
`claim/issue-1733`) was left in place — the reaper never force-removes.
Removal goes through `git worktree remove` without `--force`, which
itself refuses a dirty or locked tree (defense in depth).

## Disk

`disk_free_pct` 55.36 and falling at file time -> 40% used / 294G
available (`df -h /`, 2026-09-07T13:58Z), stable across all eight runs.

## Standing prevention

- `fleet-worktree-reaper.timer` runs daily (next run
  2026-09-07T22:10Z) plus webhook-fired reaping on PR close (#3494).
- Bound: post_count > 450 exits 3 and the escalation drop-in pages.
- The thorough-mode heartbeat that surfaced this metric was retired in
  #4176 (Prometheus recording rules + Alertmanager carry the signal
  now); the reaper's own bound-breach path is independent of it.

## Mechanical-fix statement

Class: "agent worktree dirs accumulate without bound when no reaper
runs." Detector + drain + bound + page already exist (reaper, bound,
escalation). This PR records the verification only — no code change.
