# Agent notes for fleet-ops

Stock features only. FINAL, Nish 2026-11-01: every home-built recipe, wrapper,
listener, watcher, scorer, sync unit, hand-off prompt, custom gate or policy was
deleted in favour of the vendor's own feature, and none comes back. A PR that adds
a workflow, unit, timer, script, plugin, prompt or gate is wrong unless it names, in
the PR body, the vendor doc showing stock cannot do it today. Changes under
`.github/`, `ansible/`, `systemd/`, `rootfs/`, `containers/`, `config/`, `infra/`
need Nish's approval (CODEOWNERS); the reviewer App covers the rest.

## How this repo works

- One worker lane: `.github/workflows/agent.yml`. An issue labelled `agent-ready`
  starts one worker on a box runner (user `fleet-runner`), the worker opens one PR,
  CI runs, the reviewer App reviews, the merge queue merges, `deploy-box.yml` applies
  the host play on merge. Product repos call the lane with a 10-line
  `workflow_call` stub.
- CI is `.github/workflows/ci.yml`, under 50 lines, hosted runners: host-play syntax,
  unit-file verify, python-only tests under `tests/`, actionlint. A check that goes red
  for a reason other than the change is deleted, not patched.
- The box is `ansible/host.yml`, applied by `ansible-pull` on every merge to main and
  nightly. Anything on the box that is not in the play comes back from the play.
- Alerts are symptoms only (site down, deploy failed, backup or restore failed,
  error spike), under 10 rules, and open issues the lane fixes.
- Kept on purpose: Tailscale SSH, unattended-upgrades, fail2ban, restic drills,
  Prometheus and Grafana (stock dashboards), Hermes on its own installer, Remote
  Control, Tether (a product), the LiteLLM router with plain rows for the paid seats.

## Fleet rules

**Priority**
- Fleet-ops work outranks product work for workers, reviewers and the orchestrator until the fleet beats a pro dev team's setup on quality, speed and efficiency, measured, not claimed.
- Expedite by fixing the bottleneck, never by freezing other work: no org-wide or repo-wide dispatch pause. Reorder or cancel only queued or low-priority jobs, with Jev's yes, and re-queue them in the same step.

**Seats and models**
- Prepaid subscriptions run at max utilization, and the box runs at 75-80% capacity minimum. Idle seats or RAM next to ready work is a defect, fixed the same turn. Every raw-API token flows through the LiteLLM router.
- Parallel work runs up to the governors: free RAM, router seat caps (`max_parallel_requests`), per-worker caps, the worker slice caps, and one heavy build or test at a time.
- One task = one agent = one model, first turn to last. Only when that agent fails does the task move, once, up to a senior model that gets the full context. Never sideways, never back down. It may confer with other agents.
- GLM-5.3-Flash is a worker model only, never a reviewer, judge or senior seat, and the z.ai plan serves only GLM-5.3-Flash. Qwen 3.8 Max and Opus 5.5 are judges or reviewers only, never workers.
- Never bench a seat or lane. A wall (quota, rate limit, 429, "reset in N min") is handled at run time: the same run falls through to the next lane or seat, and the walled one is asked again on the next job. No off switch, no cap defaulting to 0, no seat removed while it is paid for. If the fallthrough misses a wall's text, widen the match.
- Removing or benching any provider, seat, model, row or paid plan's key file needs Nish's explicit yes, even for a model that has ended. A quota or limit error is never evidence that a row is dead. When a provider ends a model, open a `needs-nish-decision` issue with the evidence and keep it open until he answers. `config/paid-plans.json` (CODEOWNERS: Nish) and the `PaidPlanIdle` alert enforce this.

**Failures**
- Every failure is queue work. Detection lives in Prometheus rules, routing is the Grafana alert-to-issue contact point, and the fix is this lane. Watchdogs dispatch repair; they never page Nish.
- A dying unit fails loud through its unit result, never through a log line alone.
- Never build an LLM pass that re-derives fleet state on a timer.

**Changes**
- Take a new upstream version (package, image, action, tool) at least 3 days after release, or after 24 hours once it passes a full staged test: a copy of the real data, every path smoke-tested, a burst load, and a rehearsed rollback. A security fix goes the same day after the staged test. Dependabot `cooldown` and any other age setting use 3 days.
- A skill with 3 clean one-shot runs (cite the run ids) becomes a job in the lane. A routine runs on an event; a schedule needs a named reason.
- Security work on tracker Nishfleet/nish-vault#30 may run unattended through the normal review gate. It never approves its own work, never uses an owner key, never rotates or deletes secrets or data without a recorded Nish yes, and never weakens a test or gate. Standing yes: a secret value printed into a log or transcript is rotated the same day, as a `priority-now` issue.

Before any change, read the vendor's docs for the feature you touch and name them in
the PR body. Full rules: the vault `_system/shared-memory/global-standing-rules.md`.
