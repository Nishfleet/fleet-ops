## What & why

FleetChainStalled fired from 2026-08-30T07:23:04Z with `fleet_chain_stalled` = 3, all at
`hop=run plane=alert-repair` (open run=3, verify=1, dispatch=0). Repairs were being opened
and never completing the run hop — the 3 stalled chains:

| alertname | last dispatch | unit verdict | why it can't clear in-turn |
|---|---|---|---|
| FleetMainRed | 07:11:19Z devin/glm-5-2 | exit-code (`devin` spawn ETIMEDOUT, 14 min) | fleet-ops main CI red (P14 tests) — PR-only/Nish-reserved |
| FleetSloMainGreenSlowBurn | 07:00:11Z laguna-s-2.1-free | exit-code (upstream 503) | 6h SLO smoothing window — cannot clear one turn |
| FleetSloSeatAvailSlowBurn | 07:00:11Z laguna-s-2.1-free | exit-code (upstream 503) | 6h SLO smoothing window — cannot clear one turn |

Root cause (runtime evidence, not vibes): the run hop has NO legal terminal for a unit that
ran and FAILED while the alert still fires. Each worker delivered the designed non-zero
EXIT CONTRACT verdict (genuine structural signal, escalate to senior-auditor — the packet
explicitly instructs exit non-zero), but `classify()` maps failed-unit + still-firing to
`hop=run` forever. The ladder redispatched once (fresh seat), the redispatch worker crashed
on the broken seat (devin ETIMEDOUT / laguna 503 — the "seat wall" in the issue evidence),
and the fleet-ops#2247 branch wrote STOP-REASON and then PARKED the chain at
`ladder=stop-reason`, exporting `fleet_chain_stalled=1` forever. The 15m rail then kept
dispatching FleetChainStalled repair workers into alerts unrepairable in-turn; each exited
non-zero (another failed unit) and nothing ever drained. Hand-dropping chain state (06:24,
07:14 repairs) was the only recovery — transient, because the code re-parked.

## Fix

When a stalled chain is found already laddered at `stop-reason` on the `dispatch`/`run`
hops, the STOP-REASON hand-off to the senior conference IS the terminal: close the chain
as `terminal=escalated` this tick (recorded in `chains.terminated.jsonl`), write a cooldown
marker so the same stale dispatch does not re-open it next tick, and exclude it from the
open/stalled gauges — mirroring the verify-hop detector-red deadline close (fleet-ops#1610).

Preserved: a still-loading unit keeps its second-chance redispatch before any escalation;
a fresh DISPATCH or the alert leaving 9090 still closes the chain through the normal
paths; the unit-escalation plane and dispatch plane are untouched. Escalation visibility is
kept for ≥1 tick (the STOP-REASON tick still exports the stall — the CanaryDrill/WFR shape),
then the drain is mechanical so a handled escalation cannot hold the rail open forever.

## Mechanism (prevention, per fleet-ops#366)

The code change is the mechanism: an escalated chain terminates instead of parking. Test
9g (tests/fleet-completion-canary.test.sh) is the regression drill pinning the exact live
shape — parked run chain + failed unit + still-firing alert must drain to
`terminal=escalated` with a cooldown marker, no re-dispatch, gauges at 0, cooldown holds
on the next tick. It FAILS on the pre-fix code (ledger never written) and passes after.

## Verification

Hermetic (repo gate): `bash tests/fleet-completion-canary.test.sh` → OK (17 cases, incl.
9g drain); `bash tests/escalation-coverage-canary.test.sh` → OK; `bash -n` clean;
`sgscan` (changes vs origin/HEAD) → No new security findings.

Live run-proof (real end-to-end run, this turn — the fix executed against the live
incident state, 2026-08-30T11:42Z):

```
before: fleet_chain_open{alert-repair,run}=3  fleet_chain_stalled{alert-repair,run}=3
[2026-08-30T11:42:06Z] chain FleetMainRed already laddered (stop-reason); metrics only
[2026-08-30T11:42:06Z] TERMINAL escalated alertname=FleetMainRed cycle_seconds=22870 (stop-reason hand-off; STOP-REASON owns the escalation)
[2026-08-30T11:42:06Z] TERMINAL escalated alertname=FleetSloMainGreenSlowBurn cycle_seconds=22473 ...
[2026-08-30T11:42:06Z] TERMINAL escalated alertname=FleetSloSeatAvailSlowBurn cycle_seconds=22473 ...
[2026-08-30T11:42:06Z] tick open_ar={'run': 0, 'verify': 1, 'dispatch': 0} stalled_ar={'run': 0, 'dispatch': 0, 'verify': 0}
after:  max(fleet_chain_stalled) = 0  (Prometheus query, value 0 at 1788090231.77)
after:  /api/v1/alerts — FleetChainStalled ABSENT (was firing since 07:23:04Z; remaining
        firing alerts are the genuine structural alerts: FleetMainRed, the two SLO burns,
        FleetQueueSelfMaintenanceRatioHigh — their chains terminated as escalated)
ledger: 3 new rows terminal="escalated" (FleetMainRed 22870s, FleetSloMainGreenSlowBurn
        22473s, FleetSloSeatAvailSlowBurn 22473s)
state:  the 3 parked open/*.json replaced by cooldown markers {"terminal":"escalated",
        "dead_until": ...}
```

run-proof: 9090-FleetChainStalled-resolved + max(fleet_chain_stalled)=0 ticks (values above)

## Out of scope (observed, not fixed here)

- fleet-ops main CI red (P14) — the FleetMainRed root; PR-only/Nish-reserved (already
  tracked by the FleetMainRed lane).
- SLO burn alerts' smoothing windows — structural, escalate-and-revisit by design.
- Broken-seat spawns (devin ETIMEDOUT, laguna 503) — seat selection re-picks per-seat via
  the ledger; the flush of stale seats is a separate seat-health matter.

Closes #2367