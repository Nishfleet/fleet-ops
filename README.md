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

### System-scope entries (fleet-ops#71)

The MANIFEST may list entries under `/etc/systemd/system/...` — those are
SYSTEM scope and need root to install. `./install.sh` (default) SKIPS them;
run `./install.sh --system` to install them. `--system` is non-interactive
(it checks `sudo -n true`; if sudo requires a password, it refuses with a
loud error and the exact manual command to run, so a worker can never hang
on a sudo prompt). Drift on system entries is also worth checking from
heartbeat tier 1: `./install.sh --check --system` exits nonzero on any
byte-difference.

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

A fifth reusable workflow, `.github/workflows/ci-failure-telemetry.yml`, is
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

## Allowlist

Only the files listed in `MANIFEST` are tracked and installed. Nothing else
from `~/.config/systemd/user/`, `~/.local/bin/`, or `~/.pi/agent/prompts/` is
swept in. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`, `cf.env`) are
never tracked — only the units that reference them.

## Fleet heartbeat (durable, session-independent)

`fleet-heartbeat.timer` + `fleet-heartbeat.service` keep the fleet flowing
even when every interactive Claude / Pi session dies. The old session-bound
watcher/cron died 4x in one day on session hops — this one is owned by the
user systemd instance (Persistent=true), not by any agent or tmux session.

Two-tier design (so the heartbeat still works if every LLM is dead):

- **Tier 1 (deterministic, every tick, no LLM)**: queue green fleet PRs,
  release orphaned claims, log failed units into the triage file, verify
  scout/intake timers are armed, re-examine `agent-blocked` issues (re-queue
  when a listed dependency has closed/merged; publish count and oldest age
  for Nish-decision blocks), update the `last-heartbeat:` stamp in the
  playbook. Plain bash + gh + jq. Zero quota.
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
this file is the coverage decision (#25) it consumes.

## Excluded pending manual review

- `inish-publish-on-token.path`
- `backlog-console-refresh.service.retired-20260819`

## Live paths are NOT touched by this repo

This repo copies files in. The symlink cutover (making the live paths point
here) is a separate, later step. Until then the live paths are real files and
`install.sh --check` will report every entry as a DIFF.

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


