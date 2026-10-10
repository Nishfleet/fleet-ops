# Architecture

One page. What the fleet is, how its parts fit, and the rules that are enforced
today. `README.md` is the operational front door; `docs/RUNBOOK.md` is the
operator sequence. Where this page and a live file disagree, the live file wins
(`config/litellm-proxy.yaml`, the systemd units, the workflows).

## Shape

One VPS (netcup), one `nish` user. Everything the fleet runs is a
`systemctl --user` unit whose file lives in `systemd/` and is linked into
`~/.config/systemd/user/` by hand once; a push to `main` is the deploy:
`deploy-box.yml` runs `fleet-sync.service`, a fetch plus `--ff-only` merge,
never `git pull` (RUNBOOK, fleet-ops#8893). GitHub is the durable copy of
code and config.

The work loop: `.github/workflows/agent-dispatch.yml` queues `agent-ready` issues as `agent.yml` jobs on the VPS self-hosted runners, workers open PRs on `claim/issue-<N>`, and the GitHub merge queue lands them.
Dispatch pauses through the repo variable `FLEET_DISPATCH_PAUSED`, never by disabling the workflow: with it `true`, every job that starts a worker skips and logs one summary line, while `hold-risky` and `close-claim` keep running (a disabled workflow drops every trigger, guards included; 2026-10-05). Unset or any other value is not paused. The weekly `ansible/update.yml` sets it per repo and clears it in its `always:` block, then sweeps; it lists the repos it paused in `/var/lib/fleet-ops/dispatch-paused-by-update`, so a run killed before `always:` is undone at the start of the next, and a flag set by hand is left alone; ci.yml fails if a guard job gains the condition or a dispatch job loses it.
No scheduled fleet job opens issues or PRs: issues come from people, red-main issues and dependabot, which runs weekly. The one scheduled model call is `systemd/blacksmith-flip.timer` (hourly): `prompts/blacksmith-flip.yml` runs through `pi --print` on the `worker-cheap` seat and sets or deletes the org `CI_RUNNER` variable at 95% of the free Blacksmith minutes (fleet-ops#8936).

## Model plane

Pi reaches models through the LiteLLM proxy on `127.0.0.1:4000`
(`fleet-litellm-proxy.service`), backed by a fleet-owned Postgres and Redis
(`fleet-litellm-postgres.service`, `fleet-litellm-redis.service`). Seats and
model groups are declared in `config/pi-models.json` and
`config/litellm-proxy.yaml`; **those files are the router record — no mirror
doc.** Group health is `litellm_deployment_state` on `/metrics` and
`/health/readiness`.

`POST 127.0.0.1:4000/jev` is the typed-decision pass-through (boolean / choice
/ score questions), served by the Vercel AI Gateway. The one live decision caller is `prompts/worker.md`
step 4 (`needsNish`), which carries its own threshold;
`docs/jev-call-sites.md` lists the call sites.

## Worker isolation

Each worker runs under `bwrap` on a self-hosted runner (`.github/workflows/agent.yml`):
its own PID namespace, so every process it starts dies with it, and the
fleet-ops checkout bound read-only. It stays in the runner's cgroup, so the
`agent.slice` memory caps still apply.

## GLUE-ZERO — no hand-rolled code

Nish, 2026-09-21: _"wipe and replace with properly done up design with no
glue."_ The rule, held by the `ci` check (`.github/workflows/ci.yml` runs
`.semgrep/no-glue.yml`; `.github/CODEOWNERS` also sends scripts to Nish):

- **No new scripts, helpers, hooks or extensions anywhere** — no added file
  under `bin/`, `lib/`, `libexec/`, `scripts/`, `ops/`, `hooks/`,
  `.github/scripts/`, `tests/`, `template/extensions/subagent/`, and no added
  `*.sh` / `*.py` / `*.mjs` / `*.ts` or `.fleet/**` file.
- The deleted trees stay deleted (`bin lib libexec tests scripts hooks ops
.fleet template/extensions/subagent`), and glue is deleted, never tuned: no
  added lines in `bin/`, `lib/`, `libexec/`, `tests/`, `template/extensions/`,
  `.fleet/`.
- A unit `Exec` line is one vendor command; the accepted floor is a single
  `sh -c` around one or two vendor commands (e.g. the gh-token mint). No
  program embedded in a prompt (interpreter heredoc, code fence, run-this-file
  line).
- No hand-built Pi extensions are kept. `permission-gate.ts` and
  `protected-paths.ts` are gone; the heavy-command class is capped instead by
  the agent runner services' `MemoryHigh=4G` / `MemoryMax=8G` in
  `10-agent.conf`, inside `agent.slice` (`MemoryHigh=26G` /
  `MemoryMax=28G`). The fleet-ci runners carry `MemoryMax=3G` in
  `10-fleet-ci.conf`.

The design record with the full organ-by-organ reasoning is git history
(fleet-ops#7828); this page keeps only what is enforced.

## TRUST-STACK — verification and the correction ladder

The rules still in force:

- **Concurrency is governed by capacity; merging is governed by
  verification.** Fan out to the RAM / seat / per-worker caps, but nothing
  reaches `main` without its required checks.
- **CI green is an input to a verdict, not a verdict.** A behavioural change
  needs a live or test-verified proof; a docs change does not.
- **The in-run reviewer is same-family and advisory; the required checks are
  the gate.** `prompts/worker.md` step 7 runs the stock reviewer on the
  worker's own lane, so a fresh context is not an outside pair of eyes, and CI
  is what gates the merge. A different model family is still required where it
  decides something: a change that adds or edits an AI decision (`AGENTS.md`,
  "Any change that adds or edits an AI decision") is scored by a different
  model family, which writes and labels the held-out cases and runs the final
  score. Where a review does not happen, the record says so rather than
  claiming a review it did not get: the `in-run review: unavailable -
<reason>` line.
- **Worker lanes and Claude seats.** `agent.yml` Gate: ordinary issues go to
  pi, then opencode, then Devin. `strong-only` (senior) issues go to Claude
  Code first (`claude-sonnet-5-5`; `claude-opus-5-5` after two failed runs or
  with `needs-opus`). The seat is set by the runner's number
  (`RUNNER_NAME` is `netcup-agent-N`): in the claude lane step, before claude
  runs, an even N unsets `CLAUDE_CONFIG_DIR` and runs the default login (seat b),
  an odd N keeps it (seat a), and a name with no number keeps seat a. The step
  logs `claude lane: seat=a|b runner=<name>`. The jail exposes only the chosen
  seat. Jobs split across both seats with no clock, and a job stays on one seat
  from the Gate to the last call, which keeps the prompt cache. To switch it
  off, delete that block (every runner then runs seat a). When claude exits on a rate limit or a usage
  limit, the same packet falls through: Cursor (cap 1) for `strong-only`, pi for
  any other job. Nothing polls usage.
  Routing by judgment, in plain words: Claude does the judgment work, free
  workers do the mechanical work, and Jev decides which is which. For an issue
  that is not `strong-only`, the Gate asks Jev one typed question from the issue
  title and body: does completing this need engineering judgment (a design
  choice, ambiguity, multi-file reasoning, debugging), as opposed to a
  mechanical, fully specified change? Only the extremes count. At 0.9 or more
  the issue goes to the claude lane (Sonnet, or Opus with `needs-opus`); at 0.1
  or less it goes to the free lanes (pi, then opencode, then Devin). Anything
  between, or a Jev call that fails (a warning is logged), goes to the free
  lanes; `strong-only` always goes to claude. The decision is written as
  `judgment: p=<x> -> claude|free (<reason>)` to the log and the job summary.
  Eval numbers: `tests/evals/results/needs_judgment.json`. There is no cap on
  live claude workers: nothing stock gives N slots, and each worker sits under
  its runner's `MemoryHigh=4G` and `MemoryMax=8G` while all runners share
  `agent.slice` (`MemoryHigh=26G`, `MemoryMax=28G`). First reviews of every PR
  stay on Claude (below); Jev gives the verdict. The Worker step records the
  engines that ran in a `builder-engine:` PR comment, which the review job
  reads. Secret isolation: the bwrap jail of every engine but claude hides both
  Claude seat logins (the runner's own config directory and the default
  login's credentials file and `~/.claude.json`) and every other Claude config
  or credential backup directory (matched by glob at job start, not a list) the
  same way it hides the gh and Cloudflare logins; the claude jail hides
  everything but the seat it is running on. `ci.yml` runs the real jail lines
  and fails if a login can be read, and if the claude lane cannot read its own
  seat.
- **The correction ladder.** A correction is encoded at the lowest rung that
  holds it: 1 structure (no file to put the mistake in), 2 static gate (CI
  check, ruleset, systemd property, router config), 3 rule, 4 skill, 5 prose.
  `encoded: 5` is legal only with a reason. A rule that recurs twice is a
  defect in its rung.
- Gates that exist: a PR touching a risky path is labelled `needs-coordinator` and
  not armed; agent-dispatch.yml's `hold-risky` job disarms, dequeues and labels
  any PR whose changed paths or added diff lines match `config/risky-paths.json` until its exact
  head sha is approved: an approver's unedited PR comment with the line
  `coordinator-approval: <full head sha>`, or a `coordinator-approval=success`
  status on it (0509#7092), or a GitHub `Approve` review by nish3451 whose
  `commit_id` is that head (one tap in the app, fleet-ops#9505; a `[bot]` review
  never counts, a later change request revokes). That review re-arms with no
  second step: `approval-signal.yml` (PR-head code, no permissions) uploads the
  PR number, and the `workflow_run` it triggers runs `hold-risky` from the base
  branch, which re-reads the review and calls `arm-approved` (agent.yml `arm`).
  agent.yml's `review` job (called by
  `review-risky`) is the independent approver: it reads the held head's diff
  through the API, asks a no-tools Claude call for findings (on the runner's own login:
  Opus 5.5 for work another engine built,
  Fable 5.1 for Claude-built work; the worker App's `builder-engine:` PR
  comment says which, and no comment counts as Claude-built) and Jev for
  approve or block (p >= 0.9), and posts that approval as
  `github-actions[bot]` (an approval comment written with GITHUB_TOKEN).
  "Claude never grades Claude" has one exception, approved by Nish on
  2026-10-10: the review model may be Claude when Fable reviews Claude-built
  work, but the verdict is always Jev's, a non-Claude family, so a non-Claude
  family always decides. With the runner's seat at its limit the review does not
  finish and is re-run; it is never approved without it. A PR that edits the guard itself
  (`guard` in risky-paths.json) or a workflow needs a second review as well, by
  a model family other than the judge's and Claude's, and both must approve; if
  either blocks, its blockers go to the agent as fix-it items. The same run then
  arms the PR (agent.yml `arm`, App token, `--match-head-commit`), so no person
  is asked at any step. Nish's typed comment or app review stays an optional
  override. The gate and `hold-risky` read their programs and the path list from
  the base branch, so a PR cannot loosen the rules that judge it in the same PR;
  agent-authored PRs self-land green. The in-session held-PR approver loop (a
  coordinator subagent polling every 20 minutes) is retired: the
  `review-risky` event's review job decides it, and no session polls for it
  (docs/incidents/2026-10-08-held-pr-approver-loop-retired.md, fleet-ops#9459).

The full audit (rungs, counts, second wave) is git history
(fleet-ops#8029/#8034).

## Resilience on one box

Detection + repair, not blind duplication. `Restart=`/`OnFailure=`
(`OnFailure=fleet-unit-failed@%N.service` → healthchecks.io fail ping),
and external healthchecks.io dead-men (URLs in
`~/.config/fleet-ops/keystone-hc.env`; unset = LOUD skip, shared = LOUD fail)
cover supervision. Restic R2 backup / verify / restore-test run as ROOT units
on the host (`/etc/systemd/system/restic-r2-*`, installed outside this repo)
and publish restore proofs.
SSH is Tailscale-only, so the out-of-band layer is the netcup VNC console
(RUNBOOK). GitHub-hosted runners are the compute break-glass. No second box,
no second dispatcher, no Kubernetes.

## Organs: reuse before you build

Before building a retry loop, cooldown, poller, queue daemon, watchdog or
dispatcher, find the existing owner. systemd primitives replace the bans:
`Restart=`/`WatchdogSec=`/`StartLimitBurst=`, `RestartSec=`+`StartLimitInterval`,
a `.path` unit or a named-reason timer, a `systemd-run --user` transient unit,
or Pi's stock dispatch (`.github/workflows/agent.yml`). If no existing
owner fits, open a design proposal through the senior-conference channel — do
not build by fiat.

## CI standard (the parts that stay)

- **Required checks are pure:** a required check must be a function of the
  PR's own diff. Fail on exceeding a ceiling, never on exact equality against
  a shared baseline (exact equality is correct only for pinning a downloaded
  binary). Tighten ceilings on `main` after merge.
- **Classify before retrying:** assertion failure → stop and change the code;
  infra/network/timeout → retry with backoff. A repeat-deterministic failure
  signature needs a fix, not a re-arm.
- **Red-on-main is a detector, not a reverter.** Auto-revert may only watch a
  workflow that is already green on `main`.
- **A repair PR may jump the queue** (`repair:` label) but never bypasses a
  required check.
- Org rulesets are a paid GitHub tier; the free-plan probe is a SKIP, never a
  pass.
