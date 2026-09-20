# Gap-audit cap mechanism match for #6931

Issue #6931 asks to file or match a mechanism for a hand-performed
operation recorded in a memoryctl outcome capture: "Cap the gap-audit
auto-file generator so product work is claimable". The match is
fleet-ops#2844 and [PR #2933](https://github.com/Nishfleet/fleet-ops/pull/2933),
merged 2026-09-02 at 20:30:06 UTC as squash commit
`f3b5ff7fd7eedefade5a65318aedd5112408d49d`. No new detector or runtime
change is needed for this match.

## The flagged operation was queued work

The audit's evidence file
(`00 Inbox/agent-drop/cursor/vps/2026-09-02T20-29-13Z-outcome-20260902-202912-965374-cap-the-gap-audit-auto-file-generator-so-product-work-is-cl-edbdd63e-887143703d4b.md`)
is a cursor-vps outcome record that names its own queued mechanism in
the frontmatter and body:

- Goal line ends in `(fleet-ops#2844)`.
- `derived_from` and `sources` are
  `git:Nishfleet/fleet-ops@44caf5472ca76ab3b11a04748edf5c69c21ac633`, the
  work commit produced inside the `issue-fleet-ops-2844` worktree.
- The recorded result — `AUDIT_MAX_FINDINGS` default lowered 5 to 1 in
  `bin/fleet-blind-audit`, a closeout report added, tests passing — is
  what PR #2933 merged under title "cap fleet-blind-audit gap-audit
  filings at 1 so product work is claimable (fleet-ops#2844)".

Issue #2844 ("Queue self-maintenance ratio stuck at 0.77 for 84h
(FleetQueueSelfMaintenanceRatioHigh)") is CLOSED; PR #2933 is MERGED.
The "no queued mechanism issue" premise does not hold for this record:
the operation ran inside the standard queue and self-closed with its
issue. The generic duplicate suggestions on #6931 (#5741, #6185, #6928
at 0.90) are not used as proof; the 0.90 score reflects the shared
"[gap-audit] manual seam:" title prefix, not the same finding — #6928
concerns the #2899 semantic signal-key dedup seam.

## Verification

Checked on 2026-09-20 from branch `claim/issue-6931`, based on
`8cfc507bbe0c2fa38b1d29497b5aa5b625732cbb`.

- `gh pr view 2933` → MERGED 2026-09-02T20:30:06Z, merge commit
  `f3b5ff7fd7eedefade5a65318aedd5112408d49d`.
  `gh issue view 2844` → CLOSED.
- `gh api repos/Nishfleet/fleet-ops/compare/f3b5ff7...main` →
  `status: ahead`, `ahead_by: 1135`, `behind_by: 0`: the squash commit is
  an ancestor of main. (The deploy clone is shallow, so a local
  `merge-base --is-ancestor` could not prove this; the API compare does.)
- The PR #2933 closeout report remains on main at
  `reports/self-maintenance-ratio-2844-2026-09-03.md`.

## The generator and the filing audit are both retired

- `git ls-tree origin/main bin/fleet-blind-audit` → absent. The 1780-line
  generator was deleted on main by `f851c86cf`
  ("chore(glue-sweep): delete meta-metrics-scorers", 2026-09-18), which is
  an ancestor of origin/main.
- The audit's host state directory
  `/home/nish/workspaces/agent-state/fleet-blind-audit/` — including the
  `reports/20260914T221231Z/report.md` path the issue body cites — no
  longer exists (`ls` → ENOENT on 2026-09-20).
- Surviving `fleet-blind-audit` references on main are docs/reports
  history only; no executable, test, workflow, or unit remains.

## Disposition

Record #6931 as matched to #2844 / PR #2933. The flagged seam is closed
twice over: the operation was queued work with a merged PR, and both the
generator it capped and the blind-audit that flagged it were retired in
the 2026-09-18 glue sweep, so the finding cannot refire. This report
supplies the missing audit link only.
