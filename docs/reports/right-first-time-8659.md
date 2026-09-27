# Right-first-time before/after for #8659, and the 5461-5540 seat-trial read

Parent: #8659. Requested by #8674.

**Window:** 2026-09-27T08:37:15Z to write time 2026-09-27T08:46Z. The
window opens at the later merge time of the two blocking deliveries:
#8804 (issue #8670, the in-run stock reviewer) merged
2026-09-27T08:37:15Z; #8687 (issue #8671, packet paved-path wording)
merged 2026-09-25T12:56:37Z. Merge times are GitHub `mergedAt` (`gh pr
view <N> --json mergedAt`), the clock the issue's `created:` search
queries run on; git committer dates read earlier (bbefb59a
2026-09-27T08:35:04Z, fe04e695 2026-09-25T12:47:23Z) because the merge
queue creates the commit before the merge lands. At write time the
window is minutes old, far under 24 h. The issue anticipated this case,
so this report records the machinery read and the seat census, and a
re-measure issue (#8805) was filed.

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
census use it. Proof over the 306 PRs 0509 opened since 2026-09-25 —
`gh pr list -R Nishfleet/0509 --state all --search
"created:>=2026-09-25" --limit 500 --json comments`, first lines
matched on `^[A-Za-z]+ grade:` and grouped by prefix, re-run
2026-09-27T09:50Z: `Opus grade` 367, `Kimi grade` 76, ungrouped match
total 443. 367+76=443 leaves no other first-line prefix, so zero bare
`Grade:` comments exist (the Kimi tally read 74 at the 08:46Z write;
grading is still landing). First grade = earliest such comment; a PR's
grades = the count of them.

## Seat trial: the parity routing never shipped

The issue's premise was that sibling #8673 routes even issues
#5461-#5540 to Cursor and odd ones to Pi. It did not land:

- Issue #8673 (`agent.yml: seat trial, even 0509 issues #5461-#5540
  build on the Cursor lane`) is CLOSED with `stateReason: NOT_PLANNED`;
  its delivery PR #8696 (`claim/issue-8673`) closed unmerged after two
  B grades — `gh pr view 8696 -R Nishfleet/fleet-ops --json
  state,mergedAt,comments` returns state CLOSED, mergedAt null, and
  exactly two grade-comment first lines, both `Opus grade: B`.
- `git grep -n "5461\|5540" origin/main -- .github/workflows/agent.yml`
  produces no match (exit 1, both patterns).

So issue-number parity is not the seat that built each PR. The engine
gate on origin/main today is: `strong-only` issues go to Cursor (paced
to one run), every other issue goes Devin, then LongCat/opencode, then
pi, then `lanes-full`; the Cursor fallback for regular issues was
removed in #8743 (2026-09-26) and the opencode lane added in #8791
(2026-09-26). The ladder changed mid-census: the eleven 2026-09-25 PRs
below ran under the previous gate (`strong-only` to Cursor, else
devin / pi / cursor fallback); PR 5662 on 2026-09-27 already ran under
the new one.

How a PR gets its engine: take the newest `agent run started:` run on
the issue that predates the PR's `createdAt`, open that run's work job
(`dispatch / unblocked (claim/issue-<N>) / work`, or the run's single
`dispatch / new / work` job when the job list carries no per-issue
names — the log still names the issue), and read its `ENGINE:` log
line. That ordering is an approximation: a run still in flight at
`createdAt` can diverge from it, and 5662 below is exactly that case —
created by a devin run at 06:29Z, then reworked by an opencode run
whose commit landed 06:53Z. A PR's ENGINE here is its creator run's.
Attribution is per job, not per run: run 36148428291 alone hosts both
pi and devin work jobs (proof below). 12 PRs over 9 distinct issues; no
in-range claim PR predates 2026-09-25; all timestamps below are 2026
UTC.

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
The same correction was posted on #8659 at 2026-09-27T09:10:34Z.

### Evidence (re-run 2026-09-27T10:11Z)

All re-runs postdate the 08:46Z write and are corroborative only; the
counted numbers are the write-time ones.

Per-row ENGINE reads —
`gh api repos/Nishfleet/0509/actions/runs/<run>/jobs` to find the work
job, then `gh api repos/Nishfleet/0509/actions/jobs/<job>/logs |
grep -m1 'ENGINE:'`:

    PR 5524  issue 5503  run 36147889770  job 108114549010  ENGINE: cursor
    PR 5525  issue 5510  run 36148428291  job 108123720177  ENGINE: pi
    PR 5541  issue 5534  run 36155658311  job 108139444453  ENGINE: pi
    PR 5543  issue 5537  run 36156374620  job 108142244280  ENGINE: pi
    PR 5544  issue 5539  run 36156709062  job 108143253003  ENGINE: pi
    PR 5546  issue 5540  run 36156709062  job 108143253110  ENGINE: pi
    PR 5561  issue 5539  run 36163081274  job 108164161766  ENGINE: devin
    PR 5564  issue 5510  run 36163418643  job 108165277769  ENGINE: pi
    PR 5566  issue 5538  run 36164091539  job 108167782910  ENGINE: pi
    PR 5569  issue 5528  run 36169432908  job 108185123120  ENGINE: cursor
    PR 5572  issue 5539  run 36176034334  job 108206741073  ENGINE: pi
    PR 5662  issue 5483  run 36299924113  job 108565566927  ENGINE: devin

Two caveats inside that paste: job 108114549010 (5524) ended
`conclusion: failure` — the work job pushed the PR at 15:06:44Z and
failed later — and the mixed-engine run claim is `36148428291` hosting
`ENGINE: pi` jobs (108116614574 issue-5309, 108118540193 issue-5441,
108123720177 issue-5510) beside `ENGINE: devin` jobs (108116614692
issue-5411, 108125837543 issue-5423).

Grade first lines per PR — `gh pr view <PR> -R Nishfleet/0509 --json
comments`, bodies' first lines matching `^[A-Za-z]+ grade:`:

    5524: Opus grade: C
    5525: Opus grade: A+ | Opus grade: A- | Opus grade: A+ | Opus grade: A
    5541: Opus grade: A | Opus grade: A+
    5543: Opus grade: A- | Opus grade: A+
    5544: Opus grade: B | Opus grade: B
    5546: Opus grade: A | Opus grade: A+
    5561: Opus grade: B | Opus grade: A
    5564: Opus grade: A+ | Kimi grade: A+ | Kimi grade: A | Kimi grade: A+
    5566: Opus grade: C | Opus grade: C
    5569: Opus grade: C | Opus grade: B
    5572: Opus grade: A+
    5662: Kimi grade: A- | Kimi grade: A+

## `in-run review:` coverage

0 of the 12 claim PRs in range carry an `in-run review:` body line; 0 in
the after window. Expected: the worker step that emits the line landed
in #8804 at the window's own start (2026-09-27T08:37:15Z).

## Caveats

- Window < 24 h and every seat n<20, so #8805 `Re-measure right-first-time
  (fleet-ops#8659) once 0509 #5540 is graded` was filed (plain, no
  labels — `gh issue view 8805`: OPEN, created 2026-09-27T08:46:22Z,
  labels none) as the re-measure trigger; its body states the real gate
  (>=24 h of after-window and n>=20 per seat, measuring parity only if
  parity routing has actually shipped by then).
- Baseline letter scale predates #8655's A+ bar; after-window grades use
  the grades as posted (`Kimi grade:` is the 0509 grader of record since
  #8788).
- No config change was made. A seat choice moves spend and stays with
  Nish; nothing here proposes one.

encoded: 5 — the corrections this run made are facts, not code: the seat-trial premise (parity routing shipped by #8673) was false, so the census attributes each PR by its building run's `ENGINE:` log line instead, and the re-measure trigger is filed issue #8805. No lower rung can hold a measurement: there is no structure to delete, no gate to add, no rule or skill to write — the record is this prose report and the two measurement comments on #8659.
