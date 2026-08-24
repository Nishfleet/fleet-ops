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

## Excluded pending manual review

- `inish-publish-on-token.path`
- `backlog-console-refresh.service.retired-20260819`

## Live paths are NOT touched by this repo

This repo copies files in. The symlink cutover (making the live paths point
here) is a separate, later step. Until then the live paths are real files and
`install.sh --check` will report every entry as a DIFF.
