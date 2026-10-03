# Fleet host templates

Source files for the fleet host, linked or copied by hand (README.md,
"Install"). There is no installer.

- `agents/` — pi agent prompts. The live files under `~/.pi/agent/agents/` are symlinks into this repo (`docs/RUNBOOK.md`).
  - `planner.md` — "Creates implementation plans from context and requirements" (invoked by `prompts/worker.md` step 4).
  - `reviewer.md` — "Code review specialist for quality and security analysis" (invoked by `prompts/worker.md` step 7).
  - `scout.md` — "Fast codebase recon that returns compressed context for handoff to other agents" (not invoked by `prompts/worker.md`).
  - `worker.md` — "General-purpose subagent with full capabilities, isolated context" (not invoked by `prompts/worker.md`).
- `cursor-rules/shared-memory.mdc` — the always-on Cursor rule; `~/.cursor/rules/` links to it.
- `devin-config.json` — applied by hand with the `jq` command in README.md, section "Devin workspace-trust key".
