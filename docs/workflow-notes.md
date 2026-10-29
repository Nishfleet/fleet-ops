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

