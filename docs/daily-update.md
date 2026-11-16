## Daily update

`fleet-update.timer` starts `fleet-update.service` on Sunday at 03:10 IST, in
the weekly maintenance window. It runs `ansible/update.yml` as root through
`ansible-pull`:

1. `npm update --global`, then `uv tool upgrade --all`, each capped at 900 s.
2. Ubuntu packages update through `unattended-upgrades` daily on the vendor's
   stock `apt-daily-upgrade.timer`, and Claude Code through its own
   auto-updater, so this run does not touch them.

A failed run retries after 30 min, at most 3 starts in 4 h, and then stays
`failed`, which `SystemUnitFailed` reads. A run that hangs fails at 45 min
(`TimeoutStartSec=`).

`fleet-update.service` never reboots. The restart that closes the window is
`fleet-reboot.timer`, Sunday 04:00 IST: unattended-upgrades'
`Automatic-Reboot-Time` is a time of day, not a weekday (shutdown(8)), so
`Unattended-Upgrade::Automatic-Reboot` stays `"false"` (the vendor default) in
`rootfs/etc/apt/apt.conf.d/52fleet-unattended-upgrades` and the pending reboot
is taken by the Sunday restart instead. The update starts at 03:10 with no
jitter (`RandomizedDelaySec=0`), so a run at its 45-minute cap
(`TimeoutStartSec=`) is done by 03:55. A kernel installed on any day takes
effect at the Sunday restart. The box comes back in about a minute; `fleet-host-config-boot.timer` reapplies the
host play three minutes after boot, which starts the runners, and GitHub's
queue sends the pending jobs to them. The security updates
(`unattended-upgrades`) stay on; `rootfs/etc/needrestart/conf.d/50-fleet.conf`
makes them only list services on old libraries, so they never restart a
service mid-job.
`hermes-gateway.service` and `hermes-serve.service` are not restarted by it
either, so they run on old system libraries until the next reboot.
`hermes-gateway.service` is the unit Hermes' own installer writes; `sudo hermes
gateway restart --system` restarts it and rewrites it when Hermes changes it.
`claude-remote-control.service` is never auto-restarted by needrestart: the
only restarts are Nish's own and the Sunday restart. A change to it is
therefore staged on merge: the file is copied in and
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
- Switch it off: a PR that drops "Enable the daily update" in
  `ansible/host.yml` and adds a task with `state: stopped, enabled: false`.
  In an emergency: `sudo systemctl disable --now fleet-update.timer`.
- The Sunday restart lives the same way: switch it off with
  `sudo systemctl disable --now fleet-reboot.timer`, delete it by removing
  the two `fleet-reboot` units and the "Enable the Sunday restart" task, and
  adding their paths to `retired` in `ansible/host.yml`.
- Delete it: remove `ansible/update.yml`, the two `fleet-update` units and
  `50-fleet.conf`, and add their `/etc` paths to `retired` in `ansible/host.yml`.

