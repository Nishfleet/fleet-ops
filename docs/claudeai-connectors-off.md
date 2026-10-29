## claude.ai connectors off on the server

`rootfs/etc/claude-code/managed-settings.d/80-claudeai-connectors.json` sets
`disableClaudeAiConnectors: true`, Claude Code's own switch for the claude.ai
connectors on the account. Every session on the box then starts without them,
instead of with the connectors that only work after a browser login and answer
`! Needs authentication` in every server chat (fleet-ops#10531). The switch is
all-or-nothing, so it also turns off the five that already work (Gmail, Google
Drive, Docs, Sheets and Slides). Nothing on the box reads through a connector:
the Gmail read path is the Mac's claude.ai connector
(`docs/mac-scheduled-tasks.md`), not this box's sessions. The setting is
restrictive, so `true` in any settings source wins and a project or user file
cannot turn the connectors back on. Managed settings are read whatever
`--setting-sources` says, so worker lanes get the same opt-out (see "Beacon OTLP
drop-in"). The connectors stay connected in the claude.ai account and keep
working in claude.ai itself, so any of them can be used there, or switched back
on here, later.

- Verify: `claude mcp list` on the box prints no `claude.ai` line, and the CLI
  logs `[claudeai-mcp] Disabled via disableClaudeAiConnectors setting` when
  connector loading is attempted.
- Switch it off: fast, `sudo rm /etc/claude-code/managed-settings.d/80-claudeai-connectors.json`
  (takes effect for the next Claude Code launch; running sessions keep their
  start-up values, and the next `fleet-host-config.service` run puts the file
  back until a PR retires it). Durable: a PR that deletes the file from
  `rootfs/` and adds its `/etc` path to `retired` in `ansible/host.yml`.
