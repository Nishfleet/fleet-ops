## What & why

`CLAIM-REAP-STARTED` is `pi-issue-failed-reap`'s **entry** log line, written when the reaper begins its automatic post-failure cleanup (`pi-issue@.service` OnFailure). It fires on **every** real reap — the triage file shows instance 0509-2298 STARTing five times in one hour, and every one is followed by a successful `CLAIM-REAP-RELEASED` / `PACKETS-ARCHIVED`. A reap starting is the expected recovery step, not a fault.

The detector→queue reconciler (fleet-ops#362) was treating `CLAIM-REAP-STARTED` as a loud alarm and filing a near-never-green issue per reap, keyed on the repo (`loud/claim-reap-started/nishfleet-0509`). The actionable reaper outcomes already carry their own loud tags (`CLAIM-REAP-BRANCH-FAIL`, `CLAIM-REAP-LABEL-FAIL`, `CLAIM-REAP-PARSE-FAIL`, `CLAIM-REAP-NO-GH`) that still queue. This files issue #4918.

## Fix

Add `CLAIM-REAP-STARTED` to `SKIP_TAGS` in `lib/detector-queue-reconciler.py` — the same precedent used for the informational `DEBUG-PLAYBOOK-MISSING` deterrent log (fleet-ops#4620). It no longer derives a signal, so it is not queued; observe-to-close then clears any already-filed `loud/claim-reap-started/...` issue (including #4918) on the next real heartbeat tick.

## Verification

- `bash tests/signal-reconcile.test.sh` — full suite green, including new scenarios:
  - **9f** `CLAIM-REAP-STARTED` derives no signal and files nothing (`filed==0`, `alarm_count==0`).
  - **9g** an already-open `loud/claim-reap-started/nishfleet-0509` issue observe-to-closes while fresh STARTED lines fire (the #4918 clearing mechanism).
- `bash tests/pi-issue-failed-reap.test.sh` — green (reaper behavior untouched).
- `bash tests/timer-manifest-drift-canary.test.sh` — green.

run-proof: `tests/signal-reconcile.test.sh` scenarios 9f, 9g; reconciler `derive_signals`/observe-to-close path.

## Test plan

None needed beyond the above — this is a two-line reconciler config change plus guarded tests; CI runs typecheck/coverage for fleet-ops.

Closes #4918
