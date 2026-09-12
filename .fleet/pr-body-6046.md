fix(#6046): dead-pr-detector TRAILER_RE knows the house `moves: #N` delivery trailer

## What

One-line pattern fix plus tests, exactly as the issue prescribes:

- `bin/fleet-dead-pr-detector` TRAILER_RE gains the `Mov(es|ed)` delivery verb and an optional colon between verb and ref (`moves: #5997`, `Moved #5997`, `Fixes: #595`). `moves:` stays a delivery (closing) signal only — TRAILER_RE, not RELATES_RE.
- Effect: a CONFLICTING PR whose body names an unrelated CLOSED issue before its real delivery target no longer dead-classifies on the wrong parent (live: PR #6027's body mentioned closed #3322 in a parenthetical, so the detector resolved parent=#3322 and emitted a dead-pr-human line naming the wrong parent, while the real delivery target #5997 was never consulted).
- Out of scope, untouched: `lib/deploy-fault-gate.sh` DF_TRAILER_RE (same verb family, no Mov) — the issue scopes the fix to the detector.

## Verification

bash tests/fleet-dead-pr-detector.test.sh → all 28 cases pass, including the three new ones:

```
OK: case26: unrelated-CLOSED-first-mention + 'moves: fleet-ops#5997' -> parent=5997, never 3322
OK: case27: 'moves: #1941', 'Moved #2133', 'Fixes: #595' all resolve as delivery trailers
OK: case28: prose 'moved' with no adjacent ref still falls through to first-bounded #N (priority 4)
all fleet-dead-pr-detector cases passed
```

Exit 0. Existing Closes/Fixes/Resolves cases (1-3), the bare-mention priority-4 cases (8, 14) and the never-guess skips (6, 9, 18) are unchanged and green — the never-guess rule is intact.

Live replay of the shipped regex against the REAL PR #6027 body (the issue's evidence, live-queried): `resolve_parent(#6027 body) = 5997` at TRAILER priority — before this fix the same body resolved 3322 via priority 4. #5997 and #3322 are both CLOSED, so the verdict row was right on #6027 only by luck; the wrong-parent shape (live fix PR reads DEAD) is now impossible. First proof attempt of this replay returned an empty parent — my repro failed to export the body into the subshell, not a detector failure; named and re-run to the green result above.

sgscan --base origin/main: no new security findings (rc 0). First call used a wrong flag (`sgscan --staged` → `unknown flag: --staged`); re-run per `sgscan --help` with `--base` — green.

run-proof: bash tests/fleet-dead-pr-detector.test.sh → "all fleet-dead-pr-detector cases passed" (28/28, exit 0); hermetic (mocked gh shim, no network) — the same gates CI runs on this diff. No new unit, timer, or workflow: the detector keeps its existing ExecStartPre slot on the fleet-merged-pr-close unit, and the tier1 heartbeat consumes it unchanged.

organ-heartbeat: bin/fleet-dead-pr-detector not-an-organ: not registered in config/fleet-organs.json; it is a detector consumed by fleet-heartbeat-tier1, and this diff is internals-only (no timer, unit, or absent() wiring touched). bin/fleet-organ-heartbeat-check gate on the diff: "SKIP: no fleet organ touched in the diff" (exit 0).

## Review adjudication

- Consider — lib/deploy-fault-gate.sh DF_TRAILER_RE lacks the Mov verb too. Noted, deliberately not acted on: the issue scopes the fix to bin/fleet-dead-pr-detector, and no evidence there shows the same wrong-parent trip. Recorded here as the follow-up surface.
- Noted — the existing suite already pinned the Closes/Fixes/Resolves and priority-4 fallthrough cases; no duplication added beyond the issue's prescribed pins (colon form, bare moves, past tense, prose-moved).
- Dismissed — adding `Move(s|d)` past tense? `Mov(es|ed)` already covers `move`/`moves`/`moved`; `moving` is prose, never a GitHub closing keyword.

review: fleet-ops is not a product repo in config/intake-repos.json (only 0509 is, product: true), so the one-round senior-reviewer step is exempt for this PR.
loose-ends: crgate local review gate not run (CodeRabbit not signed in on this machine — `coderabbit auth login` is Nish's; same precedent as #6092). No others: the fix is one regex line + tests, scope complete per the issue.

No agent names in the diff (bin/fleet-no-agent-names-check: REJECT=0 findings). Token budget: diff is +57/-5 across 2 files, no new machinery, no new dependencies.

## Test plan

`bash tests/fleet-dead-pr-detector.test.sh` — the standing hermetic guard for this detector; cases 26-28 pin the new trailer behavior, the full existing matrix proves no regression. `bash -n` clean on both touched files. CI (gitleaks/semgrep/manifest) covers the tree.

Closes #6046

