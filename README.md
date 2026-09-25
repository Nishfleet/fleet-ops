# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — user units (services + timers) the fleet runs under
  `systemctl --user`.
- `bin/` — shell scripts the units exec.
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `intake-repos.json` is the declared set of
  repos enrolled in the agent-ready queue (see [Intake enrolment](#intake-enrolment)).
- `systemd/fleet-sync.service` (started by
  `.github/workflows/deploy-box.yml` on push) — the whole deploy mechanism:
  `git pull --ff-only` + `systemctl --user daemon-reload`, plus
  `promtool check rules` / `promtool check config` and a prometheus reload
  when the alert rules or the scrape config changed, and a LINK-GUARD pass
  that fails the unit on a dangling or throwaway-target live symlink
  (fleet-ops#7743).

## Install

There is no installer. Every live user-scope path is a **symlink into this
repo**, so a `git pull` is the deploy — the file the fleet runs and the file
in git are the same inode. Nothing is copied, so nothing can drift, and the
5,948 LOC that used to copy files and then hunt for the drift copying caused
(`install.sh`, `MANIFEST`, `bin/fleet-ops-deploy`, `bin/fleet-deploy-check`,
`bin/fleet-ops-drift.py`) were deleted on 2026-09-18.

`deploy-box.yml` starts `fleet-sync.service` on every push to main, which
keeps the clone current. It is the only deploy machinery on the box:

```
systemctl --user status fleet-sync.service
systemctl --user start fleet-sync.service   # force a sync now
journalctl --user -u fleet-sync.service -n 50
```

`git pull --ff-only` fails loudly on a dirty or diverged clone. That is
correct: the live source must be clean `origin/main`, and a failed
`fleet-sync.service` is visible to the failed-unit sweep.

### Wiring a NEW unit (one-time, by hand)

`man systemctl`: *"link PATH... Link a unit file that is not in the unit file
search path into the unit file search path. This command expects an absolute
path to a unit file."* Add the unit file to `systemd/`, merge it, then once:

```
systemctl --user link  /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>
systemctl --user enable --now /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>   # timers and .path units
systemd-analyze verify /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>
```

`systemctl --user list-unit-files | grep linked` shows the linked set.
Retiring a unit is the mirror image: `systemctl --user disable --now <unit>`
then `systemctl --user unlink <unit>` (or `rm ~/.config/systemd/user/<unit>`)
and delete the file from `systemd/`.

Drop-in directories (`<unit>.service.d/*.conf`) are not unit files, so
`systemctl link` does not take them. Symlink them by hand, once:

```
mkdir -p ~/.config/systemd/user/<unit>.service.d
ln -sfn /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>.service.d/<x>.conf \
        ~/.config/systemd/user/<unit>.service.d/<x>.conf
```

Same idiom for a new Pi prompt (`~/.pi/agent/prompts/<x>.md`). One `ln -sfn`,
once, and git owns it from then on. New scripts are not added at all: the
glue-zero rule (docs/ARCHITECTURE.md) allows config values, unit lines and
prompt lines only — a stock feature replaces an organ or nothing does.

### The exceptions: files that must stay COPIES

Four classes are deliberately copies, not symlinks, and a `git pull` does
NOT update them. Refresh by hand when the repo file changes:

| live path | repo source | why a symlink is wrong |
|---|---|---|
| `/etc/prometheus/fleet_rules.yml` | `config/fleet_rules.yml` | prometheus runs as `prometheus`; `/home/nish` is `0750 nish:nish`, so it cannot traverse into the repo. **Handled automatically** by `fleet-sync.service` (promtool check + copy + reload). |
| `/etc/prometheus/prometheus.yml` | `config/prometheus.yml` | same privilege boundary. **Handled automatically** by `fleet-sync.service` (promtool check config + copy + reload). The #7954 alertmanager scrape job drifted here and left `FleetNishPageRailDown` red (fleet-ops#8084); that drift class is closed by the deploy step. |
| `~/.pi/agent/extensions/**.ts` | `template/extensions/**` | pi resolves a symlinked extension against its REAL path, so sibling imports would resolve into the repo (fleet-ops#3263). After the glue sweeps the only local files are the two stock forks (`permission-gate.ts`, `protected-paths.ts`) — everything else in `~/.pi/agent/extensions/` is a symlink straight into pi's shipped `examples/extensions/`. |
| `~/.pi/agent/models.json` | `config/pi-models.json` | **Handled automatically** by `fleet-sync.service` (cmp + install, fleet-ops#8568). A copy, not a symlink, because `~/.pi/agent` is an overlay mount in worker containers. |
| `~/.local/state/pi-packet/model-candidates.json` | `config/model-candidates.json` | live state the git working tree must not rewrite on every checkout (fleet-ops#2910/#3722/#3322). |
| `~/.pi/agent/settings.json` | `none (live-only)` | pi writes this file itself at runtime (provider/model switches and its own bookkeeping keys), so a repo copy would be overwritten and a symlink would fight pi. Every fleet caller passes `--provider litellm --model <group>`, so its `defaultProvider`/`defaultModel` affect only bare interactive `pi` runs (fleet-ops#8568). Its `compaction.reserveTokens: 40000` pairs with the worker `contextWindow: 296000` in `config/pi-models.json`: pi compacts at window − reserve = 256k (Nish 2026-09-25; was 88k under #8567), and pi sizes each reply as window − context − 4096, so a turn at 256k still gets its full 32k `maxTokens`. Every worker rung holds 256k+ (seat /models or spend-log prompts up to 416k). At 96000/8192 replies near 88k were cut to ~4.8k (fleet-ops#8634). The real model windows are ~1M; 128000 is a budget, not a limit. |
| `/etc/**` (systemd drop-ins, `sysctl.d`, `audit/rules.d`, `default/prometheus`, `prometheus/*.yml`) | `config/`, `etc/`, `systemd/system/` | cross a privilege boundary. |

```
# a changed pi extension:
install -D -m 0644 <repo>/template/extensions/<x>.ts ~/.pi/agent/extensions/<x>.ts
# a changed /etc file:
sudo -n install -D -m 0644 -o root -g root <repo>/<src> /etc/<dest>
sudo -n systemctl daemon-reload          # for /etc/systemd/system/**
sudo -n augenrules --load                # for /etc/audit/rules.d/**
sudo -n sysctl --system                  # for /etc/sysctl.d/**   (Nish-reserved)
# a changed root unit:
sudo -n systemctl link /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/system/<unit>
```

### Devin workspace-trust key (fleet-ops#4825)

`install.sh` used to merge `skip_workspace_trust: true` into
`~/.config/devin/config.json` on every deploy, so a Devin auto-update that
rewrote the config could not silently wall the seat. That merge is gone with
the installer. The live config carries the key today; if the Devin CLI ever
refuses with *"Refusing to run in an untrusted workspace"*, re-apply it once:

```
jq '. * ($o[0]) | del(.respect_workspace_trust)' --slurpfile o <repo>/template/devin-config.json \
   ~/.config/devin/config.json > /tmp/devin.json && mv /tmp/devin.json ~/.config/devin/config.json
```

### Canonical checkout (fleet-ops#372)

The live source — the tree every live symlink resolves into:

`/home/nish/workspaces/tooling/fleet-ops-deploy-clone`

It must stay on branch `main`, clean. Feature and auditor work uses a linked
worktree. `products/fleet-ops` still points at the worktree parent
(`/home/nish/workspaces/tooling/fleet-ops`) until no linked worktrees remain
there; that parent carries the pre-rewrite init history (16 commits with no
merge-base against `origin/main`). Do not deploy from it and do not delete it
while worktrees are attached. New fleet-ops worktrees are created from the
deploy-clone (fleet-ops#410).

The old non-canonical-checkout guard lived in `install.sh`: it refused a
mutating install from any other tree, because an install from a worktree
retargeted every live symlink at a tree that could be deleted. With no
installer there is no mass-retarget path, but hand wiring can still point
one link the wrong way — on 2026-09-18 a session linked the
`standing-rules-render` units and the vault canonical rules file into a
churning checkout, and they dangled when the files vanished, taking the
standing-rules render down (fleet-ops#7743). The guard for that is in
`fleet-sync.service`: the LINK-GUARD step fails the unit — on every deploy
push to main and at boot — while any symlink under `~/.config/systemd/user`,
`~/.local/bin`, `~/.pi/agent` or `~/workspaces/tooling/nish-vault` is broken
or resolves into a throwaway root (`*worktrees/*`, `agent-state`, `tmp`).
Live links belong to the canonical checkout and the stable install dirs
(`~/.local/share`, `~/.local/lib`), never to a tree a session can delete or
re-clone.

## systemd by default

A backgrounded `pi` dies when the launching shell ends, and the four
`EXTLOAD-OK` lines it leaves behind look like a dead seat. Detached runs are a
systemd transient unit. There is no wrapper script: `bin/pi-systemd-run` (523
lines) and `bin/pi-detached-deadman` (410 lines) were deleted on 2026-09-18 and
replaced by two stock `systemd-run` properties.

```
systemd-run --user --collect --unit <name> \
  -p RuntimeMaxSec=<seconds> \
  -E DELIVERABLE=<absolute artifact path> \
  -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' \
  -- sh -c 'cat /path/to/packet.md | pi --print --provider <provider> --model <model>'
```

`RuntimeMaxSec=` is the deadline: systemd kills an over-running unit into
`Result=timeout`. The `ExecStopPost=` line is the deliverable check: a stop at
exit 0 that left no artifact becomes `Result=exit-code`, i.e. `failed`, which is
what `OnFailure=` and the failed-units pass key off. Both halves were proven on
this host on 2026-09-18 (RED: no artifact -> `Result=exit-code`; GREEN: artifact
written -> `Result=success`; `RuntimeMaxSec=5` against `sleep 60` ->
`Result=timeout`).

Drop `--collect` when you want the dead unit to stay listed in
`systemctl --user list-units --state=failed`. With `--collect` systemd unloads
the unit as soon as it dies, so the failure survives only in the journal
(`journalctl --user -u <name>`).

Watch a live run with `systemctl --user status <name>.service`.

Not a dispatcher: no retry ladder, no seat rotation, no queue. `RuntimeMaxSec=`
and the deliverable check together are the whole of what the retired wrapper's
`--deadline` and `--deliverable` flags did (fleet-ops#4266); the healthchecks
dead-man ping and the `fleet_detached_job_died` gauge went with the script, and
the `DetachedJobDied` alert that read that gauge was deleted with them — systemd
already records the death.

If the packet clones a repo, use a reference clone against the local
bare mirror (fleet-ops#1213), not a full GitHub copy:

```
git clone --reference-if-able /home/nish/workspaces/.mirrors/<repo>.git \
  https://github.com/Nishfleet/<repo>.git <dest>
```

Never `--dissociate` on throwaway worktrees. Never push to a mirror
(read-only fetch target). A missing, stale or corrupt mirror degrades to a
plain clone — which is exactly why the `git-mirror-update` refresher was
deleted in the 2026-09-18 glue sweep: `--reference-if-able` borrows whatever
objects the mirror already has and fetches the rest from GitHub, so a mirror
that stops being refreshed costs a little bandwidth, never correctness. The
mirrors under `/home/nish/workspaces/.mirrors` are left in place (14G) and
are still worth borrowing from; refresh one by hand with
`git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all` if it ever
drifts far enough to matter.

One trap lives inside the mirror itself (fleet-ops#5737): a mirror whose
fetch refspec covers `refs/heads/*` and `refs/tags/*` only never updates any
leftover `refs/remotes/origin/*` refs — `git show origin/main:<file>` against
the mirror then silently serves hours-old content while `main` is current.
Map the heads namespace into the remote-tracking one so the two spellings
cannot disagree, then refresh:

```
git -C /home/nish/workspaces/.mirrors/<repo>.git config --add \
  remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all
```

Every fetch then force-moves `refs/remotes/origin/*` to the same SHAs as
`refs/heads/*`, so a stale spelling heals on the next fetch instead of
lying. A mirror cloned fresh from GitHub carries no `refs/remotes/` at all
— its `origin/main` spelling fails loudly instead of lying until the first
fetch seeds it (correctly, under the refspec above). A mirror cloned from
another mirror inherits whatever remote-tracking refs the source carries —
the refspec above is what keeps them honest either way. Never
hand-`update-ref` `refs/remotes/origin/*` in a mirror.

A short log with no verdict after a backgrounded launch is a **launcher fault**
(the session reaped the process). A log containing `rate_limit` /
`ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do not mix
them up.

The Claude PostToolUse hook `~/.claude/hooks/guard_pi_packet.py` classifies
these from the redirected packet log. Launcher faults advise the transient-unit
one-liner above; lane faults advise seat rotation.

## Claim shared files before editing (interactive sessions)

Queued work has an atomic lock — the `claim/issue-N` branch. Interactive
sessions claim the same way, with stock git only: push a
`claim/adhoc-<scope>` branch from `main` before touching a shared file.
A pushed branch is the fleet-visible occupied sign, and a create-only push
collides atomically for a second claimant. Convention: **use the shared
file path as the scope** so two agents on the same file pick the same
branch name. `git ls-remote origin 'refs/heads/claim/*'` plus `gh pr list`
is the pre-flight conflict check; delete the branch when done.
`bin/fleet-claim`, the helper that wrapped this, was deleted in the glue
sweep — the stock push is the whole mechanism.

Stale interactive **sessions** are no longer reaped by a bespoke timer:
`interactive-session-reap` was deleted on 2026-09-18 after 113 consecutive
hourly runs that each reaped nothing. `systemd-oomd` is the native reaper
under real memory pressure. sshd, tailscaled, and the runner services are out
of scope: they do not live in `session-*.scope`. `claim/issue-*` and
`claim/adhoc-*` branches are released by the agent that claimed them.

## CI

`.github/workflows/ci.yml` runs two jobs on every PR and push to main:

1. **ci** — stock checks: `promtool check rules config/fleet_rules.yml`, semgrep
   `--config p/default`, the CI-gaming gates (agent attribution over the
   commit range and PR text, the secret-expansion and auth-status greps),
   `promtool`/`jq` config sanity, actionlint, shellcheck, systemd-analyze
   verify over `systemd/`, and a grep gate on
   `template/cursor-rules/shared-memory.mdc` that rejects the
   pre-#6610 universal approval gate and the deleted `memoryctl` mandate
   (fleet-ops#7803).
2. **no-glue** — rejects any added script/helper/hook file (`bin/`,
   `scripts/`, `libexec/`, `ops/`, `hooks/`, `.github/scripts/`, `*.sh`,
   `*.mjs`, `.fleet/`) and any added unit `Exec` line long enough to be a
   program (fleet-ops#7828).

`.github/workflows/secret-scan.yml` is the gitleaks scan (pinned binary +
sha256, `--redact`). fleet-ops has no deploy target. All actions are pinned to exact commit
SHAs; every job has a timeout.

`.github/workflows/reusable-pr-checks.yml` (`workflow_call`) is the batched
CI standard for every current and future repo: one job, `timeout-minutes`,
PR concurrency, npm cache, job-level path gating, and gitleaks. Callers
pass `inputs`; they do not copy the steps. New repos copy
`template/.github/workflows/` (wired to this repo at `@v1`).

## Allowlist

There is no manifest and no installer. A path is live because something
symlinks to it from `~/.config/systemd/user/`, `~/.local/bin/`, or
`~/.pi/agent/prompts/`. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`,
`cf.env`) are never tracked — only the units that reference them.

## Fleet heartbeat — DELETED 2026-09-18

`fleet-heartbeat.timer`/`.service`, `bin/fleet-heartbeat-tier1` and
`prompts/heartbeat.md` are gone. Their jobs live in the organs that already
did them: `.github/workflows/agent-dispatch.yml` queues `agent-ready` work, PR
auto-merge is a GitHub workflow, and a failed unit pages through the
`SystemUnitFailed` rule in `config/fleet_rules.yml`. Its healthchecks.io
dead-man is gone; the keystone URLs in `~/.config/fleet-ops/keystone-hc.env`
now serve only the root `restic-r2-restore-test.service`.

## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
agent-dispatch and the scout job. It is the single source of truth for which
repos are enrolled — adding or removing a repo is a PR against that file, not a
`systemctl enable`. This replaces the old imperative enrolment that was
silently reverted without a record (fleet-ops#32).

Each enrolled repo needs two preconditions:

1. A git checkout at `/home/nish/workspaces/products/<name>` — the worker
   creates its worktree from it. Packet clones (when a worker clones instead
   of worktree-add) use `git clone --reference-if-able
   /home/nish/workspaces/.mirrors/<name>.git
   https://github.com/Nishfleet/<name>.git <dest>` (fleet-ops#1213).
   Mirrors are read-only fetch targets; never push.
2. The three labels `agent-ready`, `agent-in-progress`, `agent-blocked`
   present on the repo — agent-dispatch fires only on the `agent-ready` label,
   so on a label-less repo an issue looks queued and is inert (fleet-ops#25).

`fleet2` is permanently excluded (standing rule: no second dispatcher,
ever). `siterep` is excluded (archived). Both are recorded in the file's
`excluded` list with reasons.

The `bin/intake-reconcile` reconciler and its `intake-reconcile.{path,
service,timer}` units were deleted in the glue sweep — the file itself is
the enrolment mechanism (fleet-ops#32, #25).

### `depends-on:`, `collision-gate:`, spec judge — DELETED in the glue sweep

Nothing parses `depends-on:` or `collision-gate:` body
lines, and the spec-judge pass (`lib/spec-judge.sh`, `prompts/spec-judge.md`)
is gone. Ticket bodies may still carry the lines as human context, but no
machinery reads them.

## Four-plane resilience drill — DELETED 2026-09-18 (was `fleet-resilience-drill`, issue #455)

> Removed with the synthetic-drill sweep: 1474 lines of rehearsal whose stub units died
> by design.

Single-VPS resilience is detection + repair, not a second copy of a
stateless thing; the rules are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The VNC
break-glass runbook is [docs/RUNBOOK.md](docs/RUNBOOK.md).
Keystone healthchecks.io URLs live in `~/.config/fleet-ops/keystone-hc.env`,
consumed by the root `restic-r2-restore-test.service`; an unset URL is a skip,
a shared URL is a fail.

## Worker RAM admission (issue #45)

Admission carries no RAM charge: the concurrency bound is the runner count
(#8429): 16 `agent` runners (`actions.runner.Nishfleet.netcup-agent-1..16`, sized from measured memory pressure, fleet-ops#8678),
all in `agent.slice` (`systemd/system/agent.slice`, 10G/11G, `MemorySwapMax=1G`),
each with
`VITEST_MAX_WORKERS=2` (vitest's default of cores-1 workers per job thrashed
swap on this 16 GB host on 2026-09-24). RAM safety is per-unit `MemoryMax` + systemd-oomd, not a governor
division. The slice's `MemorySwapMax` (fleet-ops#8638) is the swap half:
on the 09-24/25 night the RAM caps alone let 32 runners fill all 8G of
host swap (1000-2500 pages/s, 12 OOM kills, 14.6% iowait), so runner
overflow is now killed inside the slice instead of being swapped onto
the rest of the box. Known repos overrode the per-unit limits via
intake-written drop-ins (removed with the old dispatcher, fleet-ops#8449):
fleet-ops#3930 set `MemoryMax=4G` with **no `MemoryHigh`** for
fleet-ops + 0509 (the throttle band is what makes oomd pressure-kill a
random sibling, so it was removed; 4G is now the hard stop with a clean
local OOM at the cap), while the heavy class of #3281 writes 3G/2G for
heavy|keystone packets.

`bin/ram-measure` and `bin/ram-metric-compare` were deleted with the
heartbeat that called them; their last samples remain under
`~/.local/state/ram-measurement/`. Live RAM is `systemctl --user show
-p MemoryPeak <unit>` and `systemd-cgtop`.

## Daily view

Replaces the daily-digest Telegram push (fleet-ops#8433).

- Merged PRs, all repos: `https://github.com/pulls?q=org%3ANishfleet+is%3Apr+is%3Amerged+sort%3Aupdated-desc`
- Failed agent runs on 0509: `https://github.com/Nishfleet/0509/actions/workflows/agent-dispatch.yml?query=is%3Afailure`
- Issues parked by the agent queue: `https://github.com/issues?q=org%3ANishfleet+is%3Aopen+label%3Aagent-failed%2Cneeds-orchestrator`



