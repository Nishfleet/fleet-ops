# Fleet host templates

Source files for the fleet host, linked or copied by hand (README.md,
"Install"). There is no installer.

- `agents/` — pi agent prompts. The live files under `~/.pi/agent/agents/` are symlinks into this repo (`docs/RUNBOOK.md`).
- `cursor-rules/shared-memory.mdc` — the always-on Cursor rule; `~/.cursor/rules/` links to it.
- `devin-config.json` — applied by hand with the `jq` command in README.md, section "Devin workspace-trust key".
