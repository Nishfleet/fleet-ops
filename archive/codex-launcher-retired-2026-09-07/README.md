# Retired: codex launcher governance wrapper — fleet-ops#4148

Archive of the hand-built Codex launcher governance stack, retired 2026-09-07
under Nish's "nothing hand built" endorsement (umbrella #4140, row 9;
DECISIONS comment on #4148, resolved by the claude-vps orchestrator).

These files were loose under `~/.local` and never tracked in any git repo.
This directory is the archive — git history is the backup (same rule as
fleet-ops#4141). Live copies were wiped with `rm`, not parked.

| File | Live path (deleted) | Lines (live) | Purpose |
|---|---|---|---|
| `codex` | `~/.local/bin/codex` | 281 | PATH wrapper that gated real Codex agent sessions before exec |
| `governed-run` | `~/.local/bin/governed-run` | 31 | Ad-hoc supervised-run helper importing the runtime |
| `agent-governor-runtime/` | `~/.local/libexec/agent-governor-runtime/` | ~3,660 | Governance brain: broker/manifest/trace/registry + certified/launch/gate integrations |

## Why retired

The wrapper enforced launch-time identity/policy gates by hand:

- Luna requires `provider=openai` + `agent_type=executor_luna` (+ model
  `gpt-5.6-luna`, effort `max`, `fork_turns=none`).
- Sol efforts allow-listed to `{medium, xhigh}`; approved models frozenset
  `{gpt-5.6-luna, gpt-5.6-sol}`; Sol requires `provider=openai`.
- Identity-conflict detection across CLI flags, `--config` TOML, and
  `CODEX_HOME/config.toml` profiles.
- `evaluate_certified` + `ToolBroker.decide("launch_codex_session", ...)`.
- Process-group supervision + `AGENT_GOVERNOR_*` marker injection for the
  orphan watchdog.

## What replaced it (per-role systemd unit templates — paper)

- `systemd/codex-sol@.service` — Sol identity by construction:
  `codex-real -m gpt-5.6-sol -c model_provider=openai`, effort = instance
  (`@medium` / `@xhigh`).
- `systemd/codex-luna@.service` — Luna identity by construction:
  `codex-real -m gpt-5.6-luna -c model_provider=openai -c model_reasoning_effort=max`.

A role can only launch through its template; the ExecStart cannot express
another identity. Anything the wrapper enforced that cannot be expressed as a
fixed ExecStart was dropped and is listed in the fleet-ops#4148 PR body
(`agent_type`/`fork_turns` wrapper-internal markers, `--oss`/`--local-provider`
denial, broker decision, signal-supervision — the last replaced natively by
systemd `KillMode=control-group`).

## Endorsement

- Nish 2026-09-07 "nothing hand built" — umbrella #4140.
- DECISIONS comment on fleet-ops#4148 (claude-vps orchestrator): canonical
  issue is #4148; #4159 closed as duplicate; unit/timer wipe is out of scope
  (that is #4158); archive first, then templates, then one real Sol packet run
  through `codex-sol@`, only then wipe.

Do not rebuild unless the per-role unit templates are retired AND a launch-time
identity gate is genuinely required again — and even then prefer an
off-the-shelf mechanism.
