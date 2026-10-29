# Design: the clone lag check (fleet-clone-lag)

Status: shipped in this PR. Issue: #10046.

## Why

On 2026-10-22 two merges that touched `prompts/` (`ebf1d4e7`, `dbee9335`, both
14:14Z) never reached the deploy clone. Both push runs were created, and both
went red on `runner-probe`, which was then the deploy job's first step: the two
`systemctl` steps are `skipped` in both runs, `fleet-sync.service` never started,
and the box served unit files, `prompts/` and `config/` from before them for
40 min, until a manual replay at 14:54Z. The review job read a retired file out
of that clone in the meantime.

The trigger was not the problem. `deploy-box.yml` fires on every push to `main`
and carries no path filter, so every runtime path the box reads already
qualified. Two things were missing:

1. The deploy was **skippable**. A step above it could fail and take the deploy
   with it. Fixed in the same PR: the probe is now the job's last step, so it
   keeps its verdict and loses its gate.
2. Nothing compared the clone to `origin/main` **on a clock**. `fleet-sync`'s own
   probes (`DEPLOY-BLOCKED`, the trailing `merge-base --is-ancestor` pair) run
   only when a deploy starts, and a merge that starts no deploy moves neither
   `HEAD` nor any watched file. Nothing would have said a word.

This unit is (2): the detector, for the failure class that a fix to the deploy
job cannot cover by itself.

## What it is

A stock systemd oneshot, `fleet-clone-lag.service`, that:

- fetches `refs/heads/main` from `origin` into its **own** ref,
  `refs/fleet-clone-lag/main`, with `--no-tags --no-write-fetch-head --refmap=`.
  `--no-write-fetch-head` keeps `FETCH_HEAD` out of the clone: a polluted
  `FETCH_HEAD` there merges into `fatal: Cannot fast-forward to multiple
  branches` and silently stops every deploy (fleet-ops#8893). `--refmap=` stops
  the opportunistic update of `refs/remotes/origin/main`, so this fetch never
  takes the ref lock `fleet-sync`'s own fetch uses.
- fails when the **oldest** commit on `origin/main` the clone does not have is
  more than `LAG_MIN` minutes old, and exits 0 while that age is inside the
  window, printing `deploy pending:`.
- fails, with its own message, on a clone that is missing, on a fetch that fails,
  and on a clone whose `HEAD` is not an ancestor of `origin/main` (a work branch
  checked out, or a rewritten `main`), because `fleet-sync` cannot fast-forward
  any of those and the lag number would be meaningless.

`fleet-clone-lag.timer` runs it every 5 min (`OnBootSec=10min`). `fleet-sync`
step 2m links and enables the pair on every deploy, the way step 2h links its
pair, so a check that is silently off cannot be the next failure. The page is
`OnFailure=fleet-unit-failed@%N.service`, and the failed unit also shows in the
live-state check's `list-units --state=failed`.

## Oldest, not newest

The failing commit is the oldest one the clone lacks, not the newest commit on
`main`. Under a newest-commit rule a run of merges resets the clock, so a clone
that has been stuck for an hour looks young again the moment another merge
lands, which is exactly the state a broken deploy leaves behind. Under the
oldest-commit rule the second merge cannot hide the first.

## The window: 35 minutes

Measured over the last 91 push runs on 2026-10-22: the commit-to-run gap was
8.8 min at the median, 13.5 at p90 and 27.2 at the worst, so a healthy deploy
always reaches the clone inside 28 min. 35 leaves 8 min of headroom for a slower
runner queue, and the 2026-10-22 stall lasted 40 min, so 35 still fires while
the clone is stale (at 14:49Z there, five minutes before the manual fix). A
`cancel-in-progress: false` push run can wait for a free runner for a long time
and a queued run is cancelled outright by the next push, so the window has to
be wider than the queue tail, but a false page costs a look at a unit that only
reads: 35 keeps the observed healthy tail clear of it.

The age is a commit date, not a landing time. A commit stamped long ago (a
fast-forward of an old branch, a direct push) pages on the first check, and a
future-dated commit counts as age 0 rather than a negative number.

## Alternatives rejected

- **A post-deploy assertion in `deploy-box.yml`.** It only runs when a run
  starts and reaches that step, so it is blind to a merge whose run never starts
  and to the cancelled-run-no-successor case, which is half of the failure class.
- **Make the timer run `fleet-sync` itself.** A poller that deploys puts two
  writers on the same clone and loses the per-merge run verdict that the deploy
  job exists to give.
- **A `paths:` filter on the deploy workflow.** The trigger carried none already;
  `prompts/` and `config/` always qualified.
- **A scheduled GitHub workflow that reads the clone.** It would schedule on the
  same runner pool whose saturation is one of the failure modes being detected,
  and it can be cancelled by the same next-push rule. A detector that shares a
  failure mode with the thing it watches is not a detector. The repo also keeps
  host-side conditions in host-side timers (`fleet-cua-desk-check`,
  `later-sweep`, `fleet-pr-sweep@`).

## What it does not do

It never merges, never checks out, never writes a tracked file, and writes no
shared git state. It only reads, so starting it by hand is safe at any time.

## Off switch

`systemctl --user disable --now fleet-clone-lag.timer`, then delete step 2m and
its enable line from `systemd/fleet-sync.service` and delete both unit files.
