# Right-first-time before/after for #8659, and the 5461-5540 seat-trial read

Parent: #8659. Requested by #8674.

**Window:** 2026-09-27T08:37:15Z to write time 2026-09-27T08:46Z. The
window opens at the later merge time of the two blocking deliveries:
#8804 (issue #8670, the in-run stock reviewer) merged
2026-09-27T08:37:15Z; #8687 (issue #8671, packet paved-path wording)
merged 2026-09-25T12:56:37Z. At write time the window is minutes old,
far under 24 h. The issue anticipated this case, so this report records
the machinery read and the seat census, and a re-measure issue (#8805)
was filed.

## Before/after first grades (0509)

| cohort | window | graded PRs | first-grade mix | first-grade A+ | grades/PR |
|---|---|---|---|---|---|
| baseline (per #8659) | 24 h to 2026-09-25 17:45 IST | 330 | 5A / 219B / 63C / 40D / 3F | n/a (pre-#8655 letter scale) | 1.4 |
| after | 2026-09-27T08:37:15Z to write | 0 | none | none | none |

Zero 0509 PRs were opened inside the window:
`gh pr list -R Nishfleet/0509 --state all --search "created:>=2026-09-27T08:37:15Z" --limit 500 --json number`
returned count=0 at 2026-09-27T08:40Z. The **grades/PR <= 1.1 target is
not evaluable**, and no first-grade A+ share exists.

Grades are PR comments whose first line starts `Opus grade:` or
`Kimi grade:` (grade.yml posts under whichever grader the repo variable
names; #8788 made Kimi the 0509 grader of record). The issue text also
named a bare `Grade:` prefix for after #8655; zero comments in the
census use it. Proof over the 306 PRs 0509 opened since 2026-09-25
(`gh pr list -R Nishfleet/0509 --state all --search "created:>=2026-09-25" --limit 500 --json comments`):
comment first-lines matching `^[A-Za-z]+ grade:` tally 367
`Opus grade:` and 74 `Kimi grade:`. First grade = earliest such comment;
a PR's grades = the count of them.

## Seat trial: the parity routing never shipped

The issue's premise was that sibling #8673 routes even issues
#5461-#5540 to Cursor and odd ones to Pi. It did not land:

- Issue #8673 (`agent.yml: seat trial, even 0509 issues #5461-#5540
  build on the Cursor lane`) is CLOSED with `stateReason: NOT_PLANNED`;
  its delivery PR #8696 (`claim/issue-8673`) closed unmerged after two
  B grades.
- `git grep -n "5461\|5540" origin/main -- .github/workflows/agent.yml`
  produces no match.

So issue-number parity is not the seat that built each PR. The engine
gate on origin/main today is: `strong-only` issues go to Cursor (paced
to one run), every other issue goes Devin, then LongCat/opencode, then
pi, then `lanes-full`; the Cursor fallback for regular issues was
removed in #8743 (2026-09-26) and the opencode lane added in #8791
(2026-09-26). The ladder changed mid-census: the eleven 2026-09-25 PRs
below ran under the previous gate (`strong-only` to Cursor, else
devin / pi / cursor fallback); PR 5662 on 2026-09-27 already ran under
the new one.

The census attributes each claim PR in range to the `ENGINE:` line of
its `claim/issue-<N>` `work` job in the dispatch run that produced it:
the run in that issue's `agent run started:` comment thread whose work
ends at the PR's `createdAt` (equivalently, the latest listed run
started before it). One dispatch run hosts many per-issue jobs with
different engines (run 36148428291 alone has both pi and devin jobs), so
the job, not the run, is the unit of attribution. 12 PRs over 9 distinct
issues; no in-range claim PR predates 2026-09-25. A PR's ENGINE here is
its creator run's: later rework pushes can come from a different engine
(5662 was created by a devin run at 06:29Z, then reworked by an opencode
run whose commit landed 06:53Z).

| PR | issue | building run | ENGINE (job log) | created | state | first grade | grades |
|---|---|---|---|---|---|---|---|
| 5524 | 5503 | 36147889770 | cursor | 09-25T15:06:44Z | CLOSED | C | 1 |
| 5525 | 5510 | 36148428291 | pi | 09-25T15:06:51Z | CLOSED | A+ | 4 |
| 5541 | 5534 | 36155658311 | pi | 09-25T15:48:27Z | MERGED | A | 2 |
| 5543 | 5537 | 36156374620 | pi | 09-25T15:51:40Z | MERGED | A- | 2 |
| 5544 | 5539 | 36156709062 | pi | 09-25T15:53:36Z | CLOSED | B | 2 |
| 5546 | 5540 | 36156709062 | pi | 09-25T15:54:52Z | MERGED | A | 2 |
| 5561 | 5539 | 36163081274 | devin | 09-25T16:56:56Z | CLOSED | B | 2 |
| 5564 | 5510 | 36163418643 | pi | 09-25T16:57:28Z | OPEN | A+ | 4 |
| 5566 | 5538 | 36164091539 | pi | 09-25T17:05:22Z | CLOSED | C | 2 |
| 5569 | 5528 | 36169432908 | cursor | 09-25T18:16:52Z | CLOSED | C | 2 |
| 5572 | 5539 | 36176034334 | pi | 09-25T18:56:02Z | MERGED | A+ | 1 |
| 5662 | 5483 | 36299924113 | devin | 09-27T06:29:29Z | MERGED | A- | 2 |

Per-engine roll-up (the closest thing to a seat table that exists):

| engine | n (PRs) | first-grade mix | first-grade A+ share | grades/PR |
|---|---|---|---|---|
| pi | 8 | A+ x3, A x2, A- x1, B x1, C x1 | 37.5% | 2.38 |
| cursor | 2 | C x2 | 0% | 1.5 |
| devin | 2 | A- x1, B x1 | 0% | 2.0 |
| opencode | 0 | none | none | none |

Under the parity labels the issue assumed, this same census would have
misread as "Cursor (even N): A+ x2, A x2, C x2, 2.67 grades/PR; Pi (odd
N): A+ x1, A- x2, B x2, C x1, 1.67". 8 of 12 PRs would have been
credited to a seat that did not build them: of the parity-"Cursor" six,
only 5569 was actually cursor (5525, 5564, 5541, 5566, 5546 were pi);
of the parity-"Pi" six, only 5543, 5544, 5572 were actually pi (5524
was cursor; 5561, 5662 were devin). No engine winner is named: every
seat is far under n=20 and the trial the comparison was for never ran.

## `in-run review:` coverage

0 of the 12 claim PRs in range carry an `in-run review:` body line; 0 in
the after window. Expected: the worker step that emits the line landed
in #8804 at the window's own start (2026-09-27T08:37:15Z).

## Caveats

- Window < 24 h and every seat n<20, so #8805 `Re-measure right-first-time
  (fleet-ops#8659) once 0509 #5540 is graded` was filed (plain, no
  labels) as the re-measure trigger; its body states the real gate
  (>=24 h of after-window and n>=20 per seat, measuring parity only if
  parity routing has actually shipped by then).
- Baseline letter scale predates #8655's A+ bar; after-window grades use
  the grades as posted (`Kimi grade:` is the 0509 grader of record since
  #8788).
- No config change was made. A seat choice moves spend and stays with
  Nish; nothing here proposes one.
