# Daily digest prompts and the waiting count

The morning and evening digests are Hermes jobs whose prompts live in this repo:
`config/hermes/digest-morning.md` and `config/hermes/digest-evening.md`. The
deploy applies them. [The digest prompts' canonical
home](mac-scheduled-tasks.md#the-digest-prompts-canonical-home-fleet-ops9706)
covers that deploy, the live-copy diff and the pause commands. This page covers
the one thing that section does not: where the "and N more waiting" number comes
from, and how to switch the waiting lines off.

## One printed number, no arithmetic

Step 2a of both prompts is a single command. It reads every open issue labelled
`needs-nish-decision` from every repository with issues enabled, stores each one,
classifies each stored item, and prints the reply's facts. Two of those printed
lines carry the count:

- `WAITING_TOTAL <n>` is the number of open issues that carry the label, counted
  during the same sweep that prints the `ROW` lines.
- `WAITING_MORE <n>` appears one line below `WAITING_TOTAL` only when that number
  is larger than two. It is `WAITING_TOTAL` minus the two waiting items the reply
  may name: "and N more waiting" is that line, copied as it stands.
- `WAITING_COUNT FAILED` replaces both when a repository's issue list could not
  be read. The reply then says the count could not be read and writes no overflow
  line.

Step 3 may not count anything. It names at most two waiting items from the `ROW`
lines and copies the overflow number from `WAITING_MORE`, so the number it speaks
is the sweep's own labelled backlog rather than a count of the lines it happened
to print. The wording that told the model to keep the count to itself, while
still printing "and N more waiting", is gone: the same run carried both rules,
and the model resolved them by writing a number it had no source for.

Two bounds stay, and the page states them rather than promising more than the
command holds. One sweep reads at most 1000 labelled issues per repository, so a
repository above that cap makes the total too low. The overflow line is written
only when two items are named, so a run that names one item or none says nothing
about the rest of the backlog.

Two digest runs put a wrong number in that line. Run `150bb7b3` (2026-10-22)
named two waiting items and said "and 13 more waiting", while 68 open issues
carried the label: it named two of 68, so the line it should have written was
"and 66 more waiting", and 66 issues went unnamed. Run `06829ce1` (2026-10-26)
stated "and 5 more waiting" in a run that held no new item. The number was wrong,
not the sweep: the sweep had already stored every labelled issue. Both are Hermes
execution ids, and the digest job's history on the host lists each one.

## Switch the waiting lines off

The count lines are printed either way. Switch the wording off with these edits.

1. Delete the paragraph in step 3 of both `config/hermes/digest-morning.md` and
   `config/hermes/digest-evening.md` that starts `In the reply, waiting items take
   at most two short lines` and ends `and writes no overflow line.`
2. Delete `test_the_reply_copies_the_printed_waiting_count` from
   `tests/test_digest_checks.py` and the `"and N more waiting"` pin from
   `tests/test_digest_reply_shape.py`, because both assert the wording you just
   removed.
3. Run both test files, then land all four edits in one PR. The deploy applies
   the new prompt to the live jobs.

`WAITING_TOTAL` and `WAITING_MORE` stay printed either way, and
`tests/test_digest_checks.py` keeps checking them. To stop a digest instead of
changing it, [pause the job](mac-scheduled-tasks.md#the-digest-prompts-canonical-home-fleet-ops9706):
`3acce3a945cb` is the morning job and `682de9846caa` the evening one.

## What CI holds

`tests/test_digest_checks.py` runs both step-2a commands against a fake `gh` and
a fake notepad. It pins the count to the labelled backlog: 68 labelled issues with
46 already stored print `WAITING_TOTAL 68` and `WAITING_MORE 66`, a backlog of two
prints no overflow line, and a repository whose list fails prints
`WAITING_COUNT FAILED` and no total. It also fails a step 3 that stops copying the
printed number, and one that writes the `WAITING_TOTAL` number. One case holds the
object the step saves: the two count fields never reach the stored notepad.
`tests/test_digest_reply_shape.py` keeps the reply contract, including the "and N
more waiting" line.

Run both files for a prompt change:

    python3 -m pytest -q tests/test_digest_checks.py tests/test_digest_reply_shape.py
