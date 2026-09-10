## What

The `red-main-suspicion` guardrail grouped open PRs by CHECK NAME only, so a busy queue where 4 PRs fail the same-named `P14 tests / PR checks` check for DIFFERENT reasons read as "main is red" when main was green. Crying wolf is the failure mode: a judge hunts a main-red fix that does not exist, and a detector that fires on every busy queue is one a judge learns to ignore — so a GENUINE red main arrives pre-discredited.

This PR extracts the detector into `bin/fleet-red-main-suspicion` and groups by (check name + normalised FAIL line), not check name alone. For each open PR failing a required check it pulls the first real `FAIL:` line from the job log, normalises it (strips absolute paths and PR-specific file names), and groups branches sharing the SAME normalised cause. Only >=3 branches sharing one cause is `red-main-suspicion`; branches sharing a check name but not a cause emit the throughput line `pr-checks-red`, never a guardrail line.

The positive control (3 branches, one normalised cause) still fires, so the detector is not weakened — only made cause-aware.

## Verification

Ran the detector against the current open-PR set (2026-09-10):

```
$ bash bin/fleet-red-main-suspicion
pr-checks-red: 3 PRs, 2 distinct causes
```

The 3 open PRs failing `P14 tests / PR checks` (#4830, #4792, #4422) have 2 distinct normalised causes (#4830/#4792 share an unwired-test-file cause, #4422 is a scenario regression) — so the line is the throughput line, NOT `red-main-suspicion`. Main is green.

run-proof: `bash tests/fleet-red-main-suspicion.test.sh` (false-positive drill + positive control + normalisation + empty set) all PASS; `bash tests/p14-test-listing-gate.test.sh` PASS (test hosted from ci-standards-audit.test.sh, in the P14 reachable set); `shellcheck -s bash bin/fleet-red-main-suspicion` clean; `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` OK; gate-integrity PASS (no gate-owned path touched).

## Tests

`tests/fleet-red-main-suspicion.test.sh` (hosted from `ci-standards-audit.test.sh` so P14 runs it without a workflow-file edit — workers cannot push `.github/workflows/**`):
- FALSE-POSITIVE DRILL: 4 PRs, 3 distinct causes -> `pr-checks-red: 4 PRs, 3 distinct causes`, NOT `red-main-suspicion`.
- POSITIVE CONTROL: 3 branches, 1 normalised cause -> `red-main-suspicion: 3 branches share FAIL: shellcheck not clean on` still fires.
- NORMALISATION: same-reason PRs collapse, different reasons stay distinct.
- EMPTY SET: no failing PRs -> `pr-checks-red: 0 PRs, 0 distinct causes`.

## Research

research: live search of the existing `red-on-main-detector` (a CI-failure detector for 0509, different class) and the landing-watch measure.sh's inline count compared against the cause-grouping approach; the cause-grouping approach was adopted.

help-first: read `gh pr list --help` and the existing measure.sh red-main block before building; no existing tool groups by normalised FAIL cause, so a new detector was warranted.

Closes #4845

net-positive-because: the detector logic is extracted into a testable repo script with a false-positive drill and positive control; the added lines are the script, its test, and the ci.yml listing — the durable, tested replacement for the hand-maintained inline block.
