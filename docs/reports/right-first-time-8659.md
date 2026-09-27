# Right-first-time before/after for #8659 — plus the 5461–5540 seat trial

Parent: #8659. Requested by #8674.

**Window:** 2026-09-27T08:37:15Z → 2026-09-27T08:5xZ. The window opens at
the later merge time of the two blocking deliveries: #8804 (issue #8670,
the in-run stock reviewer) merged 2026-09-27T08:37:15Z; #8687 (issue
#8671, packet paved-path wording) merged 2026-09-25T12:56:37Z. At write
time the window is minutes old — far under 24 h. The issue anticipated
exactly this case, so this report records the machinery read and the
seat-trial census, and a re-measure issue was filed.

## Before/after first grades (0509)

| cohort | window | graded PRs | first-grade mix | first-grade A+ | grades/PR |
|---|---|---|---|---|---|
| baseline (per #8659) | 24 h to 2026-09-25 17:45 IST | 330 | 5A / 219B / 63C / 40D / 3F | n/a — pre-#8655 letter scale | 1.4 |
| after | 2026-09-27T08:37:15Z → now | 0 | — | — | — |

Zero 0509 PRs were opened inside the window
(`gh pr list -R Nishfleet/0509 --state all --search "created:>=2026-09-27T08:37:15Z" --limit 500`
→ count=0 at 2026-09-27T08:40Z), so the **grades/PR <= 1.1 target is not
evaluable** and no first-grade A+ share exists.

Grade comments are matched on the three live prefixes — `Opus grade:`,
`Kimi grade:` (the grader hand-off to Kimi, #8788) and `Grade:` (#8655's
unified bar). In the 306 PRs 0509 opened since 2026-09-25 there are 367
`Opus grade:` and 74 `Kimi grade:` comments. First grade = the earliest
such comment; a PR's grades = the count of them.

## Seat trial — 0509 issues #5461–#5540

Routing per #8673 (issue closed 2026-09-25T13:14:05Z): even issue N →
**Cursor** lane (grok-4.7-xhigh), odd N → **Pi** lane (router). Population
= every 0509 PR whose head is `claim/issue-<N>` with 5461 <= N <= 5540 —
12 PRs over 9 distinct issues. No in-range claim PR predates 2026-09-25
(the range's issues were still being opened when routing went live).

| seat | n (PRs) | first-grade mix | first-grade A+ share | grades/PR |
|---|---|---|---|---|
| Cursor (even N) | 6 | A+×2, A×2, C×2 | 33% | 2.67 |
| Pi (odd N) | 6 | A+×1, A−×2, B×2, C×1 | 17% | 1.67 |

Per-PR detail:

| PR | issue | seat | created | state | first grade | grades |
|---|---|---|---|---|---|---|
| 5525 | 5510 | Cursor | 2026-09-25T15:06:51Z | CLOSED | A+ | 4 |
| 5564 | 5510 | Cursor | 2026-09-25T16:57:28Z | OPEN | A+ | 4 |
| 5569 | 5528 | Cursor | 2026-09-25T18:16:52Z | CLOSED | C | 2 |
| 5541 | 5534 | Cursor | 2026-09-25T15:48:27Z | MERGED | A | 2 |
| 5566 | 5538 | Cursor | 2026-09-25T17:05:22Z | CLOSED | C | 2 |
| 5546 | 5540 | Cursor | 2026-09-25T15:54:52Z | MERGED | A | 2 |
| 5662 | 5483 | Pi | 2026-09-27T06:29:29Z | MERGED | A− | 2 |
| 5524 | 5503 | Pi | 2026-09-25T15:06:44Z | CLOSED | C | 1 |
| 5543 | 5537 | Pi | 2026-09-25T15:51:40Z | MERGED | A− | 2 |
| 5544 | 5539 | Pi | 2026-09-25T15:53:36Z | CLOSED | B | 2 |
| 5561 | 5539 | Pi | 2026-09-25T16:56:56Z | CLOSED | B | 2 |
| 5572 | 5539 | Pi | 2026-09-25T18:56:02Z | MERGED | A+ | 1 |

Both seats sit far under n=20, so **no winner is named** — Cursor shows a
higher first-grade A+ share but also more rework rounds per PR; at n=6
that direction is anecdote, not signal. Two issues (5510, 5539) produced
more than one claim PR; the table counts each PR attempt, as the seat
exposure is per attempt.

## `in-run review:` coverage

0 of the 12 seat-trial PRs carry an `in-run review:` body line; 0 in the
after window. Expected — the worker step that emits the line landed in
#8804 at the window's own start (2026-09-27T08:37:15Z), so nothing built
under the new packet could exist yet.

## Caveats

- Window < 24 h and both seats n<20 → filed #8805 `Re-measure
  right-first-time (fleet-ops#8659) once 0509 #5540 is graded` (plain, no
  labels) as the re-measure trigger.
- Baseline letter scale predates #8655's A+ bar; the after-window rows use
  the post-#8655 grades as posted.
- No config change was made. If a seat ever wins at adequate n, the
  follow-up to move the seat line is a separate issue — the choice moves
  spend and stays with Nish.
