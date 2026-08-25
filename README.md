# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — user units (services + timers) the fleet runs under
  `systemctl --user`.
- `bin/` — shell scripts the units exec.
- `prompts/` — Pi agent prompts fed to workers on stdin.
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
  scout/intake timers are armed, update the `last-heartbeat:` stamp in the
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

## Excluded pending manual review

- `inish-publish-on-token.path`
- `backlog-console-refresh.service.retired-20260819`

## Live paths are NOT touched by this repo

This repo copies files in. The symlink cutover (making the live paths point
here) is a separate, later step. Until then the live paths are real files and
`install.sh --check` will report every entry as a DIFF.
