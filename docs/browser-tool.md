## Browser tool: Chrome DevTools MCP

One free browser tool for every agent CLI on the box: the Chrome DevTools MCP
server driving the system `/usr/bin/google-chrome` headless (DISPLAY is unset),
in a throwaway profile (`--isolated`, deleted on exit), with usage statistics
and CrUX lookups off. Chrome starts on the first browser tool call and exits
when the client disconnects; an idle server is one Node process (about 170 MB).
A page load peaked at about 1.1 GB across the Node process and Chrome. This is
the default browser (vault `global-standing-rules.md`); browser-use cloud stays
for narrow fan-out only and its entries are not touched.

`config/chrome-devtools-mcp/package.json` and `package-lock.json` own the pin
(one exact version plus the lockfile's integrity hashes, bumped by a PR; no
`npx` and no `@latest` at runtime); `ansible/host.yml` owns the argument list.
The play copies both files under `~/.local/share/chrome-devtools-mcp`, runs
`npm ci --ignore-scripts` there when they changed or `node_modules` is missing
(not `npm -g`: the daily `npm update --global` would move a global install
past the pin) and links `~/.local/bin/chrome-devtools-mcp` to it.

Every task that touches nish's home runs `become_user: nish`, never as root:
nish controls those paths, and a root task would follow a planted symlink
(`~/.config/mcp` to `/etc`, `mcp.json` to a root-only file). The tasks sit
after `flush_handlers` and before the credential assert, so a missing
credential file does not hold them back.

| Agent | How it gets the tool |
|---|---|
| Claude Code | no plugin: the `chrome-devtools` mod left the nish-mods marketplace, and the drop-in that enabled it is retired. Worker lanes run `--strict-mcp-config`, which hides plugins, so `agent.yml` passes `--mcp-config` with `config/worker-mcp.json` (bare `chrome-devtools-mcp` from `~/.local/bin`). |
| Pi | the play merges the entry into `~/.config/mcp/mcp.json`, the shared MCP file pi-mcp-adapter reads (lazy lifecycle; other servers in it are kept). `rootfs/etc/tmpfiles.d/chrome-devtools-profiles.conf` ages out profile dirs a killed server leaves in `/tmp`. |
| OpenCode | the play writes `/etc/opencode/opencode.json`, OpenCode's managed config. |
| Devin, command-code | `devin mcp add` and `cmd mcp add --scope user`, run by the play when the entry is missing or its output lacks the command or any argument; a CLI that is not installed is skipped. |
| Cursor | the play swaps the dead `camofox-browser` entry in `~/.cursor/mcp.json` for `chrome-devtools`, keeping the other servers. Cursor still asks for approval (`cursor-agent mcp enable chrome-devtools`). |
| Hermes | one `chrome-devtools` line under `mcp_servers:` in `~/.hermes/config.yaml`, added when absent and `mcp_servers:` is a bare key (`mcp_servers: {}` or no key is left alone). Its built-in `browser` toolset needs the `agent-browser` CLI and its own Chromium, which this box does not have. |
| Codex | not installed; the play drops the dead `camofox-browser` table from `~/.codex/config.toml`. |

- The Devin, OpenCode and Pi worker lines in `agent.yml` pass no flag that hides these configs (no `--config`, `--no-mcp` or `--no-extensions`), so those workers get the tool as well; the jail binds `/` read-write, so Chrome and the link are visible in it.
- Verify: `chrome-devtools-mcp --version` prints the pin; `devin mcp get chrome-devtools`, `opencode mcp list`, `cursor-agent mcp list`.
- Switch off for one agent: remove its task (Claude Code has no plugin left to
  disable, so a worker lane that must lose the tool drops its `--mcp-config`
  line); `copy` never
  deletes, so also add `/etc/opencode/opencode.json` to `retired` for OpenCode.
- Delete it all: remove the OpenCode tasks and the tasks from "Create the Chrome
  DevTools MCP install directory" through "Add the chrome-devtools entry under
  Hermes' mcp_servers" in `ansible/host.yml`, `config/chrome-devtools-mcp/` and
  `tests/test_chrome_devtools_mcp.py` with its `ci.yml` step, then
  `devin mcp remove` and `cmd mcp remove` the entry by hand.
- The check is the `ci` step "Chrome DevTools MCP is pinned once and wired into
  every agent": the args match in every fragment, and the Cursor, Codex and
  Hermes tasks run twice against temp copies (the second run changes nothing).

