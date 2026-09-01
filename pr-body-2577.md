The rulebook-redteam audit (fleet-ops#2577) found the Pi example-extension count contradicting itself: the vault's global-standing-rules.md stated 74 at one rule body and  ican 79 at two others, and CLAUDE.md inherited the stale 74. A bare number with no source-of-truth anchor drifted between sections, so every "use Pi extensions before writing orchestration" prompt gave a different answer depending on which rule body an agent read.

The fix pins ONE number to the live reality everywhere it is named:

- **lib/standing-rules/canonical.md** — the shared-fleet-routing section now carries "Pi's 79 shipped example extensions (verified 2026-09-01: `ls ~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/ | wc -l`)", byte-identical to what the render emits into `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` (all three surfaces verified byte-identical via md5).
- The rendered surfaces were regenerated live with `bin/render-standing-rules.py --canonical <worktree canonical> --render`, so `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` now carry the 79 pin (the vault's global-standing-rules.md already carried the same pin in all three of its rule bodies..
- **tests/standing-rules-drift.test.sh** — new Assertion 9 (regression lock, fleet-ops#366): the canonical's count line must carry the dated `ls ... | wc -l` check command,and — when the Pi install is present — the pinned number must equal the live count. It fails the moment anyone bumps the number without re-running the check (or leaves it stale against reality..

Mechanism: the pinned dated check command (impossible-to-drift by construction, per the audit's proposal) plus a regression test in `tests/` that proves the guard fires on a stale/missing pin. No new bin/ file, no systemd unit, no workflow change.

 Note: `crgate` could not run locally on this box (CodeRabbit not signed in, exit 3); `sgscan` (clean) and the repo's `rule-enforcement` drill (green) covered the review instead.

Verification:
- `ls ~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/ | wc -l` → `79`
- `bin/render-standing-rules.py --canonical lib/standing-rules/canonical.md --check` → `OK (checked): 2 target(s), 6 section(s)`, exit  ican 0
- `bash tests/standing-rules-drift.test.sh` → `ALL OK: 9/9 assertions passed (...pi-count pin)`, exit  ican 0
- `bash tests/rule-enforcement.test.sh` (host drill that invokes the drift test) → `ALL TESTS PASSED`, exit  ican 0
- `sgscan` → `No new security findings`, exit  ican 0

run-proof: transcript — tests/standing-rules-drift.test.sh → "OK 9b: pinned count 79 equals the live Pi example-extension count (reality-checked)", exit  ican 0; render --check was clean; rule-enforcement drill green.

 Closes #2577