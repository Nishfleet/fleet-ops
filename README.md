# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — user units (services + timers) the fleet runs under
  `systemctl --user`.
- `containers/quadlet/` — `*.container` Podman quadlet units for the
  LiteLLM proxy, its Postgres and Redis, Grafana and aiostreams.
- `etc/` — `nftables.conf` and `sysctl.d/`, host system config applied by hand.
- `patches/` — `litellm-1.98.0-gchunk-usage-union.patch`, a proxy source patch
  reapplied after every proxy upgrade (see [RUNBOOK](docs/RUNBOOK.md)).
- `docs/` — `ARCHITECTURE.md`, `RUNBOOK.md`, `jev-call-sites.md` and
  `quality-bar.md`.
- `template/` — `agents/`, `cursor-rules/`, `devin-config.json` and
  `README.md`, source files the live host links or copies by hand (see
  [template/README.md](template/README.md)).
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `intake-repos.json` is the declared set of
  repos enrolled in the agent-ready queue (see [Intake enrolment](#intake-enrolment)).
- `systemd/fleet-sync.service` (started by
  `.github/workflows/deploy-box.yml` on push) — the whole deploy mechanism:
  `git fetch` + `git merge --ff-only` + `systemctl --user daemon-reload`, plus
  `promtool check config`, the `/etc/prometheus/prometheus.yml` copy and its
  reload, and a LINK-GUARD pass
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

The unit fails loudly on a dirty or diverged clone. That is
correct: the live source must be clean `origin/main`, and a failed
`fleet-sync.service` fires `OnFailure=fleet-unit-failed@` (healthchecks.io
fail ping, fleet-ops#9033).

The sync is a `git fetch` of `main` into `refs/remotes/origin/main`
followed by a `git merge --ff-only` of that named ref — never
`git pull`, which merges the multi-entry `FETCH_HEAD` and dies with
`Cannot fast-forward to multiple branches` when anything else in the
clone has written that file (fleet-ops#8893). Two `merge-base
--is-ancestor` lines then assert `HEAD == origin/main`, so a deploy
window that ends a commit short fails the unit instead of leaving the
live clone quietly behind.

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

Five classes are deliberately copies, not symlinks, and a `git pull` does
NOT update them. The three rows marked **Handled automatically** are refreshed
by `fleet-sync.service` instead — a hand copy of one of those is wasted work,
the next sync overwrites it. The rest are refreshed by hand.

| live path | repo source | why a symlink is wrong |
|---|---|---|
| `/etc/prometheus/prometheus.yml` | `config/prometheus.yml` | same privilege boundary. **Handled automatically** by `fleet-sync.service` (promtool check config + copy + reload). |
| `~/.pi/agent/models.json` | `config/pi-models.json` | **Handled automatically** by `fleet-sync.service` (cmp + install, fleet-ops#8568). A copy, not a symlink, because `~/.pi/agent` is an overlay mount in worker containers. |
| `/etc/systemd/system/agent.slice` | `systemd/system/agent.slice` | **Handled automatically** by `fleet-sync.service` (install -C + system `daemon-reload`, fleet-ops#8862). The repo cap `MemorySwapMax=1G` sat in the repo for 5 days while the live unit read `infinity`, so the runners could fill all host swap again. |
| `~/.local/state/pi-packet/model-candidates.json` | `none (live-only)` | live state the git working tree must not rewrite on every checkout (fleet-ops#2910/#3722/#3322). |
| `~/.pi/agent/settings.json` | `none (live-only)` | pi writes this file itself at runtime (provider/model switches and its own bookkeeping keys), so a repo copy would be overwritten and a symlink would fight pi. Every fleet caller passes `--provider litellm --model <group>`, so its `defaultProvider`/`defaultModel` affect only bare interactive `pi` runs (fleet-ops#8568). Its `compaction.reserveTokens: 40000` pairs with the worker `contextWindow: 296000` in `config/pi-models.json`: pi compacts at window − reserve = 256k (Nish 2026-09-25; was 88k under #8567), and pi sizes each reply as window − context − 4096, so a turn at 256k still gets its full 32k `maxTokens`. Every worker rung holds 256k+ (seat /models or spend-log prompts up to 416k). At 96000/8192 replies near 88k were cut to ~4.8k (fleet-ops#8634). The real model windows are ~1M; 128000 is a budget, not a limit. |
| `/etc/**` (systemd drop-ins, `sysctl.d`, `audit/rules.d`, `default/prometheus`, `prometheus/*.yml`) | `config/`, `etc/`, `systemd/system/` | cross a privilege boundary. The two rows above are also `/etc/**` files, but fleet-sync owns those copies; every other one is by hand. |

```
# a changed /etc file:
sudo -n install -D -m 0644 -o root -g root <repo>/<src> /etc/<dest>
sudo -n systemctl daemon-reload          # for /etc/systemd/system/**
sudo -n augenrules --load                # for /etc/audit/rules.d/**
sudo -n sysctl --system                  # for /etc/sysctl.d/**   (Nish-reserved)
# a changed root unit:
sudo -n systemctl link /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/system/<unit>
```

For `agent.slice` specifically, a hand copy is not enough to check the change
landed: `daemon-reload` re-applies the limit to the running slice, so confirm
both the unit and the cgroup read the new cap.

```
systemctl show agent.slice -p MemorySwapMax      # 1073741824, not infinity
cat /sys/fs/cgroup/agent.slice/memory.swap.max   # same number
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
while worktrees are attached. Workers do not create worktrees from the
deploy-clone: each `git clone`s into its own
`agent-worktrees/issue-<repo>-<N>` directory (`.mirrors` as an optional
reference), and the deploy clone is mounted read-only in the worker jail
(fleet-ops#410).

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

`.github/workflows/ci.yml` runs one job, `ci`, on every PR and push to main. Its
checks are stock: semgrep `--config p/default`, the secret-expansion grep,
`jq` config sanity, actionlint, zizmor, shellcheck, and systemd-analyze verify
over `systemd/`. The stock linters are joined by repo-specific gates: a no-glue
semgrep rule at `.semgrep/no-glue.yml`, a no long-lived personal-access-token
(PAT) grep, `nft -c` over `etc/nftables.conf`, a no shell `${...}` or bare
`%s/%u/%h` check inside systemd Exec lines (fleet-ops#8382), pi seat ids
resolving to `config/litellm-proxy.yaml` `model_name` (fleet-ops#8332), and
Ollama rungs serving only the permitted slug (fleet-ops#8332).

`.github/workflows/secret-scan.yml` is the gitleaks scan (pinned binary +
sha256, `--redact`). fleet-ops has no deploy target. All actions are pinned to exact commit
SHAs; every job has a timeout.

`.github/workflows/lighthouse.yml` is the fleet's one Lighthouse speed budget, stock LHCI
assertions in `config/lighthouserc.json` (LCP 1500 ms, interactive 3000 ms, CLS
0.05, script 150 KB, total 500 KB, no console errors; sizes are bytes there,
153600 and 512000). A web repo calls it with
`uses: Nishfleet/fleet-ops/.github/workflows/lighthouse.yml@main` and
`with: urls:` (one page URL per line); callers cannot change the assertions.

## Allowlist

There is no manifest and no installer. A path is live because something
symlinks to it from `~/.config/systemd/user/`, `~/.local/bin/`, or
`~/.pi/agent/prompts/`. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`,
`cf.env`) are never tracked — only the units that reference them.

## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
agent-dispatch. It is the single source of truth for which
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
2. The six labels listed in `required_labels` in `config/intake-repos.json`
   — `agent-ready`, `agent-in-progress`, `agent-blocked`, `agent-failed`,
   `needs-orchestrator`, `strong-only` — must be present on the repo —
   agent-dispatch fires only on the `agent-ready` label, so on a repo missing
   any required label an issue looks queued and is inert (fleet-ops#25).

`fleet2` is permanently excluded (standing rule: no second dispatcher,
ever). `siterep` is excluded (archived). Both are recorded in the file's
`excluded` list with reasons.

The `bin/intake-reconcile` reconciler and its `intake-reconcile.{path,
service,timer}` units were deleted in the glue sweep — the file itself is
the enrolment mechanism (fleet-ops#32, #25).

## Worker capacity

The concurrency bound is the runner count (#8429): 24 `agent` runners
(`actions.runner.Nishfleet.netcup-agent-1..24`, sized from measured memory
pressure, fleet-ops#8860), all in `agent.slice` (`systemd/system/agent.slice`,
10G/11G, `MemorySwapMax=1G`). RAM safety is per-unit `MemoryMax` plus
systemd-oomd, not an admission charge. Live RAM is
`systemctl --user show -p MemoryPeak <unit>` and `systemd-cgtop`.
