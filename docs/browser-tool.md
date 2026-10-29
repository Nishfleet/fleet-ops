## Browser tool

Owner: none (fleet-ops#10208). No agent CLI on this box is served a browser
tool. The decision is recorded here and nowhere else.

The `chrome-devtools` mod that used to launch one was deleted from
Nishfleet/claude-mods (issue Nishfleet/claude-mods#10, PR
Nishfleet/claude-mods#13) after the 2026-10-23 glue audit found it was glue:
the mod only started the vendor `chrome-devtools-mcp` binary with hand-picked
flags. The stock replacement there is the official `playwright` plugin from the
`claude-plugins-official` marketplace, enabled in `~/.claude/settings.json` for
interactive sessions only, and `85-no-playwright.json` switches it off in every
session on this host (fleet-ops#10529). The DevTools-only uses (performance
traces, Core Web Vitals through `--no-performance-crux`) are dropped with it.

For the worker lanes and the non-Claude CLIs the audit named one choice, not
seven: the version pin, the argument list and the per-agent config writes were
the same glue the mod was. So the pin, the install tree and every server write
are gone, and no CLI gets a replacement.

What this repo no longer ships:

- `config/chrome-devtools-mcp/package.json` and `package-lock.json`, the pin.
- `config/worker-mcp.json`, the worker lane's server list.
- `rootfs/etc/claude-code/managed-settings.d/60-chrome-devtools.json`, which
  enabled the deleted mod. An `enabledPlugins` entry for a plugin no
  marketplace provides is ignored silently, so it was dead wiring, not a break.
- `rootfs/etc/tmpfiles.d/chrome-devtools-profiles.conf`, which aged out the
  Chrome profile dirs a killed server left in `/tmp`.
- The play's install tasks, its write of `~/.config/mcp/mcp.json` (the shared
  file pi-mcp-adapter reads) and its `chrome-devtools` line under Hermes'
  `mcp_servers:` in `~/.hermes/config.yaml`.
- `mcp__chrome-devtools` in the Claude worker lane's `--allowedTools` and the
  lane's `--mcp-config` line: `--strict-mcp-config` still runs, so the lane
  serves no MCP server at all.

`copy` never deletes, so the next `fleet-host-config.service` run takes the
host files the play can reach: `~/.local/bin/chrome-devtools-mcp`,
`~/.local/share/chrome-devtools-mcp` and
`/etc/tmpfiles.d/chrome-devtools-profiles.conf` are in `retired` in
`ansible/host.yml`, with the link listed before the directory it points into so
it does not dangle.

What no play run can reach, so it is removed by hand after the merge:

- `~/.config/mcp/mcp.json`, `~/.cursor/mcp.json` and `~/.hermes/config.yaml`
  each still carry the entry.
- `devin mcp remove chrome-devtools` and `cmd mcp remove chrome-devtools`.
- The two Chrome Desktop `ccd-cli` sessions that were running a server read an
  MCP source this audit could not identify, so quit and restart those sessions.

Verify after the merge and a play run: `rg -i chrome.devtools` finds only this
file and the tests that hold the removal in place, and
`pgrep -af chrome-devtools-mcp` shows no process.

The check is the `ci` step "Every test under tests/, found by pytest, not
listed here (fleet-ops#10721)", which runs `tests/test_mcp_and_agent_clis.py`.
That file asserts the deleted files stay deleted, that no task writes a browser
server into any agent config, that `ansible/host.yml` names the wiring only in
its retired list, and that the Claude worker lane passes no `--mcp-config`.
