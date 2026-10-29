# Agent lock (fleet-ops#9977)

Every agent on this box that reads text from outside the fleet runs as a
**system** unit with `User=nish`, and its unit hides every other agent's keys.

The reason is a host setting, not a preference: systemd silently ignores
sandbox directives in a **user** unit here, because
`kernel.apparmor_restrict_unprivileged_userns=1`. A user unit with
`ProtectHome=tmpfs` on this box still reads `~/.config/cloudflare/deploy-ci.env`
— measured on 2026-10-22, with `InaccessiblePaths=`, `PrivateUsers=` and
`BindPaths=` in the same run. Only a system unit applies them.

`config/agent-locks.json` is the contract: one entry per agent, with the paths
it must keep (`needs`) and the paths it must lose (`must_hide`).
`gaps` is the other half of the contract: an agent that still runs unlocked,
with the reason and the follow-up issue that closes it. Every gap names the
unit file it is about, and a test fails when that file is gone, so a gap
cannot name a unit the repo no longer ships.
`tests/test_agent_locks.py` resolves each unit's real settings, following the
symlinked shared drop-in, and fails when a unit is not a system unit with a
service user, when a hidden path is still readable, when a need is hidden, when
the unit sets no `HOME` and no `PATH` that starts with the fleet user's
`~/.local/bin`, when a gap names a unit the repo no longer ships, or when a user
unit under `systemd/` starts an agent engine in an `ExecStart*=` line and
appears in no contract entry. The `unit` job in CI runs it.
`ansible/tasks/agent-lock.yml` runs the same lists on the box inside a transient
unit with the same `User=` and `InaccessiblePaths=`. The contract spells its
paths with `~`, and `InaccessiblePaths=` takes them relative to the host's root
(systemd.exec(5)), so the task expands them to `/home/nish` before they reach
`--property=`. The probe also runs as the service user, not as root: `access(2)`
is then checked as that user, and root would read a mode-000 hidden path
straight through the lock.

Two shapes are in use. `tincan-listen-claude-vps.service` is deny-by-default:
`ProtectHome=tmpfs` empties all of `/home` and `BindPaths=` /
`BindReadOnlyPaths=` list back what the agent needs. It was proved live before
this repo owned it (request `95eeb9cc666c91d7dbf0`: gh no, hetzner no, Jev key
yes, Jev call yes, p=0.99). The other six relay listeners use an explicit
deny list, `InaccessiblePaths=` in
`rootfs/etc/systemd/system/fleet-agent-lock.service.d/50-shared.conf` (the keys
every agent loses, plus `HOME=` and `PATH=`) plus `60-own-keys.conf` in each
unit's drop-in directory (every other agent's login and every other relay
identity). Nothing else under `/home` is hidden, so a command a listener already
runs still runs.

Every `tincan-listen-*.service.d/50-shared.conf` is a symlink to the shared
file, so the rules have one source in the repo. `install-config.yml`'s copy
dereferences the link, so the box holds seven real files and a deploy re-copies
them when the shared file changes. Every path in these units is absolute,
never `%h`: `%h` is the *system manager's* home (`/root`) and is not influenced
by `User=` (systemd.unit(5)), so a `%h` unit would point at paths that do not
exist and fail its ExecStart. `HOME=` is set for the same reason — a CLI that
expands `~` would otherwise land in `/root`.

Every `InaccessiblePaths=` path starts with `-`, so a unit still starts on a
box where that path is absent: at boot a listener can come up before dockerd
creates `/run/docker.sock` or before `user@1000` creates `/run/user/1000`, and
the '-' prefix is systemd's own way to say "hide it if it exists"
(systemd.exec(5)).

## The switch-over

`ansible/tasks/agent-lock.yml` does it in this order, and never takes a step
that could leave an agent with no unit running:

1. Run the probe for every listener except claude-vps, whose shape was proved
   live. A probe failure stops the play before anything is switched.
2. Start the locked listeners with `state: started`, never `restarted`: this
   playbook runs on every merge to main and once a day, and restarting seven
   listeners that often throws away in-flight work for no change.
3. Wait until `systemctl is-active --quiet` is quiet for **all** of them.
   `Restart=on-failure` with `RestartSec=30` means a start job can succeed and
   the process still die seconds later, so "started" is not the proof. This
   step fails the run and leaves the user units below untouched.
4. Only then disable and stop the unlocked user-scope listeners.

## Rollback

One command per agent, no data moves. The old user unit file is disabled but
still on disk:

    sudo systemctl disable --now tincan-listen-pi.service
    systemctl --user --machine=nish@.host enable --now tincan-listen-pi.service

## Off switch

For the playbook's switch-over: delete the `Read the agent lock contract`,
`Show one agent cannot read the other agents' keys`, `Start the locked
listeners`, `Wait until every locked listener is active`, `List the unlocked
listener units the box still has` and `Retire the unlocked user-scope
listeners` tasks from `ansible/tasks/agent-lock.yml`, and the
`import_tasks` line that loads it in `ansible/host.yml`. The units stay
installed and keep running; nothing restarts them.

## Locking a new agent

1. Write the system unit under `rootfs/etc/systemd/system/`, with absolute
   paths and no `%h`.
2. Add its entry to `config/agent-locks.json` with its `needs` and
   `must_hide`. If it starts an engine binary that no entry names yet, add
   that binary's path to `AGENT_ENGINE` in the test, so the coverage check
   sees a unit that starts it.
3. Symlink `rootfs/etc/systemd/system/<unit>.service.d/50-shared.conf` to
   `../fleet-agent-lock.service.d/50-shared.conf`, and write the agent's own
   `60-own-keys.conf`.
4. Let the test and the playbook say whether the lock holds.
