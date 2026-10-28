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
clone has written that file (fleet-ops#8893). One `sh` line then runs
`git merge-base --is-ancestor` in both directions: together they are true
only when `HEAD == origin/main`, so a deploy window that ends a commit
short fails the unit instead of leaving the live clone quietly behind.
The line prints `DEPLOY-BLOCKED`, the branch, `HEAD` and `origin/main`,
the commits that are not on main, and `switch main` as the fix, because
the bare exit code this replaced left six red deploy-box runs printing
only `exit code 1` (fleet-ops#9967). A session that needs a work branch
uses a worktree: a work branch checked out in the deploy clone blocks
every deploy.

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

### The root deploy units: run, switch off, delete

`fleet-host-config.service` applies `rootfs/` as root and is the only deploy path
for root-owned host config. It runs its own clone of reviewed main, so a request
can at most redeploy main. Two things start it: `.github/workflows/deploy-box.yml`
on every push to main, and `fleet-host-config-boot.timer` once after every boot
(3 minutes in), which starts tether's Cua Space again when a reboot stopped it.

- Run it now: `systemctl start fleet-host-config.service` (polkit lets user nish
  start this one unit, so no sudo), then
  `journalctl -u fleet-host-config.service -n 60 --no-pager` for the PLAY RECAP.
- Switch off the boot run: `systemctl disable --now fleet-host-config-boot.timer`.
  Merges keep deploying, because only the once-per-boot run stops.
- Stop every automatic run: the timer line above plus
  `systemctl mask fleet-host-config.service`. The deploy-box job's start then
  fails, so this is a halfway point on the delete path, not a steady state.
- Roll back one bad flag: the unit runs with `--verify-commit`, and a flag that
  stops it delivering a fix is reverted on main **and** undone by hand, because
  the next run puts it back from `rootfs/`:
  `sudo sed -i 's/ --verify-commit//' /etc/systemd/system/fleet-host-config.service`
  then `sudo systemctl daemon-reload`.

`fleet-deploy.path` watches `/var/lib/fleet-deploy/request` (a file the runner uid
owns in a root-owned directory, `rootfs/etc/tmpfiles.d/fleet-deploy.conf`) and
starts `fleet-deploy.service`, which runs the same two steps deploy-box.yml starts
one by one: the user-scope sync, then the root host config. It writes one verdict
line to `/var/lib/fleet-deploy/result` and the last journal lines of the three
units to `/var/lib/fleet-deploy/log`, because the runner cannot read the system
journal.

- Run one by hand: `sudo touch /var/lib/fleet-deploy/request`, then
  `cat /var/lib/fleet-deploy/result`.
- Switch it off: `systemctl disable --now fleet-deploy.path`. The deploy-box job
  then starts the two units itself, as it did before.
- Delete the four units: delete `fleet-host-config.service`,
  `fleet-host-config-boot.timer`, `fleet-deploy.path` and `fleet-deploy.service`
  under `rootfs/etc/systemd/`, the `fleet-host-config.service.d` drop-in
  directory and `rootfs/etc/tmpfiles.d/fleet-deploy.conf`, add those six paths
  to `retired` in `ansible/host.yml`, then `sudo systemctl daemon-reload`. The
  retired list, not the file deletion, is what removes the installed copies on
  the next config run.

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
`~/.local/bin`, `~/.pi/agent` or `~/workspaces/tooling/nish-vault` resolves
into a throwaway root (`*worktrees/*`, `agent-state`, `tmp`), or is broken
(`-xtype l`) anywhere except the one mirror directory described next.
Live links belong to the canonical checkout and the stable install dirs
(`~/.local/share`, `~/.local/lib`), never to a tree a session can delete or
re-clone.

`~/.pi/agent/skills` is the exception, and its own class: each entry is a link
to a skill that `~/.claude/skills` (a Syncthing folder edited on another
machine) or the vault owns, so deleting a skill at the source leaves the link
dead as a matter of course. There a dead link is printed and does not fail the
unit, so the deploy converges and a skill that comes back needs no relink; a
throwaway target there is still fatal. Nine such links held every push red for
23 h across six runs before this split (fleet-ops#9967). Off switch, if the
skill wiring itself must never gate a deploy: delete the three LINK-GUARD
`ExecStart=` lines in `systemd/fleet-sync.service`, then
`systemctl --user daemon-reload`. Nothing else reads them.

Global skills are updated by hand when wanted: `npx -y skills update -g -y`.
There is no timer for it — the weekly skills-update timer was deleted on
2026-10-24 (fleet-ops#10134), so nobody looks for one.

