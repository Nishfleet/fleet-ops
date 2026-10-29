# Design: cut the dispatcher back to stock

Status: proposal. This document is the only change in its PR. It changes nothing
on any host, and no run behaves differently after it merges.

Issue: #10804.

## Why

`.github/workflows/agent-dispatch.yml` (1,687 lines, 53% of them a `run:` block)
and `.github/workflows/agent.yml` (1,433 lines, 70%), measured at `origin/main`
`fa9a6445a`, are the fleet's dispatcher.
They work, and they have grown one workaround at a time: a mirror with a file
lock, a comment ledger that counts retries, a label that stands in for "a worker
is on this", a relabel dance that starts the next issue, three jobs that stay
off unless `MISS_REVIEW` is set. Each was the right fix for its incident.
Together they are the surface that produces the next incident.

The question this document answers is not "is the dispatcher too big". It is:
for each mechanism, does GitHub already do this, and if it does, how many lines
does deleting ours remove and what does that cost per hour of the work?

Two rules decide every row:

1. A mechanism stays only if no stock object holds the fact it protects. A
   comment ledger is not an object. A PR's head, a run's `run_attempt`, an
   issue's dependency edge and a queue entry are.
2. A delete removes a *repair*, never a *policy*. "Retry the same engine after
   an infra death" is policy. "Count those retries in issue comments" is a
   repair, and stock has the counter.

## Where we are today

Every home-made mechanism, the stock feature that would hold its fact, and the
verdict. Verdicts are `stock` (GitHub does it, we already lean on it), `cut`
(deletable, filed above), and `keep` (no stock equivalent; the one line says
why).

| Home-made mechanism | Stock feature | Verdict |
|---|---|---|
| `claim/issue-N` per-issue lock, `orchestrate-<repo>-<issue>`, review lock | concurrency groups | stock |
| arm auto-merge on an exact head | auto-merge with `--match-head-commit` | stock |
| landing order and ejections | merge queue (ruleset `main-merge-queue`) | stock |
| `ci`, `Gitleaks`, `ratchet`, `coordinator-approval` | ruleset required checks | stock |
| issue blocking | issue dependencies (`blocked_by`) | stock |
| fire on CI failure, on a branch push, on a merged PR | `workflow_run`, `workflow_run` on `claim/issue-*`, `pull_request_target` | stock |
| the claim branch's own cleanup after a merge | `delete_branch_on_merge` | stock |
| retry a run | `gh run rerun --failed` and `run_attempt` | cut (row 5) |
| a checkout per hand-off | `actions/checkout` | cut (row 7) |
| `agent-in-progress` | the issue's live runs | cut (row 6) |
| `miss-review`, `miss-review-pr`, `miss-stalled` | none needed: the sweep's `red` class covers the fact | cut (row 1) |
| `conflicts` and `remerge` | none needed: `stuck-prs`'s CONFLICTING class covers the fact | cut (row 2) |
| log excerpt inside a rework comment | `gh run view --log-failed` | cut (row 3) |
| start the next issue after a finish | `gh workflow run` (one line) | cut (row 4) |
| `hold-risky` | required check holds the head, but cannot dispatch its review | keep |
| `paused` | no stock "do not start, do not forget" | keep |
| `admit` | no stock "who may take work" | keep |
| `stuck-prs` | no stock "PR with no verdict for 15 minutes" | keep |
| `red-main` | no stock "one issue per red workflow" | keep |
| attempt cap, two strikes | no stock escalation policy | keep |
| `close-claim` | `delete_branch_on_merge` covers merges only | keep |
| `ejected` | `dequeued` is stock, the reaction is policy | keep |

The merge queue is the one stock feature the fleet already leans on everywhere:
fleet-ops gates `main` with ruleset `23692529` (squash queue, required checks
`Gitleaks`, `ci`, `ratchet / ratchet`, `coordinator-approval`), 0509 with
`21391031`, drive with `24262668`. Every row below assumes the queue keeps
landing PRs. Nothing here touches it.

## Two shapes

The cut could be organised two ways. They share rows 1 to 4 and differ in what
the surviving dispatcher believes.

### Shape A: one sweep, events only enqueue

`list` becomes the only mover. Every event — a label, a red CI run, a merged PR
— does nothing but enqueue, and the hourly sweep decides everything. Delete
every *second path* to a decision the sweep already makes: `conflicts` and
`remerge` (row 2), the `miss-*` trio (row 1), the rework-note's log read (row 3),
and the relabel dance (row 4). Keep the label state machine, the comment
ledgers and the checkout cache, because A reads them as the sweep's memory.

Shape: 198 lines leave, 131 of `agent-dispatch.yml` (to 1,556) and 67 of
`agent.yml` (to 1,366). One shape, one place to debug, worst-case latency the
sweep interval. Its weakness is that a *store* is not a *path*, so rows 5, 6 and
7 stay by construction: the infra retry count, `agent-in-progress` and the
checkout cache are all in A. That is where the fleet's silent failures
live: a label left behind by a killed run looks like work in progress
(fleet-ops#9063), and an infra death counted in comments cannot be counted
exactly. A leaves the sweep to grow a class for each.

### Shape B: facts in stock objects, thin adapters

Every durable fact lives in a GitHub object, and the dispatcher holds only the
adapters: an event that maps to work, and a retry authority for the classes
GitHub cannot express. Delete every loop whose only job is to remember or
re-derive a fact GitHub already stores — the infra retry count (a run's
`run_attempt`, row 5), "a worker is on this issue" (the issue's live runs, row
6), the hand-off's checkout cache (a per-job workspace, row 7) — and every job
that duplicates a class the sweep already owns (rows 1 to 4).

Rows 1 and 6 remove two of the sweep's seven classes (stalled refs, and the
orphan class, which exists only because the label can be left behind). The five
that remain are in "Kept" below, and B's rule for each is the same as for a
store: a class that is a repair moves into a stock object, and a class that is a
policy stays where it is.

Shape: 346 lines leave, and the *state* surface halves: no `agent-in-progress`,
no infra comment ledger, no mirror, no worktree registration. Its weakness is
that a fact not yet in an object has no home, so the migration is per-fact, not
per-file, and one wrong move turns a silent retry into a parked issue.

## Pick

Shape B, with three rules grafted from A:

- **One retry authority.** `stuck-prs` is the only place that retries a PR
  class. A new retry path needs its own incident first (A's rule, kept).
- **A trigger never decides.** An event may enqueue, but the decision (Gate,
  admit, sweep) reads state, so a duplicate or missed event is not a lost
  decision (A's rule, kept).
- **Ordering by cost.** A's instinct that the sweep is the centre is right for
  latency, but it is the wrong reason to keep a store. B's test — is the fact
  in a stock object — decides each row.

Why A is rejected: it keeps three stores that go stale exactly when something
dies, which is the failure class the fleet hits most, and it leaves the sweep
carrying seven classes (triage labelling, missing check, unarmed, orphan
`agent-in-progress`, red claim PR, deleted-issue skip, stalled refs) with no
plan to stop it growing.

Why B is safe to start now: every row is independently revertible, is a single
PR, and removes code whose replacement is a stock call the fleet already makes.
`actions/checkout` is what every other job in the fleet uses, `list`'s run reads
are the same API the sweep already calls, and `gh run rerun` is new: no workflow
in the fleet calls it today, so row 5 is the one row that adds a command.

## Delete list, ordered by lines removed per hour of work

Hours are the whole job: the edit, the offline gates (`actionlint`,
`zizmor`, `shellcheck`), and the proof the row demands. Lines are net removed
from the files named. Rates are rounded to the nearest integer, ties broken by
fewer hours, then by more lines.

| # | Delete | File(s) | Lines | Hours | Lines/h | Cost |
|---|---|---|---|---|---|---|
| 1 | `miss-review`, `miss-review-pr`, `miss-stalled` (#10806) | dispatch | 48 | 0.5 | **96** | none: `MISS_REVIEW` is unset |
| 2 | `conflicts` and `remerge` (#10807) | dispatch | 63 | 1 | **63** | a conflicted claim PR waits for the sweep, not seconds |
| 3 | log excerpt in `rework-note` (#10808) | dispatch | 20 | 0.5 | **40** | the comment names the run, not the log lines |
| 4 | `Start the next ready issue` becomes one dispatch (#10809) | agent.yml | 67 | 2 | **34** | a freed lane waits up to the sweep interval |
| 5 | infra retry ledger becomes `run_attempt` plus `gh run rerun` (#10810) | agent.yml | 30 | 1.5 | **20** | a retry stays on the same engine by design || 6 | `agent-in-progress` becomes the issue's live runs (#10814) | dispatch, agent.yml, config, docs | 59 | 3 | **20** | the Gate and the sweep read runs, not a label |
| 7 | mirror and worktree cache become `actions/checkout` (#10811) | dispatch | 59 | 3 | **20** | a hand-off that died unpushed loses those commits, so its prompt's push-as-soon-as-checks-pass rule is the precondition, not a preference |

Total: 346 lines and 11.5 hours, 30 lines per hour on average. That is 210 lines
of `agent-dispatch.yml` (12% of it), 132 of `agent.yml` (9%), and 4 occurrences
of the one label name `agent-in-progress` in `config/intake-repos.json`,
`config/orchestrate-events.json`, `docs/intake-enrolment.md` and
`docs/red-main-issues.md`, all counted in row 6. Rows 1 and 2 delete jobs, not
labels, so they carry no config lines. Row 1 also retires the `MISS_REVIEW`
repo variable: no job reads it once its three jobs are gone, and the value is
recorded in that issue before the delete.

Issue numbers are creation order, not row order: row 6's issue was filed after
row 7's, so #10814 comes before #10811 in the list.

Stop after row 4 if the goal is the cheapest behaviour change: 4 hours for 198
lines, and it removes the failure class that cost 258 cancelled runs
(fleet-ops#9269). Rows 5 to 7 are the ones that need a live run as proof and the
ones that change how a worker is retried, where it builds, and how it is seen as
held, so they are last on purpose even though row 6 is the largest single
delete.

## Kept, with why

- **`hold-risky` (208 lines).** It looks like the easiest delete: fleet-ops has
  a `coordinator-approval` required check, so the ruleset already holds a risky
  head. But the job is also the *dispatcher* of the review that posts that
  approval. Delete the job and a risky head is held forever with nobody to
  approve it, and 0509 and drive have no such check at all.
- **`paused` (18).** A disabled workflow is not the same thing: it drops the
  event, and the work is never retried. The variable says "do not start, do not
  forget", and `update.yml` depends on that distinction.
- **`admit` (212).** One judgment call per claimed issue is a policy about who
  may take work. No stock feature makes it.
- **`stuck-prs` (168).** The single retry authority. GitHub has no "PR with no
  verdict for 15 minutes" event, and this job is where every such class
  converges.
- **`list`'s five remaining classes.** Triage labelling, a required check that
  never reported, an unarmed PR, a red claim PR, and a deleted issue. Each is a
  fact no stock object stores (a variable, a check that never ran, a missing
  arm, a red head, a 410), and the sweep is the only mover that reads state
  rather than events.
- **`red-main` (85).** Files one issue per red workflow and closes it when the
  workflow is green. Nothing stock files and closes issues.
- **`close-claim` (32).** `delete_branch_on_merge` cleans a merged claim
  branch. A deleted issue leaves an open PR that nothing stock closes.
- **`ejected` (27).** The merge queue's `dequeued` event is stock. Sending the
  worker back to the PR is policy.
- **The Gate (214), the worker (325), the review (175), the arm (63).** The
  product: routing, the session, paid judgment, and a stock auto-merge call
  wrapped only because the token must be the App's.
- **Attempt cap and two strikes (62 of `Strike or requeue`'s 92).** Escalation
  policy: a packet that failed twice goes to the senior lane.

## Seen, not filed

Each of these is a real argument for a delete that the numbers do not support
yet, recorded so the next cut starts from here instead of from scratch.

- **`list`'s `missing` class (about 30 lines).** It reworks a claim PR whose
  required check never reported. A worker cannot make a check report: only the
  CI config can, and a new head hits the same config. So the class's action does
  not fix its fact. Worth its own investigation, not a delete PR, because the
  same read also catches a dispatch that never started.
- **`RUN_LIVE_JQ` (job env, 10 lines).** It reads stock run state, and it is
  the price of not trusting `status` for a run whose `work` job ended. Both
  copies are needed while `stuck-prs` runs before the run list settles.
- **`admit`'s trusted-login check.** An authorization rule, not glue. The
  `orchestrate` job's sender check is the same rule twice, and that duplication
  is deliberate: both jobs can start a session.
- **`paused`'s per-event lines (18).** One line per event that says what would
  have happened. A person reading a paused repo needs exactly this.

## How to start

Each row is its own issue and its own PR, in the order above. The edits are
under `.github/workflows/`, which the worker App token cannot push (no
Workflows permission), so the orchestrator hand-off applies each one: add
`needs-orchestrator` to the issue when its row's turn comes, one at a time, so
two rows never share a head. The issues are filed unlabelled on purpose:
labelling one fires the hand-off immediately, and the design it implements
should be on `main` first.

Each PR states which row it is, carries the offline gate results
(`actionlint`, `zizmor`, `shellcheck`), the diff-scoped semgrep result, and for
rows 5, 6 and 7 a live run id.

Two facts set the wall time. Every row edits `.github/workflows/`, so every
row's PR is held until its exact head carries a coordinator approval: the 11.5
hours are work time, and the queue is the rest. And the worker App token cannot
push a workflow file, so the hand-off applies each row, not a worker.

Row 5's one new command needs a credential answer, and the answer is the one
row 4 already uses: `gh run rerun` runs as the runner login (`env -u GH_TOKEN`),
the same login the dispatch step calls with today, so no token gains a scope.
The `run_attempt` read uses the App token's existing `actions: read`.

Rolling back a row is that row's PR reverted, plus one `gh variable set` for a
row that deleted a repo variable: the value is recorded in the row's issue
before the delete, so the restore is one line. No row touches a database or a
host file, and no row is a migration.

## What would tell us this was wrong

- Row 1: a claim PR goes red and gets its rework note from the sweep with the
  `MISS_REVIEW` variable gone, so the note's presence is the test and the
  variable cannot be flipped back to hide a miss.
- Row 2: a conflicted claim PR sits past one sweep with no note.
- Row 3: a worker reports a red PR it could not fix because the comment carried
  no failing line, twice.
- Row 4: a freed lane sits idle for more than one sweep interval while ready
  work waits, twice in a week.
- Row 5: the same engine fails the same way three times on a run whose
  `run_attempt` is still under the cap.
- Row 6: a worker run that parks, strikes or requeues leaves an issue that the
  Gate then admits twice, or the sweep never requeues an issue whose run died.
  A run-list read that fails must hold the issue, never admit it: an unread run
  list looks like "no worker on this", which is the double admit.
- Row 7: a hand-off loses work to a fresh checkout, or a live hand-off cannot
  open its PR from a per-job workspace.

Each is observable from the issue thread and the run list, without a new
detector. That is the test for every future row too: if the wrongness needs a
new guard to see, the row is not ready to cut.
