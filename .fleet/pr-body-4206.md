## Summary

Land durable pacing + measured spend for Cursor's $400 'API Usage' on-demand pool (fleet-ops#4206) before the ~2026-09-22 billing-cycle reset, on cursor/cursor-grok-4.6-high senior/keystone work — never worker-tier.

- **config/seat-caps.json**: cursor provider cap 1->2, both model caps 1->2, dated reason (2026-09-07, fleet-ops#4206) citing the $400 pool, the reset window, and the ETIMEDOUT fallback. Senior-order and provider comments updated to match.
- **Measured spend reader** (edited inside the existing `bin/fleet-prepaid-util-canary`, no new unit): calls `POST api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` (Bearer accessToken from `~/.config/cursor/auth.json`, never logged) and emits `fleet_prepaid_spend_usd{provider="cursor"}` + pool/cycle/included into `/var/lib/prometheus/node-exporter/prepaid-spend.prom`. Fail-loud: a missing/unreachable reader omits the metric (the `absent()` rule fires), never emits a fake zero.
- **Prometheus rules** in `config/fleet_rules.yml` (group `fleet_cursor_prepaid_pacing`, 3 recording + 2 alert rules): `FleetCursorPrepaidBurnPacingLow` (trailing-24h burn < pool/remaining-days for 2h -> repair packet adds `difficulty: senior-review` to waiting heavy issues so pick_seat routes them to the cursor senior ladder) and `FleetCursorPrepaidSpendReaderAbsent` (fail-loud on a dead reader for 30m).
- **ETIMEDOUT watch** in the same canary: a cli_timeout (spawnSync ETIMEDOUT) landing in the cursor seat ledger while cap >= 2 auto-files a 'lower cursor cap to 1' finding — the safety revert now that cap is 2. The seat-health extension already benches the faulted seat; this watch stops the 2nd concurrent slot inheriting the same blast radius.
- **config/rule-enforcement.json**: corrected the stale 'no programmatic API' claim — Cursor DOES expose `DashboardService.GetCurrentPeriodUsage`; the `included_exhausted` flip is now a meter check, not a Nish dashboard action. 2 matrix rows updated, both stay `enforced`.

## Why

Nish 2026-09-07: the Cursor Ultra $400 'API Usage' on-demand pool (spendLimitUsage) is untouched and expires at the billing-cycle reset. The rule is to spend it on the seat that stretches the max AND exceeds the quality benchmark — cursor/cursor-grok-4.6-high (senior/keystone), never worker-tier. The live seat-caps.json and the judge packet were changed today; this PR lands the same state durably in the repo, adds the measured spend reader the pacing needs, and adds the safety revert for the cap raise.

## Scope

- `config/seat-caps.json` — cursor cap 1->2, both model caps 1->2, dated reason, 3 comment updates
- `bin/fleet-prepaid-util-canary` — `cursor_measured_spend()` + `emit_cursor_prepaid_spend()` + `cursor_recent_cli_timeout()` + `cursor_cap_value()` + main-flow hooks
- `config/fleet_rules.yml` — new group `fleet_cursor_prepaid_pacing` (3 recording + 2 alert rules)
- `config/rule-enforcement.json` — 2 matrix rows updated (stale 'no programmatic API' claim corrected)
- `tests/fleet-prepaid-util-canary.test.sh` — 5 new scenarios (15-19)
- `tests/fleet-token-economy.test.sh` — comment update (cursor cap 1->2)

No new scheduler, daemon, systemd unit, or workflow. No credentials printed or committed.

## Verification

```
bash tests/fleet-prepaid-util-canary.test.sh      # 19/19 OK (ladder, expiry-waste, bench skip, dedup, cap, prod clean, spend reader fixture + missing, ETIMEDOUT cap 2 / cap 1 / stale)
bash tests/fleet-token-economy.test.sh            # OK
bash tests/seat-caps-citation.test.sh             # OK
bash tests/seat-lib-aimd.test.sh                  # OK
bash tests/seat-lib.test.sh                       # OK
bash tests/fleet-ops-deploy.test.sh               # OK
bash tests/fleet-litellm-organ.test.sh            # OK
bash tests/ci-standards-audit.test.sh             # OK
python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json   # OK: 128 rules
promtool check rules config/fleet_rules.yml       # SUCCESS: 99 rules found
jq -e '.providers.cursor.cap' config/seat-caps.json  # 2
```

Live API smoke (2026-09-07 13:01 UTC, token never printed): ran `bin/fleet-prepaid-util-canary` with the real `~/.config/cursor/auth.json` and real endpoint, temp output paths, filing disabled. The reader emitted:

```
fleet_prepaid_spend_usd{provider="cursor"} 0.000000
fleet_prepaid_pool_usd{provider="cursor"} 400.000000
fleet_prepaid_cycle_end_timestamp{provider="cursor"} 1790049771   # 2026-09-22T04:02:51Z
fleet_prepaid_included_exhausted{provider="cursor"} 1             # pool is OPEN
```

Pool = $400.00 confirmed live; cycle reset 2026-09-22T04:02:51Z (~14.6d out); spend $0 (untouched, matching observed_at 2026-09-07). The reader's log line: `cursor spend reader: spend_usd=0.000000 pool_usd=400.000000 cycle_end_s=1790049771 included_exhausted=1`.

run-proof: live `fleet-heartbeat.timer` active (fleet-heartbeat.service runs bin/fleet-heartbeat-tier1 -> this canary every tick; last run 18:17:15 IST 2026-09-07); canary exit 0 on the live smoke; 19/19 canary test scenarios pass; promtool SUCCESS on the rules file; no new unit/timer/workflow in this PR.

net-positive-because: measured spend + pacing + safety-revert for the $400 pool is new control-plane capability the issue explicitly requires (4 acceptance items); it ships inside the existing canary organ with 5 new test scenarios rather than a new unit, keeping the organ count flat.

loose-ends: the issue's proof item — 24h of `fleet_prepaid_spend_usd{provider=cursor}` rising at >= $28/day and the judge's Telegram line quoting it — is a post-deploy observation and cannot complete inside this PR. The reader is proven against the live API above; the 24h proof starts when this lands and the canary tick writes the textfile. The judge packet (`agent-state/fleet-landing-watch/fable-check.md`) was changed live today (pacing rule, target >= $28/day) and is not a repo file.

organ-heartbeat: bin/fleet-prepaid-util-canary (edited, existing organ) not-an-organ: existing canary edited in place, no new unit/timer/workflow; config/fleet_rules.yml + config/seat-caps.json + config/rule-enforcement.json + tests/* not-an-organ: config/tests only.

Closes #4206
