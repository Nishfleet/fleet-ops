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
installed. A session with no network needs that metadata request to answer, so a
fully offline start is the local-install route Chrome DevTools MCP uses, not
this entry.

- Bump it: edit `config/drive-mcp.json` and run
  `tests/test_chrome_devtools_mcp.py`; the play holds no copy of the version.
- Check it: the `ci` step "Chrome DevTools wiring, hand-off cleanup and Claude
  lanes" pins the fragment's shape and runs the Cursor swap twice against a temp
  copy, asserting the pinned words and that the second run changes nothing.
