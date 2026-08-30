## What

`FleetSloSeatAvailSlowBurn` is a **WFR-input slow-burn SLO alert**: its own annotation says it "feeds the weekly fleet review" (fleet-ops#1291). Seat compliance is operator/Nish-owned (credentials, quotas, seat health) — **no repair worker can raise it**, so the alert-repair chain can never terminate green while compliance < 0.9. This is the explicit `mechanism-impossible` declaration the issue asked for.

The metric bug (compliance pinned at 1/13 regardless of real health) was already fixed in PR #2377; the remaining signal (0.846 < 0.9 at last check) is honest and clears only when seats recover + the 6h smoothing window flushes. There is no in-turn repair.

Before this PR, Alertmanager's 6h repeat spawned a repair worker into this unrepairable alert every cycle — live 2026-08-30 dispatches at 07:00Z, 11:57Z and 17:57Z, each running a seat, failing with `GENUINE_STRUCTURAL_SIGNAL`, and re-escalating the senior conference (STOP-REASON) via the completion-canary ladder. That is the "chain ran and failed to clear it" loop, and it feeds the self-maintenance ratio issue (ask #1 below).

## The fix (deletion-first, mirrors the WasteRatioRising precedent)

- `libexec/alert-repair-dispatch`: `FleetSloSeatAvailSlowBurn` added to `SKIP_SET` (like `WasteRatioRising`) — no repair worker is ever spawned; the dispatcher logs `SKIP ... reason=skip-list` and exits 0 before the claim mutex.
- `bin/fleet-completion-canary.py`: same alert added to `SKIP_FIRING` — a firing-without-dispatch never opens a chain, so it cannot ladder → redispatch → STOP-REASON → escalate the senior conference for a measurement.
- The alert itself is untouched in `config/fleet_rules.yml` — it stays firing honestly in Prometheus as a WFR input until compliance recovers (minimax/straitly quota walls reset 2026-08-31, then 6h flush). When it leaves 9090, the existing detector-green path closes the (never-opened) chain. Silencing is not part of this change.

## Ask #1 (queue self-maintenance ratio) is NOT duplicated here

fleet-ops#2110 is the same class ("Queue self-maintenance ratio stuck at 86%", `agent-blocked` on `nish-decision` — the durable un-enroll/gating decision is Nish's). This PR's in-scope cut is the seat-avail repair churn class: 3-4 worker dispatches per day removed from the queue entirely. The remaining decision stays tracked by #2110.

## mechanism-impossible declaration

`mechanism-impossible: no repair worker can raise seat_availability compliance (operator/Nish-owned supply: credentials, quotas, seat health); terminal=green is unreachable while compliance < 0.9 and is by-design achieved only when the SLO recovers and the alert leaves 9090 (detector-green).`

## Prevention mechanism (fleet-ops#366)

- Dispatcher regression drill in `tests/alert-repair-claim-mutex.test.sh`: firing `FleetSloSeatAvailSlowBurn` must log `SKIP reason=skip-list`, exit 0, add no DISPATCH line and never invoke the worker (mock `pi-systemd-run` count unchanged).
- Canary regression test in `tests/fleet-completion-canary.test.sh` (5c): a firing `FleetSloSeatAvailSlowBurn` far past every hop clock must open no chain, AMX-redispatch nothing, and write no STOP-REASON.

## Verification

- `bash tests/alert-repair-claim-mutex.test.sh` → all OK incl. `skip-list (FleetSloSeatAvailSlowBurn): SKIP reason=skip-list, no DISPATCH, no spawn`.
- `bash tests/fleet-completion-canary.test.sh` → all OK incl. `FleetSloSeatAvailSlowBurn firing is ignored (WFR-input slow-burn class)`.
- Full CI verify-command (59 hermetic test files from .github/workflows/ci.yml, pyyaml already importable) → rc=0.
- LIVE dispatcher run with the changed `libexec/alert-repair-dispatch` (scratch packet dir): `[2026-08-30T21:13:21Z] SKIP alertname=FleetSloSeatAvailSlowBurn receiver=live-skip-verify reason=skip-list`, rc=0, packet dir contains only actions.log (no packet, no spawn).
- LIVE canary tick with the changed `bin/fleet-completion-canary.py` (the same binary the 5-min timer runs): rc=0, tick log `firing=['FleetQueueSelfMaintenanceRatioHigh']` — FleetSloSeatAvailSlowBurn is absent from the firing set and from `fleet_chain_open/stalled` (all 0).

run-proof: live dispatcher SKIP line `[2026-08-30T21:13:21Z] SKIP alertname=FleetSloSeatAvailSlowBurn receiver=live-skip-verify reason=skip-list` (rc=0, no spawn); live canary tick 2026-08-30T21:13:57Z rc=0 with `firing=['FleetQueueSelfMaintenanceRatioHigh']` and `open_ar={dispatch: 0, run: 0, verify: 0}`, no STOP-REASON.

Closes #2429

Follow-up filed: #2440 (sibling WFR-input alerts — FleetSloWasteRatioOverTarget, FleetSloGhRateLimitHeadroomLow, WasteRatioRising — can still spawn repair workers / open canary chains when they fire; FleetSloMainGreenSlowBurn stays dispatchable, it is repairable in-turn).