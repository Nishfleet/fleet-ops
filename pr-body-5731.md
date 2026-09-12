fix(stop-the-line): superseded-while-queued cancels carry no verdict

Closes #5731

## Why

fleet-ops#5731: during the 2026-09-12 merge burst (~7 merges in 33 min) three
consecutive main SHAs each got a CI run cancelled before a single job started
(34666055083, 34666440082, 34666533981 — conclusion=cancelled, jobs=[]). ci.yml
has cancel-in-progress=false for push, so GitHub replaced each still-QUEUED run
in the CI-refs/heads/main concurrency group the instant the next push created a
newer run. classifyHalt counted conclusion==cancelled as fail-closed red
(deliberate, fleet-ops#2911), producing 3 consecutive "red" SHAs, a false halt,
and freeze issue fleet-ops#5714 pausing auto-merge arming across the fleet. No
run ever actually failed.

## What

- `.github/scripts/stop-the-line-detector.mjs` (classifyHalt): a cancelled run
  now counts red ONLY when it is the newest sampled run for its workflow+branch
  (tip status unknown stays fail-closed) or it actually started jobs (killed
  in-flight). A cancelled run superseded while queued by a newer run in the
  same workflow+branch contributes no verdict — its SHA is skipped in the
  consecutive-red chain. Cancelled runs are NOT blanket-ignored, so the #2911
  masking hole stays closed: cancelled-after-start and a red-newest-tip still
  halt.
- The live fetch probes the jobs endpoint for non-newest cancelled runs to
  learn started-vs-never-started (the run list does not carry jobs and
  run_started_at equals created_at even for never-started runs).
- Freeze-issue bodies and detector reports now state per named run whether it
  FAILED / CANCELLED IN-FLIGHT / SUPERSEDED WHILE QUEUED, and list discounted
  runs explicitly — triage reads the distinction without replaying run history.
- Regression fixtures under `.github/fixtures/`: superseded-queued-cancels.json
  (3 consecutive cancelled-never-started runs + later unresolved head -> NO
  halt) and cancelled-after-start.json (MUST still halt).

## Verification

- `bash tests/stop-the-line-detector.test.sh` — all 14 stop-the-line cases pass,
  including "superseded-while-queued cancels + unresolved head -> noop" and
  "cancelled-after-start -> open with per-run dispositions".
- Termination snippet from the issue replayed live:
  `OK: no halt on superseded-queued cancels`.
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` clean.

run-proof: tests/stop-the-line-detector.test.sh (single test unit, full pass,
14 cases); detector probe run against a fixture replay of the live
34666055083/34666440082/34666533981 shape.

## Review adjudication

Single reviewer round deferred to the arm step; findings will be recorded here
per the review-adjudication buckets.

net-positive-because: the diff is mostly two regression fixtures (JSON replays
of the live run shape) plus the per-run disposition reporting in freeze bodies;
the classifier change itself is a narrow guard. Fixtures are the durable
regression net the issue's accept #2 requires.

loose-ends: none — the deploy-workflow runner-holding amplifier noted in the
issue (deploy waiter polling a never-started check) is deliberately out of
scope and tracked as a NEW issue filed by this worker.

## Test plan

- [x] bash tests/stop-the-line-detector.test.sh
- [x] issue termination snippet (computeBuckets eligible classifier only)
