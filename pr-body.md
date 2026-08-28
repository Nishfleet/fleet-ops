feat(enforcement): D1 prod migration vacation grant enforced by CI drill

## What changed

- Added `tests/fleet-d1-prod-migration-grant.test.sh`, a CI drill that:
  - Asserts `prompts/worker.md` keeps the D1 schema rule (expand/contract, rollback-before-data, one phase per PR, banned DROP/NOT NULL without DEFAULT, real integration test, no stale API names).
  - Rejects a `worker.md` that drops any of those needles.
  - Asserts `config/rule-enforcement.json` has the 2026-08-27 decision as `enforced` with a mechanism and proof that name the drill, the worker prompt, and the issue.
- Updated `config/rule-enforcement.json`: the `led-2026-08-27-d1-prod-migrations-decided` row is now `enforced` with a mechanism/proof pointing at the drill.
- Nested the drill in `tests/rule-enforcement.test.sh` so CI runs it without a workflow edit.

## Why

The rule-coverage canary (fleet-ops#383) found the 2026-08-27 D1 prod migration vacation grant had no live enforcer. This drill makes the grant fail-loud in CI if the worker prompt or matrix row is weakened, and the rule-enforcement join now reports this source as covered.

## Verification

```
$ bash tests/fleet-d1-prod-migration-grant.test.sh
OK: scenario1: worker.md contains the D1 schema rule needles
OK: scenario2: dropping 'D1 schema rule (expand/contract) ...' is rejected
...
OK: scenario3: matrix row is enforced with mechanism+proof
OK: d1-prod-migration-grant: worker needles, matrix enforced, proof locked

$ python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json
OK: matrix valid (113 rules)

$ python3 lib/rule-enforcement.py join --rules /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md --ledger /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md --matrix config/rule-enforcement.json --now 2026-08-28T10:30:00Z | jq '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-27 | D1 prod migrations — DECIDED (plain-language re-ask, informed)")'
{
  "id": "led-2026-08-27-d1-prod-migrations-decided",
  "source": "decisions-ledger.md: 2026-08-27 | D1 prod migrations — DECIDED (plain-language re-ask, informed)",
  "status": "enforced",
  "fallback_id": "led-2026-08-27-d1-prod-migrations-decided-plain-language-re-ask-"
}
```

`tests/rule-enforcement.test.sh` exposes a pre-existing live vault join failure (8 uncovered 2026-08-28 standing/ledger rules already tracked in #1529 / #1537). That failure is unrelated to this PR.

Relates to #907
