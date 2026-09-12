## Summary

The "One fleet" standing rule existed as three divergent copies: the vault's `global-standing-rules.md` heading (with the `— corrected 2026-08-25` amendment), the generated block in `~/.claude/CLAUDE.md`, and another in `~/.codex/AGENTS.md` — both generated copies silently dropped the amendment and carried their own paraphrase of the superseded machinery. Nothing detected the two written-independently sets from diverging.

Consolidation (title + pointer, the pattern `global-standing-rules.md` itself uses for every other rule):

- `lib/standing-rules/canonical.md` `one-fleet-rule` section is now exactly the canonical heading (with the amendment kept) plus a single `Full text:` pointer to `standing-rules-archive.md`. The vault stays the single wording authority.
- `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` regenerated via `bin/render-standing-rules.py --render`; `--check` exits 0 after the render.
- New detector `tests/one-fleet-rule-pointer.test.sh` guards the shape: heading must carry the amendment, body must be title + one pointer line, archive must contain the exact heading, and every rendered target on this host must echo the same title + pointer and must not regain the paraphrased body. Proven to FAIL against the pre-consolidation canonical (`canonical one-fleet heading does not carry the 'corrected 2026-08-25' amendment`) and pass after.

Root-cause addendum (salvage resume): the renderer's `DEFAULT_CANONICAL` points at the vault's `global-standing-rules.canonical.md`, so a default `--check`/`--render` silently uses the vault copy and a drifted one-fleet section there silently reverts a rendered consolidation. Fixed on host: the vault canonical's `one-fleet-rule` section now mirrors the repo canonical (title + amended heading + archive pointer; backup at `global-standing-rules.canonical.md.bak-rulebook-redteam-20260911`), and the default render was re-run so future fleet renders stick.

PRE-EXISTING gate finding: `fleet-token-efficiency-check` REJECTs this diff — 'lib/standing-rules/canonical.md:38: prompt template placeholder before the static body'. PRE-EXISTING, not introduced here: on main the same unchanged text sits at line 48/116 (~41%); this diff's line 38/95 (~40%) is the identical placeholder shifted up only by the one-fleet deletions above it. The checker has no baseline/pre-existing exemption; follow-up filed as Nishfleet/fleet-ops#5686.

Relates to fleet-ops#5588.

## Verification

- `python3 bin/render-standing-rules.py --canonical lib/standing-rules/canonical.md --render` → `OK (rendered): 2 target(s), 6 section(s)`; both `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` now render the amended heading + pointer (shown live above the render).
- Default `--check` after render → exit 0.
- `bash tests/one-fleet-rule-pointer.test.sh` → `OK: one-fleet-rule is title + archive pointer in canonical and every rendered target` (exit 0); pre-fix canonical run → exit 1 with the named FAIL line.
- `bash tests/standing-rules-drift.test.sh` → `ALL OK: 10/10 assertions passed` (exit 0).
- `bash -n tests/one-fleet-rule-pointer.test.sh` → 0.
- `sgscan` → `No new security findings`.
- Salvage resume: host state had drifted back (default canonical reverted the render). Re-synced the vault canonical one-fleet section to the repo canonical, re-rendered (default canonical), re-verified: `--check` exit 0, `tests/one-fleet-rule-pointer.test.sh` exit 0 (clean run after re-run to green), `tests/standing-rules-drift.test.sh` 10/10 exit 0.

## run-proof

units: pi-issue-fleet-ops-5588 (this run); drills: none required (test + generated-file consolidation, no unit/timer/workflow change).

## Test plan

- `bash tests/one-fleet-rule-pointer.test.sh`
- `bash tests/standing-rules-drift.test.sh`

loose-ends: one-fleet-rendered-targets

research: reused the canonical TEMPLATE/SECTION marker machinery and the existing title+pointer pattern from `global-standing-rules.md`; no new generator built.

help-first: `python3 bin/render-standing-rules.py --help`-style modes (`--check`, `--render`, `--canonical`) already cover regenerate + drift detection; nothing hand-built.

organs: none touched — no organ files in this diff. organ-heartbeat: n/a not-an-organ: only canonical.md + one test changed.
