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
  status on it (0509#7092). ci.yml's `coordinator-approval` job applies the same
  test on `merge_group`, so once it is a required check (fleet-ops#9383) a hand
  enqueue is rejected too; the ruleset's admin bypass actor can still skip it;
  agent-authored PRs self-land green.

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
