## claude.ai connectors off on the server

`rootfs/etc/claude-code/managed-settings.d/80-claudeai-connectors.json` sets
`disableClaudeAiConnectors: true`, Claude Code's own switch for the claude.ai
connectors on the account. Every Claude Code session on the box then starts
without them, instead of with the connectors that only work after a browser
login and fail with `! Needs authentication` in every server chat
(fleet-ops#10531). The switch is all-or-nothing, so it also turns off the five
that already work (Gmail, Google Drive, Docs, Sheets and Slides). Nothing on the
box reads through a connector: `mcp__claude_ai` appears in no prompt, config,
skill or systemd unit, and the Gmail read path is the Mac's claude.ai connector
(`docs/mac-scheduled-tasks.md`), not this box's sessions. The setting is
restrictive, so `true` in any settings source wins and a project or user file
cannot turn the connectors back on. Managed settings are read whatever
`--setting-sources` says, so worker lanes get the same opt-out (see "Beacon OTLP
drop-in"). The connectors stay connected in the claude.ai account and keep
working in claude.ai itself, so any of them can be used there, or switched back
on here, later.

- Verify: `claude mcp list` on the box lists the `claude.ai` connectors, most of
  them `! Needs authentication`; run again with this file as the settings source
  (`claude --settings <this file> mcp list`) and it lists none.
- Switch the connectors back on: fast, `sudo rm /etc/claude-code/managed-settings.d/80-claudeai-connectors.json`
  (the deploy copies `rootfs/etc` to `/etc`, so this deletes the deployed copy
  and takes effect for the next Claude Code launch, and the next
  `fleet-host-config.service` run puts the file back until a PR retires it).
  Durable: a PR that deletes the file from `rootfs/` and adds its `/etc` path to
  `retired` in `ansible/host.yml`.
