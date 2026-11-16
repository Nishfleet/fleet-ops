## Weekly update

`fleet-update.timer` starts `fleet-update.service` every Sunday at 03:10 IST.
It runs `ansible/update.yml` as root through `ansible-pull`:

1. `npm update --global`, `uv tool upgrade --all`, `rustup update`,
   `bun upgrade`, `rclone selfupdate` and `gh extension upgrade --all`, each
   capped at 900 s.
2. Ubuntu packages update through `unattended-upgrades` at Sunday 03:00 (see
   below), and Claude Code through its own auto-updater, so this run does not
   touch them.

A failed run retries after 30 min, at most 3 starts in 4 h, and then stays
`failed`, which `SystemUnitFailed` reads. A run that hangs fails at 45 min
(`TimeoutStartSec=`).

`fleet-update.service` never reboots. The window's restart is
`fleet-reboot.timer`: a stock oneshot at Sunday 04:00 that runs
`systemctl reboot`. It fires every week, not only in a week with a kernel
update, and it lands after both the 03:00 Ubuntu upgrade and the 03:10 tool
run. `Unattended-Upgrade::Automatic-Reboot` is `false`, because the vendor's
reboot would be a second owner of the same instant. The box comes back in
about a minute; `fleet-host-config-boot.timer` reapplies the host play three
minutes after boot, which starts the runners, and GitHub's queue sends the
pending jobs to them. The weekly security updates stay on;
`rootfs/etc/needrestart/conf.d/50-fleet.conf` makes them only list services on
old libraries, so they never restart a service mid-job.
`hermes-gateway.service` and `hermes-serve.service` are not restarted by it
either, so they run on old system libraries until the next reboot.
`hermes-gateway.service` is the unit Hermes' own installer writes; `sudo hermes
gateway restart --system` restarts it and rewrites it when Hermes changes it.
`claude-remote-control.service` is never auto-restarted by needrestart: the
only restarts are Nish's own and, in a week with security updates, the Sunday
reboot. A change to it is therefore staged on merge: the file is copied in and
the running server keeps its old session until Nish restarts it or a Sunday
reboot applies it, because that restart cuts his phone link (#9425). The staged file as of 2026-10-08 adds
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
- Switch it off: a PR that drops "Enable the weekly update" in
  `ansible/tasks/services.yml` and adds a task with `state: stopped, enabled: false`.
  In an emergency: `sudo systemctl disable --now fleet-update.timer`.
- Delete it: remove `ansible/update.yml`, the `fleet-update` and `fleet-reboot`
  units and `50-fleet.conf`, and add their `/etc` paths to `retired` in
  `ansible/host.yml`.

