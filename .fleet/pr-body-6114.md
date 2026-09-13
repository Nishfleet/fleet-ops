fix(#4263 fallout): restore the Cursor $400 rows and put senior audits back on cursor-grok-4.6-high

Closes #6114

## Why

#6037 marked both 2026-08-27 Cursor $400 ledger rows `advisory-RETIRED` ("no worker routes to Cursor"). #5993 had retired the prepaid-spend reader to a 9-line no-op, which froze `prepaid-spend.prom`, so the pacing rules read 0/0 while the real $235.70 of $400 sat in the #4566 field names; the senior role meanwhile rode the #5993 LiteLLM proxy (GLM/DeepSeek) instead of the $400 bucket. Nish: Grok 4.6 and the Kimi K3 judge are part of the escalation matrix through the Cursor API, and Cursor spend is live. This restores the rows, the reader, and the ladder.

## Scope

- `config/rule-enforcement.json`: both rows (`led-2026-08-27-cursor-400-correction-nish`, `led-2026-08-27-cursor-400-sequencing-model-nish`) back to `enforced`, naming what enforces the cap today: the `fleet_cursor_prepaid_pacing` group in `config/fleet_rules.yml`, `config/seat-caps.json` `providers.cursor` + `cursor_overage`, and the direct callers (`bin/fleet-gap-closure-conference`, the `bin/pi-audit-run` senior ladder, `config/role-quality-gates.json` Kimi judge). The part of the #1167 sequencing with no live consumer since #5993 (the `opens_after_included_exhausted` pick gating) is said so, in the row. `tests/rule-enforcement.test.sh` pins restored to match.
- `bin/pi-audit-run`: the senior role walks its own ladder again. The head is `.cursor_overage.overage_model` read from `config/seat-caps.json` (cursor/cursor-grok-4.6-high), then xai-oauth/grok-4.6, then the openrouter rung; the #5993 LiteLLM `senior` group (GLM/DeepSeek) is the ladder-exhausted fallback only. Other roles stay on the proxy.
- `bin/fleet-prepaid-util-canary`: the reader is restored, in the same heartbeat-tier1 block-38 slot. When the #4206 SpendLimitUsage pool reads 0 (Nish keeps the on-demand overage limit at 0), the Included-API-bucket figures (`planUsage.apiPercentUsed` x `planUsage.limit`) export under the #4206 metric names, so `fleet_cursor_prepaid_remaining_usd` and `FleetCursorPrepaidBurnPacingLow` pace the real dollars; a non-zero SpendLimitUsage limit still wins. History appends only strictly-newer samples (the frozen-state stale-sample re-append the issue caught cannot recur), and the #4621 `usd_today` overlay is the vendor 24h delta, `UNAVAILABLE` while warming, never a fabricated 0.
- `lib/litellm-seat.sh`: `model_cap` misread INTEGER model caps (`"cursor-grok-4.6-high": 2` -> `2 | .cap` -> 0), so every `cap > 0` gate (the senior ladder, the gap-closure conference, comeback-release) silently skipped the int-capped rungs while the stubbed tests (`model_cap` -> 1) stayed green. One read fix: both shapes, unlisted models still 0. Regression-pinned in `tests/fleet-gap-closure-loop.test.sh` (fixture: int 2, object 4, unlisted 0; plus the live-config pin `model_cap(cursor, cursor-grok-4.6-high) == 2`).
- Out of scope: the #1167 included-models-then-overage pick machinery (no live consumer since #5993; documented in the sequencing row, as the issue directs) and the #6264 comeback-release test red (pre-existing, not in the P14 gate).

## Blast Radius

Nine modified files, no new files, no new unit, timer, or workflow, no gate-owned paths, no `.github/**`. Consumers: the senior ladder (`pi-audit@.service`, `pi-escalation-audit@.service`), the gap-closure conference, the Kimi judge, the Prometheus pacing rules. The `model_cap` read change also re-exposes the int-capped seats (cursor, xai, bai, minimax, cline, commandcode, opencode) to their cap>0 gates; those gates now see the values the config always declared. Rollback: revert the commit.

## Verification

- `tests/rule-enforcement.test.sh` exit 0 (both #6114 pins: rows `enforced`, today's mechanisms named).
- `tests/pi-audit-run.test.sh` exit 0 (scenario1c: un-walled senior audits resolve the ladder head; scenario1d: the head follows `.cursor_overage.overage_model`).
- `tests/fleet-prepaid-util-canary.test.sh` exit 0 (scenario2, the #6114 pin: `fleet_prepaid_spend_usd{provider="cursor"} 235.704000` and `fleet_prepaid_pool_usd 400.000000` from a live-shaped fixture with a 0/0 SpendLimitUsage; scenario2b: a frozen state never re-appends its stale sample).
- `tests/fleet-gap-closure-loop.test.sh` exit 0 (new #6114 `model_cap` pins). Also ran: `agent-cron-fable-check-litellm-routing`, `pi-seat-source-litellm`, `seat-lib-degraded`, `seat-lib-org-reserve` (all green); `fleet-seat-comeback-release` (known-red on a pristine main, #6264, identical failure).
- LIVE, 2026-09-13T15:28-15:30Z, worktree binaries against the real seats: `bin/pi-audit-run fleet-ops--6114--senior` logged `senior -> senior ladder (cursor  cursor-grok-4.6-high)` and wrote its verdict vote at 15:30:12Z. `bin/fleet-prepaid-util-canary` refreshed `/var/lib/prometheus/node-exporter/prepaid-spend.prom` to `fleet_prepaid_spend_usd{provider="cursor"} 268.176000` / `fleet_prepaid_pool_usd 400.000000` at 15:30:46Z; the $3.6 move from the 13:49Z sample ($264.536) is the audit's own spend.

run-proof: no new unit, timer, or workflow in this diff (name-status: 9M, 0A) — the reader runs inside the existing fleet-heartbeat-tier1 block-38 slot and the audits inside the existing `pi-audit@.service`; the two LIVE runs above (a real senior verdict on the prepaid seat, a real metric refresh) are the end-to-end evidence.
net-positive-because: machinery is the restored #4206 reader body, the senior-ladder head, and the one-line `model_cap` read; the remainder is the regression tests the issue demands (non-zero-bucket pin, stale-history pin, cap-shape pins) and the enforcement-matrix mechanism text. No new files, no new organ, no gate-owned paths.
organ-heartbeat: bin/fleet-prepaid-util-canary, bin/pi-audit-run not-an-organ: both pre-exist, neither is in config/fleet-organs.json, and no timer, unit, or workflow changed.
loose-ends: the `opens_after_included_exhausted` pick-sequencing intentionally has no live mechanism (documented in the sequencing row, per the issue); the #6264 comeback-release red is pre-existing on main.
