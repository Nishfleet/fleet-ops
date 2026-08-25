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
./install.sh          # symlink MANIFEST entries into live paths, daemon-reload
./install.sh --check  # report drift only, change nothing
```

install.sh is hand-written because no platform feature installs from an
explicit manifest; GNU stow was rejected because its directory-sweep semantics
conflict with the allowlist requirement (only listed files install, nothing
more).

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
`(workflow, job, step, assertion)` signature fails 3+ times within 6h — an
assertion failure is not retryable, so the alert says stop, do not re-arm).

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

## systemd-oomd — the reactive last resort (issue #62)

There is no automatic RAM manager on the box by default. `systemd-oomd` is the
built-in Linux answer; it is installed and enabled on the host, and this repo
holds its fleet-scoped policy. Killing is the **exception**, not the norm —
three layers own memory, in order, and oomd is the last:

| | mechanism | effect | owns which failure |
|---|---|---|---|
| 1 | `MIN_FREE_RAM_MB=2500` launch floor (~13.1 GiB soft cap) | **prevents** work starting | the box is filling up — stop adding work |
| 2 | per-worker `MemoryHigh=3G` / `MemoryMax=6G` on `pi-issue@.service` | **throttles** and reclaims one worker; nothing dies | one worker is runaway |
| 3 | `systemd/app-pi\x2dissue.slice` (`ManagedOOMMemoryPressure=kill` @ 80%/60s) | **kills** a cgroup | 1 and 2 have both failed — host is in trouble |

The policy lives on the worker slice only. `sshd`, `tailscaled`,
`fleet-heartbeat` and the intake timers stay `auto`, so oomd can never take a
lifeline or the supervisor that would repair a reaped worker. `ManagedOOMSwap`
is left `auto` on purpose: ~4.7 GiB of swap in use with zero pressure is
healthy here (workers idling on API calls), and killing on swap would reap
useful work.

The 80%/60s threshold is **measurement-derived**, not a default: baseline
`/proc/pressure/memory` `some avg10` = 0.00 across 5 samples with the fleet
running, so 80% sustained for a full minute is nowhere near normal. The global
`DefaultMemoryPressureDurationSec=60s` lives in `/etc/systemd/oomd.conf.d/` on
the host (root-owned system config, not this user-config repo — recorded here
so it is findable).

### Proving it: `oomd-drill`

A rollout without a drill is not done. `bin/oomd-drill` drives a bounded
(`MemoryMax=1G`) memory hog inside `oomd-drill.slice` — which carries the same
`ManagedOOMMemoryPressure=kill` mechanism behind a low 5% trip point — and
confirms oomd's own journal shows a managed kill while every lifeline stays
live.

```
oomd-drill          # run the drill, print proof, exit 0/1
oomd-drill --check  # report whether oomd + the drill units are in place
```

**Drill record, 2026-08-26 01:24:33 IST** — oomd killed a memory-hog cgroup:

```
systemd-oomd: Killed .../oomd-drill.slice/oomd-drill-hog.service due to memory
pressure for .../user@1000.service being 75.07% > 50.00% for > 1min with
reclaim activity
```

The hog hit `Pressure: Avg10: 98.76`. ssh, `fleet-heartbeat`, and the
`pi-intake` timers stayed live throughout (zero failed user units, all timers
active). The managed-kill mechanism fires and spares lifelines.

What the drill proves and what it does not: it proves oomd's managed-kill path
fires under pressure and is safely scoped. It does **not** drive the production
slice to 80% live (that would throttle real workers); the 80% trip point is
calibrated from measurement instead. `systemd/systemd#33486` reports cases
where a pressure limit does not fire as expected — re-run `oomd-drill` after any
oomd or kernel upgrade to confirm the path still trips.

