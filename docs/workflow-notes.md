## Workflow notes

Reasons and switches that used to sit as comments in the workflow files; they moved here so the workflow files do not grow (the ratchet above). The runner-group note: the org runner group `agent` must list `agent-dispatch.yml@refs/heads/main` in selected_workflows, or the self-hosted jobs queue forever.

### agent-dispatch.yml: repo variables

```
Events that put work on the agent queue. Repo variable AGENT_MODE:
  shadow (default) = only issues also labelled shadow-actions, no rework
  live             = every agent-ready issue, plus rework on red CI
Repo variable MISS_REVIEW:
  off (default, unset) = miss-review jobs never start
  live                 = a miss event starts one different-family review
To switch miss-review off: set MISS_REVIEW to off, or delete the variable.
To delete it: revert the miss-review jobs in this file and the miss-review
path in agent.yml (Gate, Worker, Arm, Deliverable, Clean).
Repo variable ORCHESTRATE:
  off                  = the orchestrate job never starts
  live (default, unset) = a needs-orchestrator label starts one hand-off run.
  Default on (Nish 2026-10-04, "on for everything the fleet touches"), so a
  newly stubbed repo cannot sit off by omission. Start one by hand with
  gh workflow run agent-dispatch.yml -f task=orchestrate -f issue=<N>
  (an alert contact point, fleet-ops#10204, uses this).
Cost controls on the orchestrate job (fleet-ops#9351), one line per part:
  Daily cap: ORCHESTRATE_DAILY_MAX hand-off runs per IST day, default 10. Off: set the variable to 0.
  Model/turns pin: Sonnet, 40 turns, on every hand-off. There is no model variable
    and no escalation label: Opus, Fable and Qwen are reviewer and judge models only
    (fleet-ops#10750). Off: delete the model and turns lines in the "Check the issue" step.
  Hook skip: the session runs with --settings '{"disableAllHooks":true}'. Off: set ORCHESTRATE_HOOKS to on.
  Runner: pi on a LiteLLM seat (ORCHESTRATE_SEAT, default worker-capable), fleet-ops#9407. Off: set ORCHESTRATE_RUNNER to claude.
    ORCHESTRATE_HOOKS and the 40 turn pin apply to the claude runner only; pi has no turn cap, and the 3000 s timeout is its wall.
  Delete all three: revert the cap and pick blocks of the "Check the issue" step and the model/--settings lines of the session step here,
    the "Orchestrate cap and session args" step in ci.yml, and cap_cases and session_cases in config/orchestrate-events.json (or revert the merge commit).
To switch orchestration off: set ORCHESTRATE to off.
To delete it: revert the orchestrate job in this file, the workflow-path
detector in agent.yml's Gate, and prompts/orchestrator-handoff.md. A run
already in flight finishes: the label gate only stops new ones.
Repo variable FLEET_DISPATCH_PAUSED (the caller repo's, like the others):
  true                   = every job that starts a worker or picks work to
                           start skips, and the paused job logs one summary
                           line per skipped event
  anything else or unset = not paused
ansible/update.yml sets it to true for the update and back to false in
its always: block, then sweeps. It replaces `gh workflow disable`: a disabled
workflow drops every trigger, so hold-risky could not hold a PR armed in that
window (2026-10-05, 08:11-10:47Z). hold-risky and close-claim never read it;
ci.yml fails if a guard job gains the condition or a dispatch job loses it.
Repo variable ADMIT_TRIAGE:
  off                   = the admit job never starts
  anything else or unset = an issue labelled needs-triage in an enrolled product
  repo, filed AND labelled by the human owner login alone and admitted by Jev
  (p >= 0.9), is queued. A bot login never admits; anything below 0.9 goes to
  the orchestrator. Caps: ADMIT_DAILY_MAX admissions per IST day (default 10)
  and ADMIT_BUDGET_SEC a run (default 780). Runs only while AGENT_MODE=live,
  so a shadow-mode repo gets no agent-ready it did not ask for.
  To delete it: remove the admit job, tests/test_triage_admit.py, its ci.yml
  step and [docs/triage-admission.md](triage-admission.md).
The orchestrate and admit jobs are the self-hosted jobs here: org runner group
`agent` (id 3) must list this file @refs/heads/main in selected_workflows,
or the job queues forever next to idle runners. Delete that entry with them.
```

### agent-dispatch.yml: stuck-prs STUCK program

stdin: {pr: {headRefOid, mergeable}, comments: the PR's issue
comments (API objects), red: names of failed required checks on the
head}. Out: {class, reason, url}. class is arm, review or stuck.
Only verdicts on the CURRENT head count, in the words agent.yml's
review job writes. Nothing arms without a reviewer or approver
approval of that head: an unreviewed head, held or not, is sent to
the review job, the same one hold-risky starts. A conflict or a red
check is stuck whatever the review said. Each review the sweep asks
for leaves a `stuck-review: <sha>` comment, so after three asks
with no verdict (a review job that died before it wrote one) the
head is stuck: STUCK re-asks once the marker is 15 minutes old.
config/stuck-pr-cases.json runs this program in CI.

### The weekly engine scorecard: closed, and the gate that closed it

#10560 (branch `fix/issue-10515`, for #10515) added
`.github/workflows/engine-scorecard.yml`: one Monday run that walked the repo's
merged PRs over GraphQL, built per-engine numbers from the `builder-engine:`
comments, posted them on the tracking issue #10521, and filed an alert when an
engine fell below its 4-week median. It is closed as superseded.

The ratchet (`.github/workflows/ratchet.yml`, called by `ci.yml`, required
check `ratchet / ratchet`) allows 0 or fewer net added code lines under
`.github/workflows`, `.github/actions`, `scripts` and `bin`. Measured on the
PR's head `1047d5f7` against its base `490fff3b`:

```
ratchet: net added code lines under .github/workflows, .github/actions, scripts, bin: 184
```

Those 184 lines are the new file's own, so keeping the measurement means
deleting 184 code lines of existing workflow. Merging `main` cannot help
either: the ratchet diffs `merge-base(base, head)` to `head`, and a merge
leaves that merge base where it was. Two independent reviews blocked the same
head on the same defect, that the alert close loop matched every open issue
whose body contains `engine-quality-alert:`, so a human issue quoting the
marker was closed by the workflow.

The ratchet's own error text names the two ways out: "Delete as many as you
add, or build the mechanism in its own repo behind an official extension
point." Both are a decision above a worker, because a second repo is a new
organ. The tracking issue #10521 has been closed since the 2026-10-29 pro-dev
cut ("Reopen if it blocks a product"), so #10515 waits on that decision, not on
a worker.

### secret-scan.yml: the scan steps live in .github/actions/secret-scan

The workflow file is 48 lines (fleet-ops#10947). Every reason that used to sit as a comment in it:

- The `Gitleaks` job is a required context, so it must be structurally incapable of concluding
  SKIPPED: GitHub counts a skipped required context as satisfying branch protection. That is why
  there is no job-level `if:` and no `needs` (a job with `needs` is skipped when its dependency
  fails, and an `if:` can skip on cancellation or any future condition edit). The authorizer is
  step 1 of the job itself, so a fork PR or an unapproved dispatch candidate fails the required
  check with a real failure: a gate that cannot verify must say no, never render green or skipped.
  Path optimization lives in step-level conditions only (the fork guard on the scan step). The
  checkout's `ref:` is `github.sha`, the candidate the authorizer just proved: routing that same
  commit through a step output changes nothing about which commit is checked out, and CodeQL's
  `untrusted-checkout` query then reports it as a privileged checkout of untrusted code.
- The authorizer refuses every event shape it was not written for: only `Nishfleet/fleet-ops`, only
  a 40-hex `GITHUB_SHA`, a `refs/pull/N/merge` PR from this repository, a `refs/heads/main` or
  `master` push, a `gh-readonly-queue/` merge-group ref, or a first-attempt dispatch from `main`
  whose `expected_sha` input equals `GITHUB_SHA`.
- `gitleaks git` walks the commit history the pinned `fetch-depth: 0` checkout provides, so a secret
  that was committed and later deleted still fails the gate. On `pull_request` and `merge_group`
  the scan is scoped to the PR's own range (`base_sha..head_sha`; merge_group carries the same
  pair) so a secret sitting on an unrelated branch cannot poison other PRs or the merge queue.
  Push and dispatch scan `--full-history HEAD` so an already-merged secret still fails, but never
  every fetched ref: a bare `gitleaks git` runs `git log --all`, which walked every claim branch,
  so a fixture on an unrelated branch turned main red and the auto-revert organ merged a revert of
  an innocent PR (0509#1817 reverted #1787, 2026-09-06).
- `--redact` keeps the secret value out of the public run log. `--exit-code 2` separates "leaks
  found" (2) from "gitleaks itself errored" (1), so an infrastructure fault can never be misread
  as a clean scan.
- The gitleaks BINARY is MIT-licensed and free for everyone. Only the `gitleaks-action` wrapper
  demands an organization licence key, and since this repository moved into the Nishfleet
  organization that wrapper aborted every run with "missing gitleaks license" - i.e. no secret scan
  actually executed. Installing the release binary restores real scanning at zero cost, and the
  repository has no `GITLEAKS_LICENSE` secret to give the stock action. The release is pinned by
  version AND by SHA-256, so the download is as tamper-evident as a SHA-pinned `uses:`. To bump:
  change `GITLEAKS_VERSION` and `GITLEAKS_SHA256` together from the release's checksums file; the
  same pair must land in `ci.yml` and `agent.yml`, and
  `tests/test_review_scan.py::test_every_place_that_installs_gitleaks_pins_the_secret_scan_release`
  fails until it does.
- The action is referenced as `./.github/actions/secret-scan`, not `@main`. A `@main` reference
  resolves against main, where the action does not exist yet, so the required `Gitleaks` context
  would fail on its own introducing PR. `.github/zizmor.yml` therefore ignores `self-repository`
  for this file; the `$/` form zizmor suggests is not GitHub syntax (actionlint 1.7.12 rejects it
  as a ref-less action).
- `private-detail-scan` looks for private infrastructure detail (personal home paths, Tailscale
  addresses and names, account ids) in the commits a pull request adds, using
  `.github/gitleaks-private-detail.toml`. History before the PR is not scanned, so old commits
  cannot fail it. It is not a required check. The conditions are on the steps, so the job always
  reports. Switch it off with the repository variable `PRIVATE_DETAIL_SCAN=off` (see README.md).

### deploy-box.yml: what the two oneshots are

Push-triggered. Starts the `fleet-sync.service` user oneshot (the user-scope deploy steps), then
the `fleet-host-config.service` system oneshot (Ansible applies `rootfs/` as root); each exit code
is a verdict. polkit lets this runner's user start that one system unit, so no step uses sudo, and
the unit's own guards still gate every step (fleet-ops#8519). The unit allows
`TimeoutStartSec=300` for the steps alone, so the job's `timeout-minutes: 10` leaves headroom
without letting a hung step park a runner.

### ratchet.yml: how the rule reaches every repo

A repo's job `ratchet` calls this `@main` and requires `ratchet / ratchet`. The rule runs from
main, so a PR that edits that job fails its own check. The org ruleset in
`config/org-ruleset.json` requires this file in every repo, and a ruleset runs a file only if it
declares `pull_request`, `pull_request_target` or `merge_group`: `pull_request` for the rule, and
`merge_group` so a merge-queue entry reports the check. This repo already calls it from `ci.yml`,
so the job skips the ruleset's own run here: one run per PR. That run reports `ratchet`, not
`ratchet / ratchet`.

### coordinator-approval.yml: the merge-queue gate

The risky-change gate as a required check (fleet-ops#9383, #10292). Fleet-ops runs it on
`merge_group`, where the job name is the single-segment check `coordinator-approval`; 0509 and
drive call it and require `coordinator-approval / coordinator-approval`. A caller grants
`contents: read`, `pull-requests: read` and `statuses: read` and triggers on `merge_group`
itself: the token is the caller's, and a narrower grant fails every entry with a read error
rather than an approval. The rules come from fleet-ops main (the base commit on fleet-ops), so a
PR cannot loosen what judges it, and every failed read fails the check. On `pull_request` it
passes, so the check reports and a PR can be enqueued; the queue does the rejecting. The base
commit of this workflow's own first queue entry is main before the move, where the rules still
sat under the `hold-risky` job, so the rules read either layout. `ci.yml` runs this block against
a fake `gh` with each read failing.

