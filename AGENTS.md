# Agent notes for fleet-ops

## Verification commands

- Rule-enforcement matrix: `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json`
- Live coverage check: `python3 lib/rule-enforcement.py join --rules $STANDING_RULES --ledger $DECISIONS_LEDGER --matrix config/rule-enforcement.json`
- Rule-enforcement tests: `bash tests/rule-enforcement.test.sh`
- Rulebook red-team (monthly + backup gate): `bash tests/fleet-rulebook-redteam.test.sh`
- Findings-queued session-close lint: `bash tests/fleet-findings-queued.test.sh`
- Decisions-ledger session-close lint: `bash tests/fleet-decisions-ledger.test.sh`
- Failed-command session-close lint: `bash tests/fleet-failed-command-flagged.test.sh`
- Debug-playbook session-close lint: `bash tests/fleet-debug-playbook.test.sh`
- Interventions-eliminated session-close lint: `bash tests/fleet-interventions-eliminated.test.sh`
- Escalation canary tests: `bash tests/escalation-coverage-canary.test.sh`
- Cancelled-while-queued detector drill (fleet-ops#819): `bash tests/cancelled-while-queued-detector.test.sh`
- Replay with the actual enrolled set: `node .github/scripts/cancelled-while-queued-detector.mjs --targets-from config/intake-repos.json --dry-run --output-json /tmp/cwq.json`
- Full P14 suite: `bash tests/manifest-shape.test.sh && bash tests/intake-repos-shape.test.sh && ...` (see `.github/workflows/ci.yml`)

## Useful env vars for canary

- `FLEET_RULE_ENFORCEMENT_FILE_ISSUES=1` enables auto-filing mechanism issues.
- `FLEET_RULE_ENFORCEMENT_NOW=YYYY-MM-DDTHH:MM:SSZ` fixes the "now" timestamp for queued-age checks in tests.
