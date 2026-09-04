## What changed

`fleet-completion-canary` counted a successfully-redispatched dispatch hop as
still open+stalled on the same tick, firing FleetChainStalled for a drain that
already happened.

## Root cause

When a dispatch-hop stall was redispatched and the dispatcher wrote a DISPATCH
line (unit spawned, `dispatched=True`), `take_ladder` returned `"redispatch"`.
`main()` set `ladder="redispatch"` but never decremented `open_hops["dispatch"]`
or `stalled_hops["dispatch"]` — the counts were incremented BEFORE
`take_ladder` ran (from the `classify()` decision) and left as-is. The
stop-reason terminal paths (verify deadline, escalated) already decrement both
counters; the redispatch path did not.

So the metric exported `stalled{dispatch}=1` on the tick the dispatch hop
actually drained. The next tick would classify the chain at `hop=run` and
count it there, but the 1-tick overcount was enough to fire FleetChainStalled.

Live: DeployBlockedStuck redispatch 13:22:13Z (seat devin/glm-5-2, rc=0,
DISPATCH line written), `chain_stalled_total` went 0->1 at `hop=dispatch`
while the unit was already running. FleetChainStalled went pending 13:23:04Z.

## Fix

When `take_ladder` returns `"redispatch"` at `hop=dispatch`, decrement
`open_hops["dispatch"]` and `stalled_hops["dispatch"]` — the dispatch hop
drained (DISPATCH line written, chain advanced to run). The next tick
classifies the chain at `hop=run` and counts it there. Mirrors the existing
decrement in the stop-reason terminal paths.

## Verification

Command: `bash tests/fleet-completion-canary.test.sh`; observed: all 38
sub-tests OK including new `9e-drain` regression (exit 0).
Command: `bash tests/fleet-escalation-completion.test.sh`; observed: all 11
sub-tests OK (exit 0).
Command: `python3 bin/fleet-completion-canary.py` against live agent-state;
observed: DeployBlockedStuck chain closed terminal=green
cycle_seconds=107, `fleet_chain_stalled{plane="alert-repair",hop="dispatch"} 0`,
`fleet_chain_open{plane="alert-repair",hop="dispatch"} 0`; FleetChainStalled
cleared from 9090.

run-proof: journal tick at 2026-09-04T13:22:45Z exported
`stalled_ar={'dispatch': 1}` (bug); fixed canary run at 13:41:38Z exported
`stalled_ar={'dispatch': 0}` with DeployBlockedStuck closed green.

loose-ends-canary: pr:nishfleet/fleet-ops#3226 stale-worker-pr

Closes #3226
