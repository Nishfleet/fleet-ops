## Daily update

`fleet-update.timer` starts `fleet-update.service` every day at 03:30 IST.
It runs `ansible/update.yml` as root through `ansible-pull`:

1. `ansible/update.yml` installs the globally installed npm and uv agent tools
   at the exact versions pinned in `config/agent-tools/pins.txt`
   (`npm install --global <pkg>@<version>`, `uv tool install --upgrade
   <pkg>==<version>`, 900 s cap each step). A new upstream release becomes a
   Renovate PR against the pin file 3 days later (`renovate.json`), so the
   tools the agents run never move outside a reviewed PR, and a rollback is
   that PR's revert.
2. Ubuntu packages update through `unattended-upgrades`, and Claude Code
   through its own auto-updater, so this run does not touch them.

A failed run retries after 30 min, at most 3 starts in 4 h, and then stays
`failed`, which `SystemUnitFailed` reads. A run that hangs fails at 45 min
(`TimeoutStartSec=`).

It never reboots. When a package needs a reboot, it opens one
`needs-nish-decision` issue. The daily security updates (`unattended-upgrades`)
stay on; `rootfs/etc/needrestart/conf.d/50-fleet.conf` makes them only list
services on old libraries, so they never restart a service mid-job.
`hermes-gateway.service` and `hermes-serve.service` are not restarted by it
either, so they run on old system libraries until the next reboot.
`hermes-gateway.service` is the unit Hermes' own installer writes; `sudo hermes
gateway restart --system` restarts it and rewrites it when Hermes changes it.
`claude-remote-control.service` is never restarted, by either path. A change to
it is therefore staged on merge: the file is copied in and the running server
keeps its old session until Nish restarts it, because that restart cuts his
phone link (#9425). The staged file as of 2026-10-08 adds
`--no-create-session-in-dir`, so relayed coordinator work no longer piles into
one standing session. Each request from the phone or a claude.ai/code project
relay then gets its own session with a fresh context. The one standing session
it replaces was measured at $52.0 over 21.0 h with a 69k average context; the
number after the restart is the real test.
The staged file as of 2026-10-28 (#9438) adds `--capacity 1`, so one session
runs at a time: in `same-dir` mode every session edits `~/workspaces`, and bursts
of up to 10 sessions could overwrite each other. A second request is refused or
queued. Drop the flag to go back to the default of 32. `~/.claude/projects` needs
no fleet pruning: Claude Code deletes transcripts after 30 days (`cleanupPeriodDays`).

- Apply a staged change to it. Nish does this, because it cuts the phone link
  for about a minute:
  1. `sudo systemctl daemon-reload` — without it systemd keeps the `ExecStart`
     line it already loaded, so the new flag never takes effect.
  2. `sudo systemctl restart claude-remote-control.service`.
  3. `systemctl --no-pager status claude-remote-control.service` shows
     `active (running)` with no restart loop, and one message sent from the
     phone is answered by a session with a fresh context.

- Run it now: `sudo systemctl start --no-block fleet-update.service`, then
  `journalctl -u fleet-update -f`.
- Switch it off: a PR that drops "Enable the daily update" in
  `ansible/host.yml` and adds a task with `state: stopped, enabled: false`.
  In an emergency: `sudo systemctl disable --now fleet-update.timer`.
- Delete it: remove `ansible/update.yml`, the two `fleet-update` units and
  `50-fleet.conf`, and add their `/etc` paths to `retired` in `ansible/host.yml`.

