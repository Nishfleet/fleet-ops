## Daily update

`fleet-update.timer` starts `fleet-update.service` every day at 03:30 IST.
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
   plugins, cursor-agent, devin, uv, bun, rclone, syncthing). Stale npm
   staging dirs (`.*-stage-*` under the npm global root) are deleted first,
   because one left by an interrupted self-update makes `npm update --global`
   exit non-zero.
   Cua Spaces has no apt repository, so when a newer stable release exists and
   no desk run is turning, the run downloads its `.deb`, checks the sha256
   against the release's `checksums.txt`, installs it, restarts the Cua daemon,
   deletes and creates the `desk` Space again (the agent's files stay in the
   Cua Volume on the host), and smoke-tests one throwaway Space. Any failure
   fails the run.
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
`hermes-gateway.service` and `hermes-serve.service` are not restarted by it
either, so they run on old system libraries until the next reboot.
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

