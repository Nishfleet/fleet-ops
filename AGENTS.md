# Agent notes for fleet-ops

## Verification commands

- Rule-enforcement matrix: `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json`
- Live coverage check: `python3 lib/rule-enforcement.py join --rules $STANDING_RULES --ledger $DECISIONS_LEDGER --matrix config/rule-enforcement.json`
- Rule-enforcement tests: `bash tests/rule-enforcement.test.sh`
- Findings-queued session-close lint: `bash tests/fleet-findings-queued.test.sh`
- Decisions-ledger session-close lint: `bash tests/fleet-decisions-ledger.test.sh`
- Failed-command session-close lint: `bash tests/fleet-failed-command-flagged.test.sh`
- Escalation canary tests: `bash tests/escalation-coverage-canary.test.sh`
- Signal-reconcile tests: `bash tests/signal-reconcile.test.sh`
- Cancelled-while-queued detector drill (fleet-ops#819): `bash tests/cancelled-while-queued-detector.test.sh`
- Replay with the actual enrolled set: `node .github/scripts/cancelled-while-queued-detector.mjs --targets-from config/intake-repos.json --dry-run --output-json /tmp/cwq.json`
- Full P14 suite: `bash tests/manifest-shape.test.sh && bash tests/intake-repos-shape.test.sh && ...` (see `.github/workflows/ci.yml`)

## Useful env vars for canary

- `FLEET_RULE_ENFORCEMENT_FILE_ISSUES=1` enables auto-filing mechanism issues.
- `FLEET_RULE_ENFORCEMENT_UMBRELLA_ISSUES=416` tells the canary to auto-file queued rows owned by issue 416.
- `FLEET_RULE_ENFORCEMENT_NOW=YYYY-MM-DDTHH:MM:SSZ` fixes the "now" timestamp for queued-age checks in tests.

## Detector→queue reconciler (fleet-ops#362)

- Runs from `bin/fleet-heartbeat-tier1` block 38 with `TICK_START` filtered to the current tick.
- `lib/detector-queue-reconciler.py` is pure logic; tests use fake `gh` and `FLEET_ISSUE_FILE`.
- `FLEET_SIGNAL_RECONCILE_OK_TO_CLOSE=1` enables observe-to-close (default is 0 outside of the production heartbeat).
- `FLEET_SIGNAL_RECONCILE_DRY_RUN=1` prints the planned actions without calling `gh` or `fleet-issue-file`.
