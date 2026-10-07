# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — the user units the fleet runs under `systemctl --user`:
  services, timers, slices, one `.path` unit (`fleet-litellm-proxy-config.path`)
  and one `.scope.d` drop-in (`tmux-spawn-.scope.d`).
- `rootfs/` — root-owned host config, laid out like `/` (`rootfs/etc/X` is
  installed at `/etc/X`): system units, slices and drop-ins, `nftables.conf`,
  `sysctl.d/`, `audit/rules.d/`, polkit rules and the prometheus config.
- `ansible/host.yml` — the Ansible playbook that installs `rootfs/`.
  `fleet-host-config.service` runs it as root (`ansible-pull`) on every merge
  and once a day, and fails on a hand-installed file.
- `ansible/update.yml` — the weekly safe full update of the box (see
  [Weekly update](#weekly-update)). `fleet-update.service` runs it as root
  (`ansible-pull`).
- `containers/quadlet/` — `*.container` Podman quadlet units for the
  LiteLLM proxy, its Postgres and Redis, Grafana and aiostreams.
- `patches/` — `litellm-1.98.0-gchunk-usage-union.patch`, a source patch for
  LiteLLM 1.98.0 that no unit in this repo applies (the proxy runs a pinned
  container image).
- `docs/` — `ARCHITECTURE.md`, `RUNBOOK.md`, `jev-call-sites.md`,
  `quality-bar.md` and `incidents/` (one blameless write-up per outage,
  named `YYYY-MM-DD-<slug>.md`).
- `template/` — `agents/`, `cursor-rules/`, `devin-config.json` and
  `README.md`, source files the live host links or copies by hand (see
  [template/README.md](template/README.md)).
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `intake-repos.json` is the declared set of
  repos enrolled in the agent-ready queue (see [Intake enrolment](#intake-enrolment)).
  `config/litellm-proxy.schema.rejects/` holds one YAML per rule
  `config/litellm-proxy.schema.json` must refuse: the bench block, a router
  cooldown over 60, a zero row cooldown, a row cooldown, and one case per
  judge-group rule (the fallback rows back on order 1, the paid row's rpm
  raised, its concurrency raised, a fourth judge row, the paid row doubled
  as its own fallback, a fallback row renamed, both fallbacks on one key, and
  a swap of the paid row's model, host or key, or of a fallback's model or
  host). CI
  validates every file
  in the directory against the schema and each must fail, so a loosened schema
  goes red. A new schema rule gets a reject file in the same PR.
- `config/grafana/` — the fleet-view Grafana provisioning
  (`provisioning/datasources/`, `provisioning/dashboards/`,
  `provisioning/alerting/`) and `dashboards/fleet.json`.
  `containers/quadlet/fleet-grafana.container` mounts all four read-only, so
  the UI cannot save edits.
- `config/user-tmpfiles.d/agent-worktrees.conf` — the `systemd-tmpfiles`
  age-out rules `fleet-sync.service` applies on every sync: an
  `agent-worktrees/` dir untouched for 3 days goes, and so do the dated files
  under `.pi/agent/sessions`, `.cursor/chats/*/` and
  `.local/state/pi-issues`.
- `credentials/` — `app-manifest.json`, the worker GitHub App manifest
  (`.github/workflows/agent.yml` cites it for the App's grant).
- `.agents/skills/verify-fleet/` — the verify-fleet skill. `SKILL.md` says how
  to run one real fleet unit and collect proof (invocation id, journal,
  artifact, exit, CPU and memory peak); `fleet-map.md` holds one row per unit,
  timer, path, slice or template.
- `.semgrep/` — `no-glue.yml`, the no-glue rule `ci.yml` runs
  (`docs/ARCHITECTURE.md` already names it).
- `systemd/blacksmith-flip.service` and `systemd/blacksmith-flip.timer` — one
  hourly decision on the cheap seat: does this calendar month still have
  Blacksmith free minutes, and does the org Actions variable `CI_RUNNER` point
  at Blacksmith accordingly (fleet-ops#8936). The decision lives in
  `prompts/blacksmith-flip.yml`, which `fleet-sync.service` installs, and a
  model runs `blacksmith usage` rather than a checked-in script, because
  "no glue or scripts" was Nish's condition on approval.
- `systemd/leviathan-index@.service` and `systemd/leviathan-index@.timer` —
  the Leviathan session-log search index, refreshed every 15 minutes per
  instance (`claude`, `pi`): an FTS5 index over the session JSONLs that
  answers "what did an old session say about X" in milliseconds (fleet-ops#9313).
  Config and index live in `~/.local/share/leviathan/` (0700), installed from
  `config/leviathan/` by `fleet-sync.service`; the binary is installed by
  `ansible/host.yml` from a pinned release. Off switch, under 2 minutes and
  nothing re-enables it: `systemctl --user disable --now leviathan-index@claude.timer leviathan-index@pi.timer`,
  then `rm ~/.local/bin/leviathan && rm -rf ~/.local/share/leviathan` —
  `host.yml`/`update.yml` only install and version the binary and
  `fleet-sync.service` only refreshes unit and config bytes, so no fleet unit
  ever re-enables a timer. Wire new instances only after `fleet-sync.service`
  has run once with the configs merged (the 15-minute tick pages on a missing
  config). Each run rebuilds the index from the files on disk, so it mirrors
  the logs and keeps the same retention; the index never holds more than the
  logs do.
- `systemd/fleet-sync.service` (started by
  `.github/workflows/deploy-box.yml` on push) — the whole deploy mechanism:
  a clean-clone check that prints
  `DEPLOY-BLOCKED` and fails, `git fetch` + `git merge --ff-only` plus two
  `git merge-base --is-ancestor` probes that fail unless `HEAD` equals
  `origin/main`, `systemctl --user link` of `fleet-unit-failed@.service` and
  `systemctl --user daemon-reload`, `systemd-tmpfiles --user --create`,
  user-scope `install -C` copies (`config/pi-models.json` to
  `~/.pi/agent/models.json`, `config/litellm-proxy.yaml` to
  `~/.config/fleet-ops/litellm-proxy.yaml` behind a `cmp` guard,
  `prompts/blacksmith-flip.yml` to `~/.local/share/blacksmith-flip/prompt.yml`,
  and the leviathan index units, their configs and the tmpfiles rule to
  `~/.local/share/leviathan/` and `~/.config/user-tmpfiles.d/`, fleet-ops#9313),
  and a LINK-GUARD pass
  that fails the unit on a dangling or throwaway-target live symlink
  (fleet-ops#7743). Root-owned files (`/etc/**`, `agent.slice`, everything under
  `rootfs/`) are not this unit's job: `fleet-host-config.service` installs them
  as root from its own clone.

## Install

There is no installer. Every live user-scope path is a **symlink into this
repo**, so a push to `main` is the deploy (`deploy-box.yml` runs
`fleet-sync.service`, a fetch plus `--ff-only` merge, described below) — the
file the fleet runs and the file in git are the same inode. Nothing is copied,
so nothing can drift, and the
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

`man systemctl`: _"link PATH... Link a unit file that is not in the unit file
search path into the unit file search path. This command expects an absolute
path to a unit file."_ Add the unit file to `systemd/`, merge it, then once:

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

These classes are deliberately copies, not symlinks, and a `git pull` does
NOT update them. The rows marked **Handled automatically** are refreshed by
`fleet-sync.service` (user files) or `fleet-host-config.service` (root files)
instead — a hand copy of one of those is wasted work,
the next sync overwrites it. The rest are refreshed by hand.

| live path                                                                                                                   | repo source             | why a symlink is wrong                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `~/.pi/agent/models.json`                                                                                                   | `config/pi-models.json` | **Handled automatically** by `fleet-sync.service` (install -C, fleet-ops#8568). A copy, not a symlink, because `~/.pi/agent` is an overlay mount in worker containers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `~/.local/state/pi-packet/model-candidates.json`                                                                            | `none (live-only)`      | live state the git working tree must not rewrite on every checkout (fleet-ops#2910/#3722/#3322).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `~/.pi/agent/settings.json`                                                                                                 | `none (live-only)`      | pi writes this file itself at runtime (provider/model switches and its own bookkeeping keys), so a repo copy would be overwritten and a symlink would fight pi. Every fleet caller passes `--provider litellm --model <group>`, so its `defaultProvider`/`defaultModel` affect only bare interactive `pi` runs (fleet-ops#8568). Its `compaction.reserveTokens: 40000` pairs with the worker `contextWindow: 140000` in `config/pi-models.json`: pi compacts at window − reserve = 100k (fleet-ops#9081: spend-log worker prompts averaged 71k and p90 was 141k, so a 256k compact point never fired). Reply budget is window − context − 4096, so a turn at the compact point still gets the full 32k `maxTokens` (140000 − 100000 − 4096 = 35904). The 96000/8192 pairing cut replies to ~4.8k (fleet-ops#8634) and is not used. The real model windows are ~1M; 140000 is a budget, not a limit. |
| `/etc/**` (system units and drop-ins, `sysctl.d`, `audit/rules.d`, `polkit-1/rules.d`, `prometheus/*.yml`, `nftables.conf`) | `rootfs/etc/**`         | cross a privilege boundary. **Handled automatically** by `fleet-host-config.service`: Ansible (`ansible/host.yml`) checks the prometheus and nftables files, installs every file under `rootfs/` as root, and reloads only the daemon whose file changed. A new root file is a new file under `rootfs/`; nothing is installed by hand.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `~/.local/share/leviathan/` (`leviathan-index@.service`, `leviathan-index@.timer`, `claude.toml`, `pi.toml`) and `~/.config/user-tmpfiles.d/leviathan.conf` | `systemd/leviathan-index@.timer`, `config/leviathan/*.toml`, `config/user-tmpfiles.d/leviathan.conf` | **Handled automatically** by `fleet-sync.service` (install -C before the daemon-reload, fleet-ops#9313). The timer fires every 15 minutes, so the unit and config bytes must exist on the box before the PR that ships them merges — a git merge refuses a clone with untracked files in the way, so nothing may read these from the deploy clone. The live unit links are hand-set once (`systemctl --user link ~/.local/share/leviathan/...`); a `user-tmpfiles.d` symlink would dangle pre-merge and be read dead by `systemd-tmpfiles --create` on every sync. Each run rebuilds the index from the files on disk, so the index mirrors the logs and never holds more than the logs do. |

```
# a changed /etc file: merge it under rootfs/etc/. deploy-box.yml then runs
systemctl start fleet-host-config.service    # polkit allows user nish; no sudo
journalctl -u fleet-host-config.service -n 60 --no-pager   # PLAY RECAP failed=0
```

Files kept off GitHub on purpose (they reveal access paths or backup targets)
are listed in `/etc/fleet-ops/box-only` on the box, so the drift check skips
them. That list is the only hand-kept root file.

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
refuses with _"Refusing to run in an untrusted workspace"_, re-apply it once:

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

## Weekly update

`fleet-update.timer` starts `fleet-update.service` every Sunday at 03:30 IST.
It runs `ansible/update.yml` as root through `ansible-pull`:

1. Pause: set the repo variable `FLEET_DISPATCH_PAUSED=true` in each queue
   repo, stop the work timers, wait until no runner has a job (up to 150 min),
   stop the runner services. `agent-dispatch` stays enabled: only its
   worker-starting jobs skip, and `hold-risky` keeps holding risky PRs. (It was
   `gh workflow disable` until 2026-10-05; a disabled workflow drops every
   trigger, the guard included.)
2. Prune: apt cache, Docker containers stopped for a day, dangling Docker and
   Podman images, old build cache, the npm and uv caches.
3. Update: `apt dist-upgrade`, `autoremove`, `needrestart -r a`, then each
   user-level tool through its own updater (npm globals, pi, claude and its
   plugins, cursor-agent, devin, uv, bun, rclone).
4. Resume, even when a step failed: start the runners, set
   `FLEET_DISPATCH_PAUSED=false` where this run set it, restart the timers,
   sweep each queue. The repos it paused are listed in
   `/var/lib/fleet-ops/dispatch-paused-by-update` from before the first set
   until every flag is clear again, so a run killed before this step (timeout,
   SIGKILL) is undone by the next run, which clears those flags first. A flag
   set by hand is never in that file and stays set.
5. Verify: the netcup runners online, each queue's sweep run accepted by
   GitHub, pi answering a real call with its extensions loaded and every
   extension in `~/.pi/agent/settings.json` pinned (full SHA for `git:`, exact
   version for `npm:`), no failed unit, router ready, Remote Control up. Any
   problem fails the unit, which pages.

It never reboots. When a package needs a reboot, it opens one
`needs-nish-decision` issue. The daily security updates (`unattended-upgrades`)
stay on; `rootfs/etc/needrestart/conf.d/50-fleet.conf` makes them only list
services on old libraries, so they never restart a service mid-job.
`claude-remote-control.service` is never restarted, by either path.

- Run it now: `sudo systemctl start --no-block fleet-update.service`, then
  `journalctl -u fleet-update -f`.
- Switch it off: a PR that drops "Enable the weekly update" in
  `ansible/host.yml` and adds a task with `state: stopped, enabled: false`.
  In an emergency: `sudo systemctl disable --now fleet-update.timer`.
- Delete it: remove `ansible/update.yml`, the two `fleet-update` units and
  `50-fleet.conf`, and add their `/etc` paths to `retired` in `ansible/host.yml`.

## CI

`.github/workflows/ci.yml` runs one job, `ci`, on every PR and push to main. Its
checks are stock: semgrep `--config p/default`, the secret-expansion grep,
`jq` config sanity, actionlint, zizmor, shellcheck, and systemd-analyze verify
over `systemd/`. The stock linters are joined by repo-specific gates: a no-glue
semgrep rule at `.semgrep/no-glue.yml`, a no long-lived personal-access-token
(PAT) grep, `nft -c` over `rootfs/etc/nftables.conf`, `ansible-playbook --syntax-check` over `ansible/host.yml` and `ansible/update.yml`, a no shell `${...}` or bare
`%s/%u/%h` check inside systemd Exec lines (fleet-ops#8382), pi seat ids
resolving to `config/litellm-proxy.yaml` `model_name` (fleet-ops#8332), and
Ollama rungs serving only the permitted slug on the native provider
(fleet-ops#8332, fleet-ops#9253), the litellm-proxy
schema gate: `config/litellm-proxy.yaml` must validate against
`config/litellm-proxy.schema.json`, and every
`config/litellm-proxy.schema.rejects/*.yaml` must fail the same check
(fleet-ops#8653), so a loosened schema goes red.

`.github/workflows/secret-scan.yml` is the gitleaks scan (pinned binary +
sha256, `--redact`). fleet-ops has no deploy target. All actions are pinned to exact commit
SHAs. `agent.yml`, `ci.yml`, `deploy-box.yml`, `lighthouse.yml` and
`secret-scan.yml` set `timeout-minutes` on their jobs. `agent-dispatch.yml`
sets none. Its `new`, `rework`, `ejected` and `unblocked` jobs
call `agent.yml` through `uses:` and inherit its limits, while its `list` and `close-claim`
jobs run their own steps on `ubuntu-latest` with no `timeout-minutes`.

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

`excluded` in the file lists repos that are never enrolled (fleet2: no
second dispatcher, ever; archived repos). `deferred` lists repos paused with
the reason and the condition to re-enrol, and `fleet-ops` itself is in it.
Only `repos` is enrolled.

The `bin/intake-reconcile` reconciler and its `intake-reconcile.{path,
service,timer}` units were deleted in the glue sweep — the file itself is
the enrolment mechanism (fleet-ops#32, #25).

## Worker capacity

The concurrency bound is the runner count (#8429): 22 `agent` runners
(`actions.runner.Nishfleet.netcup-agent-1..22` in org runner group 3, shared
by every enrolled repo including drive since 2026-10-06; live count:
`gh api orgs/Nishfleet/actions/runner-groups/3/runners --jq .total_count`;
sized from measured memory pressure, fleet-ops#8860), all in `agent.slice` (`rootfs/etc/systemd/system/agent.slice`,
26G/28G, `MemorySwapMax=1G`). RAM safety is per-unit `MemoryMax` plus
systemd-oomd, not an admission charge. Live RAM is
`systemctl --user show -p MemoryPeak <unit>` and `systemd-cgtop`.
