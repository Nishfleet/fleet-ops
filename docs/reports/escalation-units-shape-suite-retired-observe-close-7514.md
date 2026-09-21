# Observe-close for #7514 — escalation-units-shape suite and the drain it tested are both retired

Issue #7514 (filed 2026-09-17) reports `bash
tests/escalation-units-shape.test.sh` failing its nested
fleet-escalation-drain scenario 3 — "FleetStuck (old, no terminal) must
be ARCHIVED under archived/stuck" — reproduced on then-main
`af146adffc6c36591fb0985cd084434581b94896`. Acceptance: fix the
drain/test mismatch and run the suite to green without weakening
archival assertions.

By the time this claim ran (2026-09-22) the entire escalation-tower —
the shape test, the drain test it nested, and the drain itself — had
been deleted from main. There is no mismatch left to fix and no suite
left to run. This report is the resolution record.

## What was found

1. **The failure was real at the pinned SHA.** At
   `af146adffc6c36591fb0985cd084434581b94896`,
   `tests/escalation-units-shape.test.sh` exists and hosts the drain
   behavior test via `bash "$here/fleet-escalation-drain.test.sh"`
   (line 222, "fleet-ops#2677 + #2773: host the escalation-drain
   behavior test here"). `tests/fleet-escalation-drain.test.sh` at that
   SHA contains scenario 3: `packet-FleetStuck-20260820T000000Z.md`, an
   old packet with no terminal ledger entry, expected to converge to
   `agent-state/alert-repair/archived/stuck/` with a DISPOSITION line.
   The issue's reproduction stands as recorded.
2. **The whole surface is deleted on main.** `9f0cba02c`
   ("chore(glue-sweep): delete escalation-tower (16948 lines, Jev
   0.87)", committed 2026-09-18 by the sweep, ancestor of origin/main)
   removed `tests/escalation-units-shape.test.sh`,
   `tests/fleet-escalation-drain.test.sh`, and `bin/fleet-escalation-drain`
   along with the rest of the escalation layer (OnFailure drop-ins,
   stop-escalation path/service, daily sweep, auditor summons — the
   commit body documents the tower as ~1,300 paid auditor runs per week
   of pure self-watch).
3. **The failure mode today is file-absent, not an assertion.**
   `bash tests/escalation-units-shape.test.sh` on origin/main →
   `bash: tests/escalation-units-shape.test.sh: No such file or
   directory`. `git cat-file -e origin/main:<path>` → fatal for all
   three paths.
4. **No live code still references the surface.** Repo-wide search for
   `escalation-units` / `escalation-drain` / `FleetStuck` /
   `archived/stuck` matches only historical `docs/reports/` records and
   the `.fleet/bench7371/` benchmark corpus — no test, workflow, unit,
   or helper.
5. **The acceptance clause is unreachable as written.** "Fix the
   drain/test mismatch and run the suite to green" presumes both sides
   of the mismatch still exist. Neither does — same shape as #5721
   (observe-close #8089) and #6845, where the named suite was deleted
   with the rail it exercised. There is nothing to weaken: the archival
   assertions retired with the subsystem they measured.
6. **The defect class is retired, not merely masked.** The mismatch was
   between `bin/fleet-escalation-drain`'s converge path and the drain
   test's archival expectations. Both files are gone; the class has no
   carrier on main.

## Acceptance verification (2026-09-22, netcup-rs2000)

| Check | Result |
|---|---|
| Test file on origin/main | `git cat-file -e origin/main:tests/escalation-units-shape.test.sh` → fatal: path does not exist |
| Nested drain test on origin/main | `git cat-file -e origin/main:tests/fleet-escalation-drain.test.sh` → fatal: path does not exist |
| Drain on origin/main | `git cat-file -e origin/main:bin/fleet-escalation-drain` → fatal: path does not exist |
| Deleting commit on main | `git merge-base --is-ancestor 9f0cba02c origin/main` → yes (origin/main `f12ec3295`) |
| Suite run on main | `bash tests/escalation-units-shape.test.sh` → ENOENT, cannot fail an assertion |
| Files at pinned SHA | `git cat-file -e af146adff:tests/escalation-units-shape.test.sh` → exists; drain test exists; scenario 3 present |
| Open PR on `claim/issue-7514` | `gh pr list --state all --json headRefName` → none before this run |

## Why the acceptance resolves as retired, not fixed

"Fix the existing drain/test mismatch" has no object: a mismatch needs
two living sides, and both were deleted deliberately in a reviewed
sweep the day after the issue was filed. "Run the suite to green" has
no suite. Restoring any part of the 16,948-line escalation-tower to
satisfy the letter of the clause would re-add machinery the fleet
deleted on purpose — the wrong answer even though it would turn the
named command green.

## Residual note

The issue carries `agent-in-progress` from this claim
(`pi-issue-fleet-ops-7514`, claimed 2026-09-21T20:18:58Z; an earlier
attempt produced no worktree, no salvage commits, and no PR). This
record's PR performs the `Closes #7514` close — the same observe-close
path used for #5721, #6845, #6926, and the other sweep-deleted
surfaces. No follow-up is filed: the drain, its tests, and the
drain/test-mismatch defect class are all retired code.
