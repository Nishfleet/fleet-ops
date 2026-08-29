fleet-ops#1145 slice 2 (Conflict B): split `nish-memory-compound` into two canonical sections and template the per-surface `--agent` token.

# What changed

Two new canonical sections replace the old `nish-memory-compound` block in `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`:

- `never-relay-finding` — the "Never relay a finding you could act on" heading + bullets. Used in the CLAUDE.md surface only; in AGENTS.md it stays a hand-written block (per its existing marker scope), the same call the issue made for it.
- `shared-memory-loop` — the `## Automatic shared-memory loop` heading + the six memoryctl bullets, used by BOTH surfaces.

## Scope fact the issue description did not carry

The issue described the second conflict as exactly two pieces (marker scope + per-surface `--agent`). Verification against the live files found a third scope difference inside the same block: the **failure-response bullet** sits inside CLAUDE.md's `nish-memory-compound` marker but lives in AGENTS.md's hand-written `## Safety` section (byte-identical in both, line 124 vs line 198). A single `shared-memory-loop` section could not carry it without either duplicating it in AGENTS.md or dropping it out of CLAUDE.md — both behavior-changing.

Solution mirrors the slice-1 `{{OLD_LAUNCHER_BLOCK}}` precedent (a block present in one surface's region and absent in the other's): a per-surface `{{FAILURE_RESPONSE_BLOCK}}` token. Claude's value is the bullet (its loop keeps it exactly where it was); Codex's value is empty (its loop never had it). Byte order in the always-loaded files is unchanged.

## The five per-surface occurrences

`shared-memory-loop` keys every `--agent` / `--verified-by` occurrence off `{{SURFACE_AGENT}}` — exactly five, as the issue's DONE-WHEN requires: `context (...--agent)`, `outcome (--agent + --verified-by)`, `feedback (--agent + --verified-by)`. Note: no `--agent-id` flag exists in the live commands; the live flags are `--agent` and `--verified-by`, and those five are templated. `capture` carries no per-surface token, so nothing is templated there.

# Behavior-preserving proof (byte-exact)

Diff of each live file against its pre-edit backup shows ONLY marker renames:

- `CLAUDE.md`: `<!-- nish-memory-compound:start -->` → `BEGIN GENERATED: never-relay-finding`; the separator blank line → `END GENERATED: never-relay-finding` + `BEGIN GENERATED: shared-memory-loop`; `<!-- nish-memory-compound:end -->` → `END GENERATED: shared-memory-loop`. No content dropped, no reorder, failure-response bullet preserved in place.
- `AGENTS.md`: only the two marker lines renamed. Everything else byte-identical.

Backups: `/home/nish/.local/state/standing-rules/bak-1153-20260829T015925Z/`.

# Verification

- `bash tests/standing-rules-drift.test.sh` → `ALL OK: 8/8 assertions passed` (and the new 4b split + token-binding assertion).
- Live `--check` is clean: `python3 /home/nish/.local/bin/render-standing-rules.py --canonical <vault> --check` → `OK (checked): 2 target(s), 6 section(s)`.
- Drift gate fires and recovers on the live system: hand-edit a generated region → `--check` exits 1 (`DRIFT in /home/nish/.claude/CLAUDE.md`) → `--render` restores byte-exact → `--check` exits 0.
- Token accounting: canonical has 0 literal `claude-vps`/`codex-vps`; the `shared-memory-loop` canonical body holds exactly 5 `{{SURFACE_AGENT}}`; the live CLAUDE.md region renders 5× `claude-vps`, live AGENTS.md renders 5× `codex-vps`, zero cross-leak, zero surviving `{{`.

run-proof: journal — `standing-rules-render.service`:
```
Aug 29 07:30:28 ... Starting standing-rules-render.service ...
Aug 29 07:30:28 ... python3[...]: OK (rendered): 2 target(s), 6 section(s)
Aug 29 07:30:28 ... Finished standing-rules-render.service ...
```
The path unit fired on the vault canonical write and rendered both live target files with the new generator (status=0/SUCCESS).

research: n/a — this slice adds no new `bin/` file (the generator already exists; only modified). Compared the issue's "two sections" shape against the discovered third scope difference and chose the slice-1 `{{OLD_LAUNCHER_BLOCK}}` presence-token mechanism over a third generated region, because a separate region would reorder the failure-response bullet relative to the loop heading and break byte-identity for CLAUDE.md.
help-first: n/a — no new `bin/` file.

# Live-config edits

| Path | Before | After |
|---|---|---|
| `~/.claude/CLAUDE.md` | `<!-- nish-memory-compound:start/end -->` block (Never-relay + loop, failure bullet inline) | two adjacent `BEGIN/END GENERATED` regions (`never-relay-finding`, `shared-memory-loop`) |
| `~/.codex/AGENTS.md` | `<!-- nish-memory-compound:start/end -->` block (loop only) | single `BEGIN/END GENERATED: shared-memory-loop` region; Never-relay stays hand-written at line 163 |
| vault `global-standing-rules.canonical.md` | 4 sections | 6 sections (+never-relay-finding, +shared-memory-loop) |
| `tooling/fleet-ops-deploy-clone/bin/render-standing-rules.py` | slice-1 generator | +`{{FAILURE_RESPONSE_BLOCK}}`, applied to the live symlink target so the path-fired render is clean now; absorbed by `origin/main` on merge |

# Deviation note

The deploy-clone is currently in a pre-existing deploy-flap (unrelated dirty tracked files `libexec/staleness-checker.py`, `prompts/scout-repair.md`; see `~/.local/state/fleet-heartbeat/deploy-audit.log`). This PR does not own that; the generator sync here is byte-identical to what `origin/main` will hold post-merge, so the next clean deploy absorbs it.

## Pre-existing gate false-positive found while running the worker preflight

`bin/fleet-token-efficiency-check` rejects `lib/standing-rules/canonical.md` (`prompt template placeholder before the static body`, first `{{` at line 48). That is a pre-existing misclassification on `origin/main` (identical first `{{SURFACE_PREIMPLEMENT_PHRASE}}` at line 48 in the merged file — slice-1), not introduced here; the canonical is a generator template source, not a model-prompt assembler. The gate is not run in any CI workflow. Filed as #1813 for the gate owner; not fixed in this slice so the generator template contract is not distorted.

mechanism-impossible: n/a — this is not a failure-fix; it is the slice-2 de-duplication feature. The existing drift gate (CI `standing-rules-drift` test + the live path-fired render + `--check`) is the prevention mechanism and is extended by the new 4b assertions.

Closes #1153
