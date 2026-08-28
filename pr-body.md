## Why

The rule-coverage canary (fleet-ops#383) found the D1 prod migration process amendment (decisions-ledger 2026-08-27) with no live enforcer. The rule requires that production D1 migration execution goes through a senior process: strong lane plan + independent senior blind-review + apply + live verification + text Nish. Never single-agent apply.

This PR adds a CI drill that proves the worker prompt carries this gate, and marks the rule as enforced in the enforcement matrix.

## Scope

- `prompts/worker.md`: New "D1 prod migration execution rule" section after the existing D1 schema rule. Tells workers to block themselves and route through `blocked-on: senior-conference` when a task involves applying a prod D1 migration.
- `tests/fleet-d1-prod-migration-process.test.sh`: New CI drill. Three scenarios: (1) worker.md contains the five execution needles, (2) dropping any needle is rejected, (3) the enforcement matrix row is `enforced` with the right mechanism and proof.
- `tests/rule-enforcement.test.sh`: Wires the new drill in, following the same pattern as the existing D1 grant test.
- `config/rule-enforcement.json`: Marks `led-2026-08-27-d1-prod-migrations-process-amendment` as `enforced` with the mechanism and proof pointing at the new drill. The diff also normalizes Unicode escapes throughout (jq round-trip, cosmetic only — no data changes).

## Tradeoffs

The enforcement is at the prompt level (worker.md needle check), not at the execution level (e.g., detecting an actual `wrangler d1 execute` against production). A prompt-level gate means a worker must still follow the rule; a bypass would require the worker ignoring a hard instruction in the prompt. The prompt-level approach follows the same pattern as the existing `led-2026-08-27-d1-prod-migrations-decided` enforcement (fleet-ops#907).

## Verification

```
$ bash tests/fleet-d1-prod-migration-process.test.sh
OK: scenario1: worker.md contains the D1 prod migration execution rule needles
OK: scenario2: dropping 'D1 prod migration execution rule...' is rejected
OK: scenario2: dropping 'Never single-agent apply.' is rejected
OK: scenario2: dropping 'Senior process gate:' is rejected
OK: scenario2: dropping 'INDEPENDENT senior agent blind-reviews...' is rejected
OK: scenario2: dropping 'blocked-on: senior-conference' is rejected
OK: scenario3: matrix row is enforced with mechanism+proof
OK: d1-prod-migration-process: worker needles, matrix enforced, proof locked

$ bash tests/fleet-d1-prod-migration-grant.test.sh
OK: scenario1: worker.md contains the D1 schema rule needles
OK: scenario2: dropping 'D1 schema rule...' is rejected
... (all 6 needles, all rejected when dropped)
OK: scenario3: matrix row is enforced with mechanism+proof
OK: d1-prod-migration-grant: worker needles, matrix enforced, proof locked

$ sgscan diff origin/main...HEAD
No new security findings.
```

Closes #908