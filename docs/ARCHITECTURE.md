# Architecture

One page. What the fleet is, how its parts fit, and the rules that are enforced
today. `README.md` is the operational front door; `docs/RUNBOOK.md` is the
operator sequence. Where this page and a live file disagree, the live file wins
(`config/litellm-proxy.yaml`, the systemd units, the workflows).

## Shape

One VPS (netcup), one `nish` user. Everything the fleet runs is a
`systemctl --user` unit whose file lives in `systemd/` and is linked into
`~/.config/systemd/user/` by hand once; a `git pull` is the deploy
(see README, and RUNBOOK for the wiring rules). GitHub is the durable copy of
code and config.

The work loop: `.github/workflows/agent-dispatch.yml` queues `agent-ready` issues as `agent.yml` jobs on the VPS self-hosted runners, workers open PRs on `claim/issue-<N>`, and the GitHub merge queue lands them.
Alerts reach repair through `prometheus-am-executor` → `alert-repair@`.
The scout and `fleet-gardener` are scheduled jobs in `.github/workflows/agent.yml` (fleet-ops#8433); the daily view is the saved searches in the README.

## Model plane

Pi reaches models through the LiteLLM proxy on `127.0.0.1:4000`
(`fleet-litellm-proxy.service`), backed by a fleet-owned Postgres and Redis
(`fleet-litellm-postgres.service`, `fleet-litellm-redis.service`). Seats and
model groups are declared in `config/pi-models.json` and
`config/litellm-proxy.yaml`; **those files are the router record — no mirror
doc.** Group health is `litellm_deployment_state` on `/metrics` and
`/health/readiness`.

`POST 127.0.0.1:4000/jev` is the typed-decision pass-through (boolean / choice
/ score questions with probabilities). Its one tuning knob — the per-site band
edges — lives in RUNBOOK, and each caller's prompt carries the comparison it
applies. Every /jev body carries `custom_llm_provider: "vercel_ai_gateway"`
at top level (fleet-ops#8713).

## Worker isolation (containers)

Each Pi worker runs in a rootless-podman container generated from a Quadlet
file under `systemd/` (`fleet-container.slice`). The image tag pins the Pi
version; the only writable host bind is that worker's issue worktree, the
mirror is read-only, and `~/.pi/agent` is an overlay mount. Network is host
loopback only (`slirp4netns:allow_host_loopback`); the model is reached as
`litellm.fleet.local:4000`, and an nftables table keyed on the container
slice's cgroup rejects egress except loopback, GitHub's published CIDRs and
the slirp subnet. Named loss: a containerized worker routes models through
LiteLLM only — a direct-provider seat would need that provider's CDN ranges
opened, so it is not containerized.

Unit exit codes propagate, so `Restart=`, `StartLimitBurst=` and the
`ExecStopPost` artifact check (`test -s "$DELIVERABLE"`) all still work.

## GLUE-ZERO — no hand-rolled code

Nish, 2026-09-21: *"wipe and replace with properly done up design with no
glue."* The rule, and it is enforced by the `no-glue` job in
`.github/workflows/ci.yml`:

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
  each runner's `MemoryMax=6G` in `agent.slice`.

The design record with the full organ-by-organ reasoning is git history
(fleet-ops#7828); this page keeps only what is enforced.

## TRUST-STACK — verification and the correction ladder

The rules still in force:

- **Concurrency is governed by capacity; merging is governed by
  verification.** Fan out to the RAM / seat / per-worker caps, but nothing
  reaches `main` without its required checks.
- **CI green is an input to a verdict, not a verdict.** A behavioural change
  needs a live or test-verified proof; a docs change does not.
- **A unit's verifier runs on a different model family from its builder.**
  Where the router cannot supply one, the packet says so rather than claiming
  a review it did not get.
- **The correction ladder.** A correction is encoded at the lowest rung that
  holds it: 1 structure (no file to put the mistake in), 2 static gate (CI
  check, ruleset, systemd property, router config), 3 rule, 4 skill, 5 prose.
  `encoded: 5` is legal only with a reason. A rule that recurs twice is a
  defect in its rung.
- Gates that exist: `blocked-by-judge` stops the arm (fleet-ops#4557); an
  armed PR with no verification receipt is disarmed (fleet-ops#3731);
  agent-authored PRs self-land green.

The full audit (rungs, counts, second wave) is git history
(fleet-ops#8029/#8034).

## Resilience on one box

Detection + repair, not blind duplication. `Restart=`/`OnFailure=`, the
failed-unit sweep, and external healthchecks.io dead-men (URLs in
`~/.config/fleet-ops/keystone-hc.env`; unset = LOUD skip, shared = LOUD fail)
cover supervision. Restic R2 backup / verify / restore-test run as ROOT units
and publish restore proofs; `ResticRestoreProofStale` and `LitellmPgDumpStale`
(page `config/fleet_rules.yml`) make a stale proof reach the repair path.
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
