# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — user units (services + timers) the fleet runs under
  `systemctl --user`.
- `bin/` — shell scripts the units exec.
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `seat-caps.json` is the per-seat ceiling
  map; `intake-repos.json` is the declared set of repos enrolled in
  pi-intake/pi-scout (see [Intake enrolment](#intake-enrolment)).
- `MANIFEST` — one line per file: `<repo-relative-path> <absolute-install-path>`.
- `install.sh` — symlinks each manifest entry into its live path, then
  `systemctl --user daemon-reload`. `--check` reports drift without changing
  anything (exits nonzero on any difference).

## Install

```
./install.sh              # user-scope only: symlink MANIFEST entries, systemctl --user daemon-reload
./install.sh --system     # system-scope only: copy /etc/systemd/system drop-ins, sudo systemctl daemon-reload
./install.sh --check      # drift detection for user-scope entries
./install.sh --check --system  # drift detection for system-scope entries
```

install.sh is hand-written because no platform feature installs from an
explicit manifest; GNU stow was rejected because its directory-sweep semantics
conflict with the allowlist requirement (only listed files install, nothing
more).

install.sh refuses to overwrite a live file whose mtime is newer than the
repo copy. That stops a stale checkout from replacing live seat caps.

### Canonical checkout (fleet-ops#372)

Live install source, the only tree `install.sh` and the heartbeat deploy
step may run from:

`/home/nish/workspaces/tooling/fleet-ops-deploy-clone`

`fleet-heartbeat.service` pins `FLEET_OPS_CHECKOUT` to that path.
`fleet-blind-audit.service` pins `AUDIT_REPO_ROOT` to the same path
(fleet-ops#367). A run pointed at `products/fleet-ops` or the worktree
parent retargets to the deploy-clone and auto-files
`audit-target-noncanonical: fleet-ops#367`.
`products/fleet-ops` still points at the worktree parent
(`/home/nish/workspaces/tooling/fleet-ops`) until no linked worktrees
remain there. `fleet-ops-retarget-products` (run with `--apply` by the
drift canary) then points the symlink at the deploy-clone. That parent
holds linked worktrees and carries the pre-rewrite init history (16
commits with no merge-base against `origin/main`). Do not install from
it. Do not delete it while worktrees are attached. New fleet-ops
worktrees are created from the deploy-clone (fleet-ops#410).

The drift canary compares live-installed files to `origin/main` blobs, not
to the checkout working tree, so it cannot self-compare. It also fails if
any installed unit file or enable-link resolves into `/tmp`, `/run`, or
`agent-worktrees`.

`install.sh` (mutating modes) and `fleet-ops-deploy` refuse to run from any
path under `/home/nish/workspaces` that is not that canonical checkout.
`--check` still runs from a worktree so an auditor can see DIFF. Override
with `FLEET_OPS_ALLOW_NONCANONICAL=1`. The drift canary tags
`DRIFT-SOURCE` and auto-files when live dests point at a non-canonical
workspaces tree (fleet-ops#176).

The deploy-clone itself must stay on branch `main`. Feature and auditor
work uses a linked worktree. Heartbeat merge-to-live blocks and the
drift canary auto-files `deploy-clone-off-main: fleet-ops#477` if a
named non-main branch is checked out there.

### System-scope entries (fleet-ops#71)

The MANIFEST may list entries under `/etc/systemd/system/...` and
`/etc/prometheus/...` — those are SYSTEM scope and need root to install.
`./install.sh` (default) SKIPS them. Heartbeat `fleet-ops-deploy` runs
`./install.sh --system` after the user-scope install and reloads prometheus
when that unit is active, so `fleet_rules.yml` actually loads
(fleet-ops#1247). A hand-run of `./install.sh --system` still works.
`--system` is non-interactive (it checks `sudo -n true`; if sudo requires a
password, it refuses with a loud error and the exact manual command to run,
so a worker can never hang on a sudo prompt). Drift on system entries is
also worth checking from heartbeat tier 1: `./install.sh --check --system`
exits nonzero on any byte-difference.

The two system drop-ins repo-owned by `#71` are the fleet RAM governor
themselves — see [docs/ram-governor-tree.md](docs/ram-governor-tree.md) for
the full five-layer policy tree and what each layer does.

## Dispatch a packet that outlives this session

`nohup pi ... &` dies when the launching shell ends. The four `EXTLOAD-OK`
lines it leaves behind look like a dead seat. Use the thin systemd wrapper:

```
pi-systemd-run --unit mypacket --stdin /path/to/packet.md -- \
  pi --print --provider minimax --model MiniMax-M3
```

That is `systemd-run --user --collect --no-block`. Not a dispatcher: no
retry ladder, no seat rotation, no queue. Watch with
`systemctl --user status mypacket.service`.

A short log with no verdict after `nohup` or `&` is a **launcher fault**
(the session reaped the process). A log containing `rate_limit` /
`ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do not mix
them up.

The `pi-packet-guard` (and the Claude PostToolUse hook that calls it)
classifies these automatically from the redirected packet log. Launcher
faults advise `pi-systemd-run`; lane faults advise seat rotation.

Overlapping `systemctl start` of a live intake tick is a no-op
(`pi-intake-run` flock). Starting a live `pi-issue@` worker is a no-op
(`pi-issue-start`). The failed-reaper will not release a claim while that
worker still has a MainPID.

## Claim shared files before editing (interactive sessions)

Queued work has an atomic lock — the `claim/issue-N` branch. Interactive
sessions used to bypass it, so two agents could fix the same control-plane
file minutes apart without either knowing (fleet-ops#55: two sessions
fixed the same `seat-lib.sh` bug in one hour). `bin/fleet-claim` gives
interactive work a claim path that is one command, agent-agnostic (git +
gh, not a Claude hook), and visible before any PR exists — a pushed branch
is the fleet-visible occupied sign.

Before touching anything shared (`seat-lib.sh`, `seat-caps.json`, a systemd
unit, a hook, this repo), run:

```
fleet-claim conflicts fleet-ops lib/seat-lib.sh   # pre-flight: anyone on it?
fleet-claim start    fleet-ops lib/seat-lib.sh    # reserve it (one command)
# ...edit, commit, push, open PR...
fleet-claim release  fleet-ops lib/seat-lib.sh    # free it when done
```

- `start` pushes `claim/adhoc-<scope>` from `main` with a create-only
  `--force-with-lease`, so two agents starting the same scope collide
  atomically — the second gets `claimed-by-other` and stops. Convention:
  **use the shared file path as the scope** so two agents on the same file
  pick the same branch name.
- `conflicts` is the pre-flight the standing rule asks for, made
  agent-agnostic. It scans every live `claim/adhoc-*` branch whose scope
  token matches the file path **or basename**, plus every open PR whose
  file set overlaps (via `gh`, when available). Exit 1 if anything is
  found. Basename matching catches the realistic case where two agents
  name the same file differently (`lib/seat-lib.sh` vs `seat-lib.sh`).
- `check <scope>` reports free/claimed for one scope; `release <scope>`
  deletes the branch.

It is warn-shaped, not a hard block: a second agent on the same file is
sometimes legitimate, and a false block during control-plane repair is
worse than a duplicated diff. The Claude-only `guard_shared_file_collision`
hook covers the open-PR window; `fleet-claim` covers the pre-PR window that
the hook cannot see.

Stale interactive **sessions** (idle past 8 hours with no jsonl tool-call)
are reaped by `interactive-session-reap.timer` (hourly at :41, fleet-ops#85).
Activity is the Claude transcript mtime for `--resume=<uuid>`, not journal
lines (those are sshd/sudo noise). Reap is SIGTERM, a 15s grace, then
SIGKILL. A dirty worktree or a live `claim/issue-*` / `claim/adhoc-*`
branch skips the session. sshd, tailscaled, fleet-heartbeat, and intake
timers are out of scope: they do not live in `session-*.scope`. The durable
heartbeat still reaps orphaned `claim/issue-*` branches (queued work);
`claim/adhoc-*` branches are released by the agent that claimed them.

## CI

`.github/workflows/ci.yml` runs four jobs on every PR and push to main:

1. **semgrep** — `--config p/default`. TODO: add the fleet's
   `no-hand-built-orchestration.yml` ruleset from Nishfleet/siterep-public at
   an exact commit SHA once packet p56 merges it. Until then the
   orchestration-specific rules are NOT applied — flagged loudly.
2. **shellcheck** — `bin/*` and `install.sh` (pinned binary + sha256).
3. **unit-verify** — `systemd-analyze verify --man=no` on every `systemd/*`
   file. Proven to catch breakage: a malformed unit (bad section header,
   missing `=`) makes verify exit nonzero with a clear message.
4. **gitleaks** — full history secret scan (pinned binary + sha256, `--redact`).

All actions are pinned to exact commit SHAs. Every job has a timeout.

The tests job calls `.github/workflows/reusable-pr-checks.yml` (`workflow_call`).
That file is the batched CI standard for every current and future repo: one
job, `timeout-minutes`, PR concurrency, npm cache, job-level path gating, and
gitleaks. Callers pass `inputs`; they do not copy the steps. The four required
check names stay as local jobs because a `uses:` job reports as
`caller / callee` and branch protection still lists `Gitleaks`, `Semgrep`,
`Shellcheck`, and `systemd-analyze`.

New repos copy `template/.github/workflows/` (wired to this repo at `@v1`).

A further reusable workflow, `.github/workflows/ci-failure-telemetry.yml`, is
the central CI failure telemetry set. Other repos call it with
`workflow_call`; it is an alert, not a required check. It runs two detectors:
the merge-queue semantic-conflict detector (fires when the same check is
green on `pull_request` and red on `merge_group`, names the check, and
publishes the `pull_request` vs `merge_group` failure-rate split) and the
repeat-deterministic detector (fires when the same
`(workflow, job, step, assertion, event)` signature fails 3+ times within
6h — an assertion failure is not retryable, so the alert says stop, do not
re-arm). Both detectors also publish a headline decomposition: top failure
signatures ranked by count (every distinct tuple, not just the ones that
fired the alert) and the `pull_request` vs `merge_group` divergence in
percentage points — the single most diagnostic number for whether failures
are semantic merge conflicts (large divergence) or flaky tests (small
divergence). A headline "21.8% CI failure rate" without this decomposition
cannot drive any action (fleet-ops#21).

A sixth, `.github/workflows/ci-required-check-purity.yml`, flags required
checks that compare a computed value against a shared committed baseline
with exact equality (or that fail unless the PR edits that baseline). It
is advisory: warn, do not block. The rule itself is in `docs/ci-standard.md`.

A seventh pair, `.github/workflows/red-on-main-detector.yml` (reusable) and
`.github/workflows/red-on-main-watch.yml` (15-minute sweep, synced to other
Nishfleet repos), watches **every** workflow on main — including ones that
have never been green. Auto-revert still only watches proven-green
workflows; this detector alerts, it does not revert. A workflow whose
first ever main run fails is called out as merged untested against main.

An eighth, `.github/workflows/ci-standards-audit.yml`, is the central
conformance audit. It reads every non-archived repo from the GitHub API,
resolves each repo's real default branch, then publishes a per-repo,
per-workflow gap matrix for the CI standard: `timeout-minutes` on every
job, `concurrency` with `cancel-in-progress` on PR-triggered workflows,
dependency caching, job-level path filtering (with trigger-level path
filters on required checks flagged as an error), and `auto-revert.yml`
presence and eligibility. It can also open fix PRs for the one gap that is
safe to fix mechanically: missing `auto-revert.yml` on repos that already
have a green push-to-main CI workflow and required checks.

## Allowlist

Only the files listed in `MANIFEST` are tracked and installed. Nothing else
from `~/.config/systemd/user/`, `~/.local/bin/`, or `~/.pi/agent/prompts/` is
swept in. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`, `cf.env`) are
never tracked — only the units that reference them.

## Codex orphan app-server (fleet-ops#78)

An unmanaged `codex app-server` on the control socket blocks
`codex-remote-control.service` (`app server is running but is not managed
by codex app-server daemon`). Killing it mid-week severs live peer
connections.

`bin/codex-orphan-reap` kills that orphan, starts the managed unit, and
proves takeover with `codex remote-control pair --json`. It refuses unless
the weekly window is open (`maintenance.json` status `paused` or
`quiescing`) or there are zero peer connections. A listener already named
by the daemon pid file is left alone — next week's window must not kill
the healthy daemon.

The weekly update runs it as `ExecStartPre=-` (Sun 03:30 IST, after the
15-minute quiesce drain). The leading `-` means a failed reap cannot skip
apt. Do not run it by hand while the flag is `clear` and peers are live.

## Fleet heartbeat (durable, session-independent)

`fleet-heartbeat.timer` + `fleet-heartbeat.service` keep the fleet flowing
even when every interactive Claude / Pi session dies. The old session-bound
watcher/cron died 4x in one day on session hops — this one is owned by the
user systemd instance (Persistent=true), not by any agent or tmux session.

Two-tier design (so the heartbeat still works if every LLM is dead):

- **Tier 1 (deterministic, every tick, no LLM)**: queue green fleet PRs,
  release orphaned claims, recover failed fleet units then surface what remains
  in triage (no direct Telegram page), verify scout/intake timers are armed,
  re-examine `agent-blocked` issues, check `pi-seat-health.json` is fresh
  (`observed_at` < 90 min), update the `last-heartbeat:` stamp in the
  playbook. Also re-dispatches repair workers onto orphaned red fleet-worker
  PRs whose worker has exited (debounced one tick, bounded 2 attempts, then
  fail-loud into the unit-escalation path). Plain bash + gh + jq. Zero quota.
  A successful tick also pings healthchecks.io (`HC_URL` in
  `~/.config/fleet-heartbeat/hc.env`, same dead-man pattern as siterep-uptime)
  so a masked or dead timer is visible off-box.
- **Tier 2 (judgment, only when the triage file is non-empty or the held
  queue has dispatchable items)**: walk a seat ladder
  `claude -p --model claude-opus-5` → `pi --print --provider devin
  --model glm-5-2` (after a 30 s probe) → `pi --print --provider minimax
  --model MiniMax-M3`. First healthy seat wins; all dead → loud triage
  line + unit FAILS (systemd's `state=failed` is the page).

Freshness guard: the orchestrator entry reads the plan file's
`last-heartbeat:` line and exits 0 immediately if < 20 minutes old, so the
durable timer does not thrash against a live interactive session.

Schedule: every 30 minutes at minute `:17` (off-peak — avoids the cluster
of fleet timers firing at :00, :13, :15, :23, :38, :39, :43, :48, :52).

Prompt: `prompts/heartbeat.md` — provider-neutral (no Claude-specific
tool references). Plain instructions any agent with shell + `gh` executes.

## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
pi-intake/pi-scout. It is the single source of truth for which repos are
enrolled — adding or removing a repo is a PR against that file, not a
`systemctl enable`. This replaces the old imperative enrolment that was
silently reverted without a record (fleet-ops#32).

Each enrolled repo needs two preconditions, both verified by the reconciler
before its unit is enabled:

1. A git checkout at `/home/nish/workspaces/products/<name>` — intake does
   `git -C <checkout>/<name> fetch origin` and the worker creates its
   worktree from it.
2. The three labels `agent-ready`, `agent-in-progress`, `agent-blocked`
   present on the repo — the `ExecCondition` in `pi-intake@.service`
   silently no-ops without them, so an `agent-ready` issue on a label-less
   repo looks queued and is actually inert (the gap fleet-ops#25 was filed
   for).

`fleet2` is permanently excluded (standing rule: no second dispatcher,
ever). `siterep` is excluded (archived). Both are recorded in the file's
`excluded` list with reasons, and `tests/intake-repos-shape.test.sh`
fail-closes if `fleet2` ever reappears in `repos`.

The reconciler that converges systemd state to this file is fleet-ops#32;
this file is the coverage decision (#25) it consumes. The reconciler is
`bin/intake-reconcile`, triggered by `systemd/intake-reconcile.{path,
service,timer}` (file-change trip + 30-minute sweep). Every enable, disable,
mask-detect or precondition-fail writes one line to
`$HOME/.local/state/intake-reconcile/audit.log` with
`<iso8601> <unit> <action> actor=reconciler why=<reason>` so the four
silent reversions that prompted this issue have no recurrence path.

## Excluded pending manual review

- `inish-publish-on-token.path`
- `backlog-console-refresh.service.retired-20260819`

## Live paths are NOT touched by this repo

This repo copies files in. The symlink cutover (making the live paths point
here) is a separate, later step. Until then the live paths are real files and
`install.sh --check` will report every entry as a DIFF.

## Four-plane resilience drill — `fleet-resilience-drill` (issue #455)

Single-VPS resilience is detection + repair + a regular drill, not a second
copy of a stateless thing. The adopted-delta list and specs live in
[docs/resilience-blueprint.md](docs/resilience-blueprint.md). The VNC
break-glass runbook is [docs/break-glass-access.md](docs/break-glass-access.md).

```
fleet-resilience-drill          # run the four-plane drill, print proof, exit 0/1
fleet-resilience-drill --check  # report whether the repo files are present
```

The drill never kills live tailscaled or live heartbeat. Resurrection is an
isolated `Restart=always` stub. State recovery reuses #388. Compute
break-glass is GitHub-hosted runners. Keystone healthchecks.io URLs (intake,
scout, reconcile, restore) live in `~/.config/fleet-ops/keystone-hc.env`
and must be four checks distinct from the heartbeat dead-man. Unset URLs
are a LOUD skip. A shared URL is a LOUD fail.

## systemd-oomd drill — `oomd-drill` (issue #62)

The fleet's RAM policy is a five-layer tree, owned by this repo and documented
in [docs/ram-governor-tree.md](docs/ram-governor-tree.md). `systemd-oomd` is
the reactive last resort; the 2026-08-26 01:24 IST drill proved its managed
kill path fires under pressure (provenance recorded in
`systemd/app-pi\x2dissue.slice`).

That drill was run ad-hoc via `systemd-run`; this repo now holds the
reproducible tooling so it can be re-run after any oomd or kernel upgrade:

```
oomd-drill          # run the drill, print proof, exit 0/1
oomd-drill --check  # report whether oomd + the drill units are in place
```

`bin/oomd-drill` drives a bounded thrasher (`MemoryHigh=128M`, `MemoryMax=1G`,
`MemorySwapMax=0`) inside `oomd-drill.slice` — which carries the same
`ManagedOOMMemoryPressure=kill` mechanism behind a low 5% trip point — then
confirms oomd's own journal shows the managed kill (not the kernel OOM killer,
not systemd's `RuntimeMaxSec` backstop) and that `sshd`, `tailscaled`,
`fleet-heartbeat` and the intake timers stayed live. It proves the mechanism
fires and is safely scoped; the production 80% trip point is calibrated from
measurement (see the governor tree), not driven live, since doing so would
throttle real workers. `systemd/systemd#33486` notes pressure limits can fail
to fire — re-run `oomd-drill` after any upgrade to confirm the path still
trips.

## Worker RAM measurement — `ram-measure` (issue #45)

`ram_gb_per_worker` in `config/seat-caps.json` is the governor budget the
RAM governor divides `MemAvailable` by. It is sized on typical-worker
cgroup `memory.current` (0.6 GiB, fleet-ops#1168) with the tail bounded
three ways (per-worker `MemoryHigh=3G` throttle, `MemoryMax=6G` hard stop,
and `TimeoutStartSec=45min` to kill a wedge). A re-derive is one command:

```
ram-measure                          # one-line summary
jq '.history[0]' ~/.local/state/ram-measurement/ram-measurement.json
```

`bin/ram-measure` walks every `pi-issue@*.service` and `pi-packet@*.service`
unit, pulls `MemoryPeak` (bytes) from `systemctl show`, and reports count,
mean, median, p95, and max in GiB plus a per-unit breakdown. State lives at
`~/.local/state/ram-measurement/ram-measurement.json` with a rolling
10-run history. The fleet-heartbeat calls it once per tick (section 14 of
`bin/fleet-heartbeat-tier1`) so a re-derive is a one-time `jq` over the
history, not a re-read of a comment. Pure observability — never a gate, never
an escalation, never an edit to the cap map.

`bin/ram-metric-compare` (fleet-ops#202) samples live `pi-issue@` units for
both cgroup `memory.current` and process VmRSS. The 35 MB figure in older
comments is VmRSS, not cgroup cost. Live 2026-08-26: `memory.current` p95
was 822.6 MB. The compare command records both every tick. fleet-ops#489
decided to keep `memory.current` for admission. fleet-ops#1168 then set
`ram_gb_per_worker` to 0.6 GiB from the live typical-worker measurement
(the 1.5 GiB figure was the p95*3 clamp).


