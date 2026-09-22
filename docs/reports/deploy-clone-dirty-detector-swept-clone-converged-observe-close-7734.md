# Observe-close for #7734 — the DIRTY-CLONE detector was swept; the clone is clean and converging

Issue #7734 (filed by the fleet-deploy-check signal, observed
2026-09-18T11:26:18Z) reported the deploy clone
(`/home/nish/workspaces/tooling/fleet-ops-deploy-clone`) dirty on three
consecutive 2-minute ticks, named `config/fleet_rules.yml` and
`libexec/fleet-metrics-export.py`, and asked for salvage-or-reconcile plus a
return to `status --porcelain` empty.

By the time this re-claim ran (2026-09-22 IST), the detector that filed it had
been deleted from main, the clone was clean and fast-forwarding on every tick,
and both named paths were either replaced or gone. No unsalvaged edit survives
and no code change is needed; this report is the resolution record, following
the same convention as the #7511 observe-close (PR #8103) and the #7709
observe-close (PR #8167).

## What was found

1. **The alert has no producer on origin/main.** `bin/fleet-deploy-check`
   (724 lines) and `systemd/fleet-deploy-check.{service,timer}` were deleted by
   `72b38e857` ("cut(deploy): delete the copy-then-detect-drift deploy cluster;
   one linked-unit sync timer replaces it", 2026-09-18, an ancestor of
   origin/main `8719d6a64`). That binary wrote the `DIRTY-CLONE` journal line
   the issue's evidence command greps. No `DIRTY-CLONE` string remains on main
   outside `prompts/worker.md` prose, and `config/fleet_rules.yml` carries no
   dirty/diverged-clone alert rule — nothing is left emitting the signal.

2. **The replacement fails loud instead of soft.** `systemd/fleet-sync.service`
   is the surviving 2-minute tick (its header records the same cadence as the
   deleted `fleet-deploy-check.timer`). Its first step is
   `git -C <clone> pull --ff-only origin main`; on a dirty or diverged clone it
   logs `DEPLOY-BLOCKED pull --ff-only refused (dirty or diverged clone)` and
   exits 1, so the unit lands in
   `systemctl --user list-units --state=failed` and is captured by the
   failed-unit sweep. The old auto-file-and-retry path is gone: a recurring
   writer now produces a visible failed unit, not a fresh issue.

3. **The clone is clean and on main.** At claim time,
   `git -C /home/nish/workspaces/tooling/fleet-ops-deploy-clone status
   --porcelain` returned empty (0 lines) and `rev-parse HEAD` equalled
   `rev-parse origin/main` (`8719d6a645324c35dc804df2d8fee62a24caf1fe`). The
   clone reflog is a run of `pull --ff-only origin main: Fast-forward` entries,
   including two more clean fast-forwards during this run.

4. **The writer, named before anything was touched.** The issue's own 3-tick
   wave was authored by Nish's backup-shrink session: the 2026-09-18T12:23Z
   comment on #7734 names Claude session
   `657fe727-f472-424b-b266-5700ddc69e09`, which spawned transient unit
   `second-cut-b-metrics-test.service` running
   `tests/fleet-metrics-export.test.sh` + `measure.sh` with cwd inside the
   clone (the fleet-ops#3758 worktree violation), continuing the merged
   second-cut-B stream `a437f7be6`. That session and unit are gone: no
   `second-cut*` transient unit exists, no process matches it, and its
   `deploy-clone-rescue-2026*` salvage directories no longer exist on disk.
   No live process (`pi-issue@*`, `agent-cron`, `pi --print`) has the clone as
   its `/proc/<pid>/cwd`; the only running worker units work in their own
   `agent-worktrees` trees. No open PR touches either named path
   (`gh pr list --state open`, filtered on changed files → none for
   `config/fleet_rules.yml` or `fleet-metrics-export`).

5. **Salvage-or-reconcile: reconciled, by deletion.**
   `libexec/fleet-metrics-export.py` does not exist on origin/main; it was
   removed by `f65e812c4` ("cut(exporter): 67 alert rules -> 14, all on
   stock-exporter metrics", an ancestor), and
   `systemd/fleet-metrics-export.service` now runs
   `libexec/fleet-metrics-probe.sh` — the export logic was replaced, not lost.
   `config/fleet_rules.yml` is present and identical to main (the clone is
   clean). The wave's tracked deletions landed on main through the sweep:
   `4d7ab9f28` (21 process gates, incl. `bin/attest-identity-gate`,
   `bin/fleet-claim`, `prompts/senior-conference.md`,
   `config/machinery-allowlist.json`), `d7d69d813` (the 0509 market-signal
   cron), `a437f7be6` (second-cut-B) — all ancestors of origin/main. There is
   no in-clone edit left to discard (nothing is present) and nothing left to
   salvage (the work is already on main), so no claim-worktree PR is possible
   or needed.

6. **The class recurred after the filing, then converged.**
   `journalctl --user -u fleet-sync.service` shows 11 `DEPLOY-BLOCKED` lines
   since 2026-09-18: one each on Sep 19 and Sep 20, six on Sep 21
   04:44–04:54Z, and three on Sep 21 16:04–16:08Z. The Sep 21 21:22–21:39 IST
   episode is visible in the clone reflog as `checkout: moving from main to
   deputy/trust-stack`, then back to `main` and `pull -q --ff-only` — a
   feature branch parked in the deploy clone (the fleet-ops#477 violation,
   guarded for auditor repairs by the merged `24fa42c74`, an ancestor). Since
   2026-09-21T16:09:42Z every `fleet-sync` tick reports `origin/main unchanged`
   or a clean fast-forward; no further `DEPLOY-BLOCKED` line has been written.

## Why the acceptance arms do not require a code change

- *Name the writer before touching anything* — named above (item 4). The
  writer was a human-launched session that has exited; the agent-side writer
  class is already covered by the merged worktree guard for escalation workers
  (`24fa42c74`).
- *Salvage-or-reconcile* — there was nothing in the clone to discard or
  salvage (item 5); the tracked work is on main.
- *Never commit on the clone* — no commit was made on it; the clone's only
  history moves are `pull --ff-only` fast-forwards.
- *Done means `git -C ... status --porcelain` is empty* — verified empty.

No watcher/cleaner was added. The #6225 root-cause analysis for this same
signal class already recorded the must-not ("a watcher/cleaner that resets the
clone, or a `|| true` around the dirty check"), and Nish's 2026-09-19 no-glue
direction (#7828) rules out new helper scripts. The single-writer guarantee now
lives in `fleet-sync.service`'s loud failure plus the deleted-organ convention,
not in a repaired `DIRTY-CLONE` detector.

## Acceptance verification (2026-09-22, netcup-rs2000)

| Check | Result |
|---|---|
| Clone porcelain empty | `git status --porcelain` → 0 lines |
| Clone on origin/main | `rev-parse HEAD == rev-parse origin/main` → `8719d6a64` |
| Detector deletion on main | `git merge-base --is-ancestor 72b38e857 origin/main` → yes |
| Replacement present | `systemd/fleet-sync.{service,timer}` present; `ExecStart` runs `pull --ff-only` and prints `DEPLOY-BLOCKED` + exit 1 on failure |
| Named path 1 | `config/fleet_rules.yml` present; clone clean (identical to main) |
| Named path 2 | `libexec/fleet-metrics-export.py` absent on main (removed by `f65e812c4`) |
| Dangling alert rule | none (`grep -i 'dirty\|deploy_clone' config/fleet_rules.yml` → no hits) |
| Writer unit/process | gone; no `/proc/<pid>/cwd` inside the clone; last non-fast-forward clone move 2026-09-21T16:09:42Z |
| Open PRs on named paths | none |

mechanism: the detector that filed the signal (`bin/fleet-deploy-check`) was
deleted by `72b38e857`; its replacement `systemd/fleet-sync.service` refuses a
dirty pull with `DEPLOY-BLOCKED` and exit 1, and the clone is clean and
converging — observe-close record per the fleet's deleted-organ convention
(fleet-ops#6225 → observe-to-close; #7511 → PR #8103; #7709 → PR #8167).
