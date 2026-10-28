## Remote Control stays on (OOM storm 2026-10-09)

The phone link must not drop, and when it does someone must hear within
seconds. Measured on 2026-10-09: a secret scan (trufflehog over a full git
history) started from one Remote Control session grew to 15.4G RSS on the 32G
host. Nothing capped `claude.slice`, and everything under Remote Control
inherited `OOMScoreAdjust=-900`, which scores a 15G scan the same as an idle
session. The kernel killed the unprotected services instead (hermes, the
router, the executor) and stalled the link for about two minutes with all 8G
of swap full. Nothing alerted anyone.

| Piece | File | Takes effect |
| --- | --- | --- |
| `claude.slice` `MemoryHigh=14G` / `MemoryMax=18G` / `MemorySwapMax=2G` (normal use 6-7G, incident peak 21.5G) | `rootfs/etc/systemd/system/claude.slice` | at the daemon-reload after merge |
| `OOMPolicy=continue`: a killed child no longer stops the whole unit | `claude-remote-control.service.d/50-alert-on-stop.conf` | at the daemon-reload after merge |
| `ExecStopPost=` starts `fleet-unit-failed@claude-remote-control.service`, the existing healthchecks.io fail ping (fleet-ops#9033) | same file | next restart of Remote Control (Nish) |
| `OOMScoreAdjust=-900` to `-500`, so a runaway session child can be chosen | `claude-remote-control.service` | next restart of Remote Control (Nish) |
| Sandbox drop-in (kernel, clock, devices, `/proc`, `/home` read-only except `/home/nish`, address families, capability and syscall trims): `systemd-analyze security` 9.2 to 4.8 offline. `NoNewPrivileges`, `PrivateTmp` and `ProtectSystem` stay off on purpose, because sessions use `sudo`, `/tmp` and system edits | `claude-remote-control.service.d/80-hardening.conf` | next restart of Remote Control (Nish). Roll back: delete the file, reload, restart |
| `OOMScoreAdjust=-500` for `hermes-gateway.service` | `hermes-gateway.service.d/70-oom-protect.conf` | next restart of hermes (it restarts itself) |

The alert uses `ExecStopPost=` because `OnFailure=` never fires for this unit:
it fires on `failed`, and `Restart=always` with `StartLimitIntervalSec=0`
(`selfheal.conf`) sends every exit to auto-restart. A deliberate restart by
Nish pings too. The ping needs `HC_URL_RECONCILE` in
`~/.config/fleet-ops/keystone-hc.env`; unset, the handler logs SKIP and exits 0.
That check is shared with every `fleet-unit-failed@` caller and is fail-only,
so it stays down until it is re-armed with a success ping, and a second drop
while it is still down does not page again.

The LiteLLM router gets no `OOMScoreAdjust`: it runs in the user manager,
which cannot lower the value below its own 100 (measured:
`systemd-run --user -p OOMScoreAdjust=-500` reads back 100). The cap above is
what keeps it from being the victim.

Switch off: delete `50-alert-on-stop.conf` (alert and `OOMPolicy`), the
`MemoryHigh`/`MemoryMax`/`MemorySwapMax` lines in `claude.slice`, or
`70-oom-protect.conf`, then `systemctl daemon-reload`. Delete the file from
`rootfs/` and add its path to `retired` in `ansible/host.yml`, otherwise the
next run installs it again. The running `ExecStopPost=` and `-500` stay until
Remote Control is next restarted.

### Remote Control runs on the default login (2026-10-22)

`claude-remote-control.service.d/10-max-config.conf` (the filename is kept so
`ansible/host.yml` needs no change) holds `UnsetEnvironment=CLAUDE_CONFIG_DIR`,
so Remote Control and every session it spawns use the default Team-seat login
in `~/.claude`. From 2026-10-10 the drop-in pointed it at the personal Max
config dir `~/.claude-max`; on 2026-10-22 that login lost Remote Control
("Remote Control isn't enabled for this account") and the unit crash-looped on
the next restart. Setting `CLAUDE_CONFIG_DIR` to `~/.claude` (as an absolute
path) instead fails with "Workspace not trusted", because it reads a different
`.claude.json`.

Checked 2026-10-22: the unit has run on this login since 21:06 IST with
`NRestarts=0` (set by a runtime drop-in until this file landed), so the Team
seat does allow Remote Control. Usage and sessions now sit on that Team seat
and its organization, not on the personal Max login. `~/.claude/settings.json`
and `~/.claude-max/settings.json` have identical `permissions`, `hooks` and
`enabledPlugins`; only `env` differs. The Max config dir's Remote Control
environment stays listed on claude.ai as offline. A running server keeps its
environment; the change applies at the next restart of Remote Control, which
only Nish does, or when the unit's own restart loop next fires.

Switch off: put the old `Environment=CLAUDE_CONFIG_DIR=` line (the Max config
dir `~/.claude-max`, as an absolute path) back in place of the
`UnsetEnvironment=` line, `systemctl daemon-reload`, and restart Remote
Control, only once the Max login has Remote Control again.

### Subagents on the Max config dir (2026-10-11)

Historical since 2026-10-22: Remote Control no longer sets `CLAUDE_CONFIG_DIR`
and reads `~/.claude/agents` directly; the link below stays harmless.

Claude Code reads subagents from `$CLAUDE_CONFIG_DIR/agents`, so with the
drop-in above every Remote Control thread got "helper not found", and the
model-lanes gate denies every other subagent type: no thread could delegate.
`config/claude-agents/` now ships `helper.md` and `scout.md` (until now
hand-placed in `~/.claude/agents`). `fleet-sync.service` step 2d copies them
there, `config/user-tmpfiles.d/claude-max-agents.conf` links
`~/.claude-max/agents` to `~/.claude/agents` (step 5), and step 5b fails the
sync if that path is anything but the link. Edit an agent here, by PR; a hand
edit of the live file is overwritten on the next sync.
`tests/test_claude_max_agents.py` runs those unit lines against a temp home.

Switch off: delete the three step-2d install lines and step 5b, the tmpfiles
file and its live copy in `~/.config/user-tmpfiles.d/`, then
`rm ~/.claude-max/agents`. The live agent files stay as plain files.

