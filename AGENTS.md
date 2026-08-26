# Agent notes for fleet-ops

## Verification commands

- Rule-enforcement matrix: `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json`
- Live coverage check: `python3 lib/rule-enforcement.py join --rules $STANDING_RULES --ledger $DECISIONS_LEDGER --matrix config/rule-enforcement.json`
- Rule-enforcement tests: `bash tests/rule-enforcement.test.sh`
- Findings-queued session-close lint: `bash tests/fleet-findings-queued.test.sh`
- Decisions-ledger session-close lint: `bash tests/fleet-decisions-ledger.test.sh`
- Escalation canary tests: `bash tests/escalation-coverage-canary.test.sh`
- Skills-symlink canary: `bash tests/skills-symlink-canary.test.sh`
- Full P14 suite: `bash tests/manifest-shape.test.sh && bash tests/intake-repos-shape.test.sh && ...` (see `.github/workflows/ci.yml`)

## Useful env vars for canary

- `FLEET_RULE_ENFORCEMENT_FILE_ISSUES=1` enables auto-filing mechanism issues.
- `FLEET_RULE_ENFORCEMENT_UMBRELLA_ISSUES=416` tells the canary to auto-file queued rows owned by issue 416.
- `FLEET_RULE_ENFORCEMENT_NOW=YYYY-MM-DDTHH:MM:SSZ` fixes the "now" timestamp for queued-age checks in tests.
