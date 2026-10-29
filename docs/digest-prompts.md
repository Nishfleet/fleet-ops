# Daily digest prompts and the waiting count

The morning and evening digests are Hermes jobs whose prompts live in this repo:
`config/hermes/digest-morning.md` and `config/hermes/digest-evening.md`. The
deploy applies them, and how that deploy and the live-copy check work is in
[Mac daily update](mac-scheduled-tasks.md). This page covers the one thing that
page does not: where the "and N more waiting" number comes from, and how to
switch the waiting lines off.

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
lines and copies the overflow number from `WAITING_MORE`, so the count cannot
drift away from the label it describes. The wording that told the model to keep
the count to itself, while still printing "and N more waiting", is gone: the same
run carried both rules, and the model resolved them by writing a number it had no
source for.

Three runs of that rule, on 2026-10-22 and 2026-10-26 (`execution 150bb7b3` and
`execution 06829ce1`), named two waiting items and stated a small total while 68
open issues carried the label. The number was wrong, not the sweep: the sweep
already stored all 68.

## Switch the waiting lines off

The count line is printed either way, so switching the wording off is one edit to
one file.

1. Delete the sentence in step 3 that starts `In the reply, waiting items take at
   most two short lines` in both `config/hermes/digest-morning.md` and
   `config/hermes/digest-evening.md`.
2. Land the edit through a PR. The deploy applies it to the live jobs.
3. Diff the live prompt against the file to confirm the deploy reached it.

To stop the digest itself, pause the job instead: `hermes cron pause <job id>`
for `3acce3a945cb` (morning) or `682de9846caa` (evening).

## What CI holds

`tests/test_digest_checks.py` runs both step-2a commands against a fake `gh` and
a fake notepad. It pins the count to the labelled backlog: 68 labelled issues with
46 already stored print `WAITING_TOTAL 68` and `WAITING_MORE 66`, a backlog of two
prints no overflow line, and a repository whose list fails prints
`WAITING_COUNT FAILED` and no total. It also fails a step 3 that stops copying the
printed number. `tests/test_digest_reply_shape.py` keeps the reply contract,
including the "and N more waiting" line.

Run both files for a prompt change:

    python3 -m pytest -q tests/test_digest_checks.py tests/test_digest_reply_shape.py
