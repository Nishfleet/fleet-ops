## Drive filesystem server

Claude Code's user config, `~/.claude.json`, carries one MCP entry: the official
filesystem server over `~/Drive`. `config/drive-mcp.json` owns that entry, and
the play hands it to Claude Code's own `mcp add --scope user drive` (after
`mcp remove` when the words on disk differ), so Claude Code writes its own config
and the play never rewrites it. Cursor's copy of the same entry is pinned by the
Cursor swap task, and only when Cursor already has a `drive` server. The package
spec is always an exact `@modelcontextprotocol/server-filesystem@<version>`:
with no version, `npx` installs whatever the registry calls latest, and a bad
release lands on the next session start. The pin is the whole change, and the
version is taken at least 3 days after its release. A host where Claude Code has
never run has no entry to add for, so nothing is created.

`npx` still asks the registry for the package metadata on every start. It then
runs the pinned copy it already has in `~/.npm/_npx`, so no new version is ever
installed. A session with no network needs that metadata request to answer, so
a fully offline start is the route a locally installed server takes, not this
entry.

- Bump it: edit `config/drive-mcp.json` and run
  `tests/test_mcp_and_agent_clis.py`; the play holds no copy of the version.
- Check it: the `ci` step "Every test under tests/, found by pytest, not listed
  here (fleet-ops#10721)" runs the whole suite, so the drive entry's shape and
  the Codex cleanup are pinned there.
