## Workflow notes

Reasons and switches that used to sit as comments in the workflow files; they moved here so the workflow files do not grow (the ratchet above). The runner-group note: the org runner group `agent` must list `agent-dispatch.yml@refs/heads/main` in selected_workflows, or the self-hosted jobs queue forever.

### agent-dispatch.yml: repo variables

```
Events that put work on the agent queue. Repo variable AGENT_MODE:
  shadow (default) = only issues also labelled shadow-actions, no rework
  live             = every agent-ready issue, plus rework on red CI
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
without letting a hung step park a runner. The security probe is the job's last step, not its
first: a red probe still fails the run, and it can no longer mark the two deploy steps `skipped`,
which is how two merges on 2026-10-22 reached no deploy for 40 min (fleet-ops#10046;
`tests/test_deploy_box_trigger.py` locks the order).

### ratchet.yml: how the rule reaches every repo

A repo's job `ratchet` calls this `@main` and requires `ratchet / ratchet`. The rule runs from
main, so a PR that edits that job fails its own check. The org ruleset in
`config/org-ruleset.json` requires this file in every repo, and a ruleset runs a file only if it
declares `pull_request`, `pull_request_target` or `merge_group`: `pull_request` for the rule, and
`merge_group` so a merge-queue entry reports the check. This repo already calls it from `ci.yml`,
so the job skips the ruleset's own run here: one run per PR. That run reports `ratchet`, not
`ratchet / ratchet`.

### ci.yml: the enrolled-stub check shares the python3-yaml step with the alert routes

`ci.yml`'s `systemd-verify` job runs `tests/alert_routes_check.py` and
`tests/intake_stub_check.py` in one step, because the ratchet above allows no net new
workflow code line: a step of its own costs four lines (its name, `if: always()`, the
`env` map and the `run` line), which is exactly the four that step already spent on the
alert routes. Both checks read a repo file with python3-yaml and hold a contract written
as prose, so they share the one install. The alert-route check still runs first, so its
failure is reported before the stub check's, and `if: always()` is what keeps the stub
check reporting when an earlier step of the job failed.

### agent-dispatch.yml: hold-risky, review-risky and list

hold-risky (0509#7092: a risky PR was armed, gained commits after the
coordinator approved a different head, and merged on ci-ok alone; its
needs-coordinator label came 8 s after the arm). Risk is read from the changed
paths, not only the label, so an unlabelled risky PR is caught too. The path
list is config/risky-paths.json on fleet-ops main, read by URL so every caller
repo uses the same copy; an unreadable list holds every PR.
Approval is either a PR comment with the line `coordinator-approval: <full head
sha>` (unedited) or a coordinator-approval=success commit status on that sha.
The comment path exists because cloud sessions get 403 on POST /statuses. Both
name one sha, so every push needs a fresh approval. GITHUB_TOKEN writes fire no
workflow, so the hold does not re-trigger itself or the ejected job. The hold
fails closed: a read that fails (the PR, its files, the path list, its statuses
or comments, the merge state) counts as risky or not approved, gets a
::warning:: naming the read, and the label, disarm and dequeue still run. The
job only goes red when it cannot confirm the PR is disarmed and out of the
queue. Either approval read failing means not approved, even if the other read
alone would approve. The label goes first, so a dequeued event raised by the
steps below already sees it, and a failed label does not stop the disarm and
dequeue. A failed merge-state read still runs both mutations blind (with the
REST node_id) and the re-read confirms; a PR that left the queue between the
read and the call ("not queued") is fine, the re-read catches one still
queued. tests/test_risky_paths_cases.py in the unit job runs CLASSIFY and
APPROVAL against every case in config/risky-paths.json, and ci.yml runs the
hold block against a fake gh with each read failing.

pull-requests: write labels the PR and disables auto-merge. contents: write is
what GitHub asks of a merge-queue dequeue (it acts on the merge, like arming
does). statuses: read and pull-requests (which covers a PR's issue comments)
read the approval. Nothing here checks out code, so contents: write never
meets PR head code. The changed-files read lists both names of a rename and
goes through a file, not argv: 3000 paths can pass the 128 KiB single-argument
limit, and a failed read leaves the list empty, which CLASSIFY holds. The
merge list says a not-risky PR merges on green checks (as before), so the
review the ruleset now requires on every PR is given here, for a same-repo
head only; a fork PR waits for a person. The API refuses a commit_id that is
no longer the head (HTTP 422, checked 2026-10-12), so a push after the read
gets no approval. That approve needs the repo setting "Allow GitHub Actions to
create and approve pull requests" on.

review-risky (Nish 2026-10-05: reviewed PRs merge themselves, no pasted
approval lines). agent.yml's review job reads the head's diff through the API,
never checks out PR code, asks a model with no tools for findings and Jev for
approve or block, then posts the coordinator-approval comment as
github-actions[bot]; the same run's arm job then arms the PR. hold-risky stays
the only door: it reads that comment like any other. A PR that edits the guard
itself (risky-paths.json "guard") or a workflow needs three reviews to
approve: the judge and two more reviewers of other model families. No person
is asked. Paused fleets do not review.

CLASSIFY stdin is {repo, labels, files, patches, changed_files} and $cfg is
risky-paths.json or null. patches is [{file, patch}] with patch null when the
API sent none (large or binary). Risky is a path hit (under "*", minus the
"safe" docs patterns, or under the PR's own repo), or an added diff line
matching a "diff" entry for that file, or a file such an entry covers with no
patch. A list cut at 3000 files, an empty list or an unreadable path list all
count as risky. APPROVAL stdin is {sha, statuses, comments}: only the newest
status for CONTEXT counts, so a later failure revokes it, and the comment must
be unedited (updated_at == created_at), so an old one cannot be moved onto a
new sha.

list is the sweep. A closed blocker frees the issues it was blocking; a manual
run also sweeps every ready, unblocked issue (cutover backfill and missed-event
recovery), then open claim PRs that are unarmed, conflicting, missing a
required-check report, red with no rework since the failure, or still
agent-in-progress with no live agent run. Priority-now first, then oldest. The
Gate step in agent.yml re-checks each and its 3-run cap bounds any loop.
contents: read is required because `statusCheckRollup` on a private repository
needs it as well as checks: read, or GitHub answers "Resource not accessible by
integration (repository.pullRequest.statusCheckRollup.nodes.0)" and the sweep dies on
the first claim PR (tether#56); a public repo never asks for it. actions: read,
not write, is `gh run view` liveness (fleet-ops#8777); actions: write made
their sweeps fail at startup (fleet-ops#10638). Every sweep runs where its
re-queue writes find the worker App key: fleet-ops on its own runners, a caller
on its agent runners, because a hosted runner has no ~/.config/gh and the
`env -u GH_TOKEN` re-queue writes only print "re-queue refused" there
(fleet-ops#10963). A closed blocker releases at most 12 parked hand-offs a
sweep, the requeue batch's own bound, because each one costs two writes and a
closed epic can block hundreds (fleet-ops#11010).

A split parent never closed on its own, so everything blocked by it waited
forever (0509, 2026-09-24: ~140 issues); the job closes each open ancestor
whose sub-issues are all closed and releases what it blocked (a GITHUB_TOKEN
close fires no event), while a critical-path or epic parent carries its own
finish line and never closes here. CONFLICTING counts as stuck too: auto-merge
stays armed on a PR that turns DIRTY after arming, so it never enters the
queue and no event fires (0509#4384); the bulk list returns mergeable UNKNOWN
until GitHub recomputes after a push to main, so each armed PR is re-read
(fleet-ops#8557); and a merge-queue PR is dropped by ref, because it can have
autoMergeRequest null (0509#4688) and the CONFLICTING test alone cannot drop
it. A required check that never reported (fleet-ops#8777) is BLOCKED with
nothing pending and nothing failed; a pending check is left, it is running,
not missing; a completed failure is left to the red case below; and a repo
with no required checks is never BLOCKED by them, so it lists none
(Nishfleet/drive, fleet-ops#8981). An agent-in-progress issue whose worker is
gone is live when the newest "agent run started:" run is queued or in
progress, read by `gh run view` and judged by its work job (RUN_LIVE_JQ at the
top of the file). The red case covers what the rework event missed (drive#765:
no run fired; 0509#7182 #7172: rework hit lanes-full and nothing retried;
every failure while FLEET_DISPATCH_PAUSED is true): an "agent run started:"
newer than the failure, or a live newest run, leaves the PR alone, a rare
overlap with the rework event is serialised by agent.yml's concurrency, a
DIRTY PR is the conflicts job's, and a PR at the 3-run cap is sent on so the
Gate parks it.

RED_REWORK's label list and infra-failed rule are agent.yml's Gate, copied; a
start whose run infra-failed never tried, so it does not count. Its input is
{pr: gh pr view, issue: the issue API object, comments: gh issue view
comments}; reason is "go" or the skip reason, and run is the newest counted
"agent run started:" body. No cap test: a
PR at the cap is dispatched on purpose, so the Gate parks it with
needs-orchestrator and later sweeps skip it on the label. No rework-note test:
rework-note posts even while paused, so a note would hide the failure the
event missed. The gone-issue read: measured 2026-10-12 with gh 2.93.0 on
deleted issue 9502, exit 1, stdout {"message":"This issue was deleted",
"status":"410"}, stderr "(HTTP 410)"; either marks it gone, any other read
fault stays fatal (fleet-ops#9553).

### agent.yml: the arm step classifies with the one list

`config/risky-paths.json` is the one list. The arm step runs agent-dispatch.yml's
`CLASSIFY` program against it before it arms a claim PR, and holds the PR, labeled
`needs-coordinator`, when the classifier calls it risky. It reads both from
fleet-ops main by URL, the way `hold-risky` and `coordinator-approval` read them,
so the check cannot drift from the hold, and it holds when a read of the rules,
the list or the diff fails, so an outage at arm time cannot arm a risky head
(fleet-ops#11164). The step used to carry a second list beside the file, and the
two drifted: a drive PR in `src/` was held while the file already called it safe,
which took a patch to the step to fix (fleet-ops#9420, #11049).
tests/test_agent_workflows.py runs the step against a fake `gh` that serves a
`pulls/<n>/files` read and a fake `curl` that serves the checkout's rules and
list, so the step runs the real program against the real list: a PR the
classifier calls risky is labeled and not armed, and the old second list cannot
come back unnoticed. `ci.yml` runs that test (fleet-ops#9278).

### agent.yml: the 2026-10 diet audit (fleet-ops#11068)

Issue #11068 asked for four cuts to agent.yml. All four are live, so the audit
deleted nothing and records why, with a run that shows each one working.

Counting agent.yml's own runs does not count `work`. A called workflow's jobs
run inside the caller's run, named `<caller job> / work`, so agent.yml's run
list holds only its own runs: 58 in the 30 days to 2026-10-30, 38 `schedule`
and 20 `workflow_dispatch`. Run 40880205007 (2026-10-29T13:15:02Z) shows
`unblocked (claim/issue-10900) / work` success and
`unblocked (claim/issue-10913) / work` success. agent-dispatch.yml holds ten
`uses: agent.yml@main` lines. Six pass a `ref` and so start `work` (new,
rework, remerge, ejected, unblocked, stuck-rework), two start `review`
(review-risky, stuck-review), `stuck-arm` starts `arm` and `stuck-file` starts
`stuck`. No dispatch input is needed.

`report` is already deleted (fleet-ops#9336, commit 0d572d6ca, 2026-10-15).
Before that every run skipped it (run 38545447452: `report` skipped), so the
issue's "0 of 16" counts skips of a job that no step reached, not a job that
ran. The `Strike or requeue` step in `work` does its work, and ci.yml's
"Infra-wall classifier (fake gh)" step fails a PR that adds the job back.

`review`'s rework block stays. The orchestrator starts on the
`needs-orchestrator` label, and `GITHUB_TOKEN` fires no event on a label or a
comment, so this block is the only route that sends a blocked `orch/issue-N`
PR back, and it must post as the worker App. The 3-round cap lives in the same
step. tests/test_orch_rework.py runs it.

`inish-daily`'s runner-probe is not a copy of ci.yml's jail step. The job runs
one step for it, `.github/actions/runner-probe` (fleet-ops#9989), and no
planted-file step sits beside it today. ci.yml's "Worker jail hides the gh
login" step plants fake logins on a throwaway GitHub-hosted runner and runs
bwrap's mounts. The probe reads the live `actions.runner.*` unit's
`InaccessiblePaths` as its own user and fails when a hidden path is readable,
and only the box has that unit, so neither check covers the other's case. The
`work` job runs the same probe on the same runner group, but every
agent-dispatch.yml job that reaches `work` carries
`vars.FLEET_DISPATCH_PAUSED != 'true'`, while `inish-daily`'s own `if:` has no
pause term and fires at 02:00 and 05:00 UTC. On a paused fleet its probe is the
only one left.

`stuck` stays. agent-dispatch.yml's `stuck-file` job (line 905) passes all four
inputs (`stuck_pr`, `stuck_sha`, `stuck_reason`, `stuck_url`): run 40957777296
shows `stuck-file (11052, …) / stuck` success. ci.yml's "Sweep moves PRs waiting
over 15 minutes (STUCK)" step pins the wiring (`stuck-review:review_pr
stuck-arm:arm_pr stuck-rework:ref stuck-file:stuck_pr`) and fails when the job
is gone.

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

