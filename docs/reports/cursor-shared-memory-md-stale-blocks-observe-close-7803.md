# Observe-close for #7803 — cursor shared-memory.mdc stale blocks fixed on the live file; no renderer or gate exists to extend

Issue #7803 (filed from the #5735 fix run, same file, different blocks) named
two stale `nish-*` blocks in `/home/nish/.cursor/rules/shared-memory.mdc` —
the always-on Cursor rules surface on this VPS:

1. `nish-preimplementation-contract` carried the pre-#6610 wording —
   "present Goal, Blocking questions, Assumptions, and Plan, then stop for
   Nish's approval" for ALL non-trivial work. The canonical contract (vault
   `_system/shared-memory/pre-implementation-contract.md`, audited
   2026-09-19) stops for Nish ONLY on a reserved class or irreversible work —
   "engineer reversibility, don't gate". The live file gated everything, the
   opposite of the current rule.
2. `nish-memory-compound` mandated `memoryctl context|outcome|feedback|capture`
   per session. `memoryctl` was deleted in the 2026-09-18 sweep
   (`efaa7fa57`, "cut(memory-vault): delete the memoryctl loop, the vault
   linters and their units"), so every Cursor session read a mandate for a
   missing binary. `docs/ruthless-audit-2026-09.md` line ~890 already flags
   this: "memoryctl is a dead organ with live mandates".

The issue records that no generator renders either block
(`agent-surfaces.yaml` `block_types` covers only
memory_compound/agent_contract/graph_behavior, and that tooling is
quarantined), so the fix is a direct live-file edit with a dated backup +
actions.log line, same as #5735.

## What was done (live, 2026-09-22 ~02:56 UTC)

- Dated backup sibling: `/home/nish/.cursor/rules/shared-memory.mdc.pre-issue-7803-20260922T025607Z`
  (cp -a, preserves mode/mtime).
- `nish-preimplementation-contract` block REWORDED in place to current truth:
  plan on the record (Goal, blocking questions, assumptions, plan), then
  begin; stop for Nish's approval ONLY when the work touches a reserved class
  or is irreversible; engineer reversibility instead of gating; the
  proportionality exception unchanged.
- `nish-memory-compound` block DELETED outright — deletion-first. There is no
  current truth to reword to: the binary, the curator, and the quarantined
  tooling it described are all gone. Its one still-true sentence — the
  non-negotiable concise-ELI5 response style — survives as a plain bullet
  alongside the file's other plain rules (it is a response-style rule, not
  memory machinery).
- Attributed actions.log line appended to
  `/home/nish/workspaces/agent-state/actions.log` (devin-vps, 2026-09-22T02:56:44Z).

## Verification receipts (live file after edit)

- `grep -c memoryctl` → 0.
- `grep -c "then stop for Nish's approval"` → 0 (the stale universal gate).
- Marker audit: `nish-preimplementation-contract:start/end` and
  `nish-fleet-model-routing:start/end` balanced; no `nish-memory-compound`
  markers remain.
- `diff` against the backup shows exactly the two intended hunks and nothing
  else; frontmatter and the fleet-model-routing block (fixed by #5735) are
  untouched.

## Mechanism note (fleet-ops#366)

Detector/gate: mechanism-impossible for this surface by deliberate deletion.
The only gate that asserted this file's wording was
`tests/rulebook-host-drift.test.sh`, extended for the #5735 markers by
(closed, unmerged) PR #7804 and then deleted outright in the #7828 glue sweep
— Nish 2026-09-19: no new hand-built scripts, hooks or wrappers anywhere.
Re-adding a host-file assertion would recreate exactly the machinery the
sweep removed; the file is hand-maintained content with no renderer, so
there is no surviving organ to extend. This observe-close report is the
repo-committed resolution record and re-runnable evidence list.

Scope: `shared-memory.mdc` only. The sibling files in `~/.cursor/rules/`
(`fleet-packet-verdict.mdc` — a tracked symlink into `template/cursor-rules/`,
`pstack-models.mdc`, empty `MEMORY.md`) carry no memoryctl or pre-#6610
gating wording (checked live, same greps).
