Fix the "dirty tracked files" deploy-block incident (fleet-ops-3389).

Root cause (orchestrator, 2026-09-05T04:25Z): the alert-repair dispatcher
spawned its pi worker with NO working directory, so a weak model ran with
cwd=/home/nish, found the live deploy-clone symlinks (~/.local/bin/* ->
deploy-clone), ran `git checkout -b fix/...` on it and edited fleet-ops files
in place. Its worker died, leaving a named branch + dirty tracked files that
blocked merge-to-live for hours (this issue's body).

Two mechanistic fixes ship together:

1. alert-repair-dispatch worktree seam (reuses the pi-issue-run seam):
   - repo-targeted alerts get a real git worktree (detached at the repo's
     origin/main) under agent-worktrees/alert-repair-<name>;
   - fleet-internal alerts (no repo label) get a safe scratch working dir
     under agent-state/alert-repair/worktrees;
   - either way the dispatch passes `--working-directory <dir>` to
     pi-systemd-run, so the worker's cwd is NEVER the live deploy-clone
     (pi-systemd-run already banks that dir via PI_SALVAGE_WORKDIR);
   - the packet now names the working directory and forbids the live
     deploy-clone and the ~/.local/bin symlinks.
   Fail-open: a worktree-creation error never drops the dispatch.

2. fleet-ops-deploy auto-rescue: when the clone is on a NAMED non-main
   branch carrying dirty tracked files AND no live process has cwd inside
   the clone, the branch is orphaned WIP (an alert-repair worker edited the
   clone in place); stash it with a dated message and detach to
   origin/main so merge-to-live unblocks the SAME tick instead of blocking
   for hours. A checkout with a live process inside (a real worker/hotfix)
   is never touched — it stays a DEPLOY-BLOCK. Same `/proc/<pid>/cwd`
   pattern interactive-session-reap uses.

mechanism-impossible: no. Both fixes are mechanisms with regression tests:
  - tests/alert-repair-worktree-seam.test.sh proves the repo alert creates
    a real worktree + --working-directory, the internal alert gets a safe
    scratch dir, the packet forbids the live clone, and NO-SPAWN stays
    hermetic (no worktree). Hosted from ci-standards-audit (worker App
    cannot push .github/workflows/**); pin added to the P14 gate.
  - tests/fleet-ops-deploy.test.sh scenario 21a/21b proves the auto-rescue
    fires when no process is inside and is refused while one is.

Verification: (hermetic, no live 9090/systemd; real git worktree from a
scratch checkout; mock pi-systemd-run)
```
bash tests/alert-repair-worktree-seam.test.sh        # 4/4 OK (RC=0)
bash tests/fleet-ops-deploy.test.sh                  # incl. scenario21a/21b OK (RC=0)
bash tests/alert-repair-class-park-skip.test.sh      # 4/4 OK
bash tests/alert-repair-claim-mutex.test.sh          # OK
bash tests/alert-repair-seat-walled.test.sh          # OK
bash tests/alert-repair-slo-slowburn-skip.test.sh    # OK
bash tests/alert-repair-wfr-trend-skip.test.sh       # OK
bash tests/alert-repair-outcome-metric.test.sh       # OK
bash tests/ci-standards-audit.test.sh                # OK (hosts the new test)
bash tests/p14-test-listing-gate.test.sh             # OK (test listed closed)
python3 -m py_compile libexec/alert-repair-dispatch  # OK
bash -n bin/fleet-ops-deploy                          # OK
sgscan                                               # No new security findings
```
net-positive-because: the added lines are the mandatory mechanical
prevention for a recurring (2nd time in 8h) incident — a worktree seam so a
worker can never touch the live clone, an auto-rescue so a residual pollute
cannot block merge-to-live for hours, and the regression tests + P14 pin
that prove both and prevent regression. No unit/timer/workflow added.
research: no new bin/ file; both seams reused from existing machinery
(pi-systemd-run --working-directory / PI_SALVAGE_WORKDIR, and the
interactive-session-reap /proc cwd pattern) per the orchestrator's
help-first note — nothing forked or hand-built.

Closes #3389
