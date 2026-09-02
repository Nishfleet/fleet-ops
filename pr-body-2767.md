Worker-side repair of the seat-availability burn, proven live; residual burn is operator-owned and declared mechanism-impossible.

## What this PR does

Closes fleet-ops#2767 ("FleetSloSeatAvailSlowBurn escalated, not repaired — firing 47h"). The issue's either/or: repair the seat-availability burn, or fix the SLO so an escalated terminal state gets a repair path instead of parking.

**Fork A — the burn is repaired for every worker-repairable seat (live, this session):**
- cursor/composer-2.5, cursor/cursor-grok-4.6-high, zenmux/z-ai/glm-4.7-flash-free were enrolled (cap>0) but had **no health ledger ever** — counted unhealthy on zero evidence. Live 1-token probes returned PONG/200 and the seat-health extension wrote healthy ledgers (+2 healthy enrolled providers).
- SLO compliance trajectory on the live exporter (Prometheus): 0.615 (17:15Z baseline) -> 0.538 (18:10Z, transient holds) -> 0.692 (18:20Z, probes land) -> 0.769 (18:26Z, poolside auto-release) -> **0.846154 (18:30Z, mechanical ceiling 11/13)**.
- Auto-repair rail verified: fleet-seat-comeback-release released commandcode/poolside at 17:45Z and again at wall expiry 18:21Z; the openrouter empty-run spawn-bench expired at 18:29Z (fleet-ops#2493).

**Fork B — the escalated terminal / repair-path: already settled, no change warranted:**
- The 28800s terminal=escalated cycle row is the last real pre-skip dispatch fossil; the class is skip-listed (fleet-ops#2429/#2441) so no repair worker is ever summoned into it — the class-park IS the repair path, proven with live queries in #2744 (merged).
- The SLO rollup math is correct and tested (PR #2377 fix, tests/fleet-metrics-export.test.sh).

**Remaining holds — probed live, all billing/subscription-owned, worker repair mechanism-impossible:**
- straitly → HTTP 402 "credit balance is exhausted" (account credits; 3 seats share one wall)
- minimax → HTTP 429 "Token Plan usage limit reached"
- cline → HTTP 429 "monthly Clinepass limit... resets in 16d 13h" (~2026-09-19)
- commandcode credits wall (fleet-ops#1890)
These clear only with operator action (top-up/plan) + the 6h/30m smoothing flush; the alert honestly stays firing at 0.846 < 0.9 until then. Sibling family tracked: #2798, #2818, #2440.

mechanism-impossible: the residual burn is billing/subscription-owned (straitly credits, minimax plan, cline monthly cap, commandcode credits #1890); no worker mechanism can raise it, and the class is skip-listed (fleet-ops#2441) so no repair worker is summoned into it. The worker-repairable portion is now healthy and self-maintaining (comeback-release organ + spawn-bench expiry).

Ships the forensic report under reports/seat-avail-repair-2767-2026-09-02.md. No unit, timer, workflow, or bin/ file added.

## Verification

```
# probes (all rc=0, PONG) — ledgers written healthy by seat-health extension
pi --print --provider cursor --model composer-2.5 'reply exactly with: PONG'
pi --print --provider cursor --model cursor-grok-4.6-high 'reply exactly with: PONG'
pi --print --provider zenmux --model z-ai/glm-4.7-flash-free 'reply exactly with: PONG'

# held walls confirmed (operator-owned)
straitly  -> 402 "credit balance is exhausted"
minimax   -> 429 "Token Plan usage limit reached"
cline     -> 429 "monthly Clinepass limit... resets in 16d 13h"

# SLO compliance (Prometheus, live)
fleet_slo_compliance{slo="seat_availability"}: 0.615385(17:15Z) -> 0.846154(18:30Z)  // mechanical ceiling 11/13

# auto-release rail (journalctl --user -u fleet-seat-comeback-release)
17:45:12Z UNWALLED commandcode/poolside/laguna-s-2.1-free (healthy observation written)
# alert honestly firing until billing walls clear
FleetSloSeatAvailSlowBurn state=firing activeAt=2026-08-31T04:49:33Z
```

run-proof: prometheus query transcripts + probe stdout + journalctl lines above; also `bash tests/fleet-metrics-export.test.sh` rc=0, `bash tests/slo-budget.test.sh` rc=0, `bash tests/fleet-seat-comeback-release.test.sh` rc=0 on this worktree.

Closes #2767