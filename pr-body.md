## What & why

Issue #1424 is the `escalate-senior` wrapper for the 0509 scout-futility
signal. It is supposed to be adjudicated by the senior-auditor panel
(`pi-escalation-audit` -> three POVs -> `pi-escalation-audit-tally`, which
files a fix issue on 2-of-3 PASS or closes on 2-of-3 FAIL).

But the panel for #1424 was **permanently wedged**: `devin` voted FAIL,
`free-glm-5-3` voted PASS, and `straitly` returned **SKIP** (a transient
provider failure from 2026-08-27 that `pi-audit-run` writes as exit 0 and
promises to "retry next tick"). Because a SKIP verdict counts as neither
PASS nor FAIL, the tally was stuck at PASS=1 FAIL=1 with no way to reach
2-of-3. The orchestrator treated the existing SKIP vote file as "present"
(`continue` in `process_escalation`) and never re-ran that role, so the
wedge was permanent. It was also *silent*: the tally path reset the pending
stamp every tick, so the `PANEL-PENDING` alarm never fired.

Root cause: a transient provider wall on one panel seat wedges the whole
escalation panel forever, leaving an escalate-senior issue unresolved
indefinitely — the exact kind of green-and-silent stall #1424 exposed.

For an `escalate-senior` issue, the escalation panel IS the disposition
path. This change makes that path able to actually reach a decision.

## Change

`bin/pi-escalation-audit`: in `process_escalation`, a vote file whose
verdict is not a real `PASS` or `FAIL` (e.g. a `SKIP` written on a transient
provider failure) is now discarded and that role re-run, instead of being
treated as a completed vote. The existing unit template's seat-health
preflight re-screens the seat before the next call, so a still-broken seat
keeps being retried and, if it never recovers, the `PANEL-PENDING` alarm now
actually fires (the pending stamp is no longer reset by a dead-end tally).

`tests/pi-escalation-audit.test.sh`: new scenario 6 — a role whose vote is
SKIP is discarded and re-run, and the tally is not called while a SKIP vote
is in place. This is the regression guard that proves the mechanism fires
(required by the mechanical-fix rule, fleet-ops#366).

## Verification

`bash tests/pi-escalation-audit.test.sh` -> `all pi-escalation-audit cases passed` (scenarios 1-7 green, including the new SKIP-wedge scenario).

test-run: reproduced the exact live #1424 wedge state (`devin=FAIL`,
`free-glm-5-3=PASS`, `straitly=SKIP`) and ran the fixed script against it:
it logs `fleet-ops/#1424: discarding incomplete/SKIP vote ... will re-run
straitly`, starts `pi-escalation-audit@fleet-ops--1424--straitly.service`,
does NOT call the tally, and the stale `straitly.vote` is gone.

`bash -n bin/pi-escalation-audit` -> OK
`escalation-units-shape`, `escalation-coverage-canary` -> green
`sgscan` -> No new security findings.

run-proof: none of the three Fleet-file gates apply here (no new bin/ file,
no unit/timer/workflow). The repo test suite above is the run.

research: n/a (no new bin/ file added; this edits an existing script).

help-first: n/a (no new bin/ file; reused the existing `vote_path`/JSON
conventions already in the file).

Closes #1424
