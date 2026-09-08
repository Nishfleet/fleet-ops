# fleet-ops#4453 — land Pareto Inference (Pareto Pass) prepaid worker seat

Scope: config-3-files + one spend-meter extension on the existing prepaid-usage
counter. Docs: https://docs.paretoinference.com/ base `https://api.paretoinference.com/v1`,
OpenAI chat-completions, `Authorization: Bearer`. Rate card verified live
2026-09-08: deepseek-v4-flash $0.081/$0.162/$0.016; glm-5.3-flash $0.075/$0.25/$0.015;
glm-5.3 $2.80/$8.80/$0.52. Live probe: `usage.cost` reports 0.0 (pass bills off the
rate card), so the spend meter MUST be token-derived, not usage.cost.

## Phases
- [x] phase 1: config/pi-models.json — `paretoinference` provider block
- [x] phase 2: config/seat-caps.json — cap 4, class prepaid-quota, daily_budget_usd 20,
      glm-5.3 cap 0, per-model daily_spend_cap_usd 19.50, prepaid_providers_in_order FIRST
- [x] phase 3: config/entitled-seats.json — paretoinference seat with docs cited
- [x] phase 4: seat-lib spend meter — extend prepaid-usage counter to write `usd_today`
      (token-derived from the provider cost map) + provider daily-budget gate benches
      seats at the stop, never charges the work item
- [x] phase 5: test proving usd_today is written and the daily-budget bench fires
- [ ] phase 6: run seat-relevant repo tests + sgscan/crgate + one real pi-issue run
- [ ] phase 7: PR body (Verification/run-proof/research/help-first) + arm auto-merge

## Design decisions
1. **Budget stop = existing `daily_spend_cap_usd` ledger-bench shape** (fleet-ops#3724),
   but token-derived: ParetoInference reports `usage.cost`=0 (the $3/wk pass credits
   bill off the rate card, not per-call cost), so `_seat_daily_spend_usd` (usage.cost)
   reads 0 forever. The new provider-level meter sums today's session tokens x the
   provider's OWN cost map from pi-models.json (generic formula:
   `input*in/1e6 + output*out/1e6 + cacheRead*cache/1e6`). For paretoinference that is
   exactly the issue's `prompt_tokens*0.081 + cached*0.016 + completion*0.162`.
2. **`usd_today` lives in the existing prepaid-usage counter file** per the acceptance
   (`~/.local/state/pi-packet/prepaid-usage/<provider>.json` gains `usd_today`).
3. **Stop at $19.50** (margin under the $20/day budget so the first 200-after-reset
   re-probe and cleanup never blow the cap); `daily_budget_usd` 20 is the declared
   budget, `daily_stop_usd` 19.50 is the bench threshold. Both live on the provider row.
4. **No new units/timers; no new files** (spend meter reuses the existing counter file
   + the existing ledger-bench writer). `required:` satisfied.
5. Ordering: paretoinference first in `prepaid_providers_in_order` (expiry-first — a
   daily-allowance seat beats non-expiring balances; rule 6).
