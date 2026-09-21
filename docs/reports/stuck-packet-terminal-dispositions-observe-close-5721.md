# Observe-close for #5721 — land-or-close PR #5648: merged, then its whole surface retired

Issue #5721 (filed 2026-09-12) is a land-or-close ticket tracking PR #5648
("fix(alert-repair): converge stuck-packet LOUD loop into file-or-drop
terminal dispositions"), which sat `mergeable: CONFLICTING` when filed. Its
`termination:` clause is `gh pr view 5648 -R Nishfleet/fleet-ops --json
state --jq '.state=="MERGED" or .state=="CLOSED"'` — the PR reaching any
terminal state resolves the issue.

By the time this claim ran (2026-09-22), the metric was already satisfied
and the code surface itself was gone. No new code is needed; this report
is the resolution record.

## What was found

1. **PR #5648 is MERGED.** `gh pr view 5648` → state MERGED at
   2026-09-12T06:42:01Z, squash commit
   `33375d5dfca1b89a93c710f4b1844a3d19862c0d`. `git merge-base
   --is-ancestor 33375d5d origin/main` passes at origin/main `60a162739`
   — the fix is a true ancestor of current main.
2. **The live termination probe passes.** This run re-executed the issue's
   own `termination:` clause verbatim: `.state=="MERGED" or
   .state=="CLOSED"'` → `true`.
3. **Both named test suites are deleted.** `tests/alert-repair-stuck-packet.test.sh`
   and `tests/fleet-escalation-drain.test.sh` went with `9f0cba02c`
   ("chore(glue-sweep): delete escalation-tower (16948 lines, Jev 0.87)",
   2026-09-18, ancestor of origin/main). The accept bullet "re-run its
   tests" is unreachable as written — the same shape as #6467, where the
   suite the clause named was deleted with the rail it measured.
4. **The patched file is deleted.** `bin/fleet-escalation-drain` (1510
   lines) went with the same sweep; `git cat-file -e
   origin/main:bin/fleet-escalation-drain` → fatal, path does not exist.
   The defect class the issue tracked — stuck packets looping LOUD inside
   the drain — has no live code left to exhibit it.
5. **The earlier in-issue verification stands.** The 2026-09-12T13:35Z
   claim run recorded: GitHub compare `33375d5d...main` ahead/behind_by 0
   with merge base `33375d5d`; both suites green on then-main `25da515f`;
   neighbour #5660 merged 2026-09-12T03:04:30Z, before #5648's 06:42:01Z,
   so the rebase sat on top of it and no double-fix occurred; #5622 (the
   defect #5648 closed) is CLOSED via the merge.
6. **The possible-duplicate flag is a non-match.** The body header names
   #4734 (score 0.40) — a different, already-CLOSED land-or-close ticket
   for PR #4676. Nothing to confirm or merge there.

## Acceptance verification (2026-09-22, netcup-rs2000)

| Check | Result |
|---|---|
| `termination:` probe | `gh pr view 5648 -R Nishfleet/fleet-ops --json state --jq '.state=="MERGED" or .state=="CLOSED"'` → `true` |
| PR #5648 state | MERGED 2026-09-12T06:42:01Z, squash `33375d5dfca1b89a93c710f4b1844a3d19862c0d` |
| Squash on main | `git merge-base --is-ancestor 33375d5d origin/main` → yes (origin/main `60a162739`) |
| Named test files on main | `git ls-tree origin/main tests/` → both absent; deleted by `9f0cba02c` |
| `bin/fleet-escalation-drain` on main | `git cat-file -e origin/main:bin/fleet-escalation-drain` → fatal: path does not exist |
| Open PR on `claim/issue-5721` | `gh pr list --head claim/issue-5721 --state open` → none |

## Why the accept bullets resolve as landed, not rebased

Accept-1 ("rebase PR #5648 onto current main") is moot — the PR merged
2026-09-12, ten days before this run; there is nothing left to rebase.
Accept-2's test re-run is unreachable: both suites are deleted with the
rail they exercised, and the last executable run is the green record above.
Accept-3 (close #5648 if #5660 carried the surviving logic) is moot —
#5648 is not open to close, and neither PR's logic survives on main to
name a carrier. The metric's substance — "no stuck-packet LOUD loop
repaired by hand" — holds: the merged fix plus the subsequent subsystem
deletion is the record.

## Residual note

The issue carries `agent-in-progress` from this claim. The 2026-09-12
parking under `awaiting-runtime-gate` held the claim-spin until the
gate-release tick of 2026-09-20T20:32:29Z evaluated `termination:` →
MERGED and released it to `agent-ready` for this close-out run. This
record's PR performs the `Closes #5721` close under the trailer regime —
the same close path that replaced the deleted observe-to-close sweep
(fleet-ops#6467). No follow-up is filed: the drain, its tests, and the
LOUD-loop defect class are all retired code.
