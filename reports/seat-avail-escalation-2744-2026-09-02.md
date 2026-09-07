# FleetSloSeatAvailSlowBurn escalated + unit-escalation chain open — prove stale-vs-repair (fleet-ops#2744)

Report date: 2026-09-02
Issue: fleet-ops#2744 — "FleetSloSeatAvailSlowBurn escalated + unit-escalation chain hop open with 0 failed units"
Host: netcup-rs2000

## The reported snapshot (issue body, filed 2026-09-02T00:30:26Z)

- `FleetSloSeatAvailSlowBurn` firing since `2026-08-31T04:49:33Z`.
- Chain cycle `terminal=escalated value=28800` (no green).
- `chain_open{plane="unit-escalation",hop="trip"}=1.0` while `failed_units user=0 system=0`.
- Ask: "Either the escalation is stale and must close, or the seat-availability SLO needs a real repair; prove which with live queries."

## Live state (2026-09-02T17:1xZ, this worktree)

### 1. The escalated chain cycle (28800s, no green) is the intended terminal record, not a live defect

- Ledger `agent-state/fleet-completion-canary/chains.terminated.jsonl` holds exactly two
  `FleetSloSeatAvailSlowBurn` rows, both `terminal=escalated`, both from **pre-skip-list**
  dispatches on 2026-08-30/31:

  ```
  start 2026-08-30T05:27:33Z -> end 2026-08-30T11:42:06Z  terminal=escalated cycle=22473 unit=alert-repair-FleetSloSeatAvailSlowBurn-20260830T070011Z
  start 2026-08-30T17:57:47Z -> end 2026-08-31T01:22:00Z  terminal=escalated cycle=28800 unit=alert-repair-FleetSloSeatAvailSlowBurn-20260830T175747Z
  ```

- Since PR #2441 (fleet-ops#2429, merged) `FleetSloSeatAvailSlowBurn` is skip-listed in
  `libexec/alert-repair-dispatch` ("WFR-input slow-burn class, repair mechanism-impossible —
  seat compliance is operator/Nish-owned; no repair worker can raise it"), and in the canary's
  `SKIP_FIRING` set (bin/fleet-completion-canary.py, kept through #2776). No DISPATCH is ever
  expected, so a firing-without-dispatch chain must not ladder; the class can never produce a
  green terminal. **The 28800s escalated row is the fossil of the pre-skip era and stays the
  last per-alertname sample by design** (`load_ledger_cycles` keeps the last record per
  alertname in `fleet_chain_cycle_seconds`).

- Live heartbeat of the skip: `actions.log` shows a `reason=skip-list` line every AMX repeat
  (6h) and no DISPATCH since the skip landed — 12 SKIP lines, latest
  `[2026-09-02T11:19:59Z] SKIP alertname=FleetSloSeatAvailSlowBurn receiver=repair-dispatch reason=skip-list`.

- The alert is still firing (live `/api/v1/alerts`: `state=firing activeAt=2026-08-31T04:49:33.742872195Z`),
  which is honest signal (compliance below target), and it will clear only when seats recover
  and the 6h smoothing window flushes — not via any worker action (see §3).

### 2. The unit-escalation chain: was stale, is now CLOSED

- `chain_open{plane="unit-escalation",hop="trip"}=1` in `/var/lib/prometheus/node-exporter/fleet-chains.prom`
  was written by the canary tick at **17:07:41Z** with `ue_open=1` — at that instant the
  34th-in-class `fleet-heartbeat.service` trip (failed 2026-09-02T17:01:00Z) was still open.
- The senior-auditor closeout then landed on `agent-state/STOP-REASON.json`:
  `"reason": "auditor-resolved"` (terminal per `reason_is_terminal`), `closed_at_utc
  2026-09-02T17:40:00Z`, `units_reset: [fleet-heartbeat.service, pi-scout-repair@0509.service]`.
- Live `systemctl`: **0 failed user units, 0 failed system units**; `stop-escalation.service`
  (the pipeline that closes trips) `inactive`. The stop-escalation pipeline being idle plus
  every failed unit recovered is the stale-trip condition — and it is satisfied only because
  the closeout already advanced the STOP-REASON to a terminal reason.
- Canary `observe_unit_escalation()`: with `reason=auditor-resolved` it returns `(0, 0)` —
  the exported `ue_open` flips to 0 at the next tick (observed below in Verification). The
  `=1` in the issue snapshot was a mid-closeout tick lag, not a live open chain.

**Answer to the issue's either/or, prong A: the escalation was stale and it has closed.**
A worker cannot do more — closing that chain is the auditor's closeout, already done.

### 3. The seat-availability SLO: real burn, honest signal, operator-owned

- `fleet_slo_compliance{slo="seat_availability"}` = **0.615385** at the 17:15:28Z export
  (0.692308 at the 17:0xZ export — poolside's overload_bench re-anchored in between),
  target = **0.9**. `fleet_pi_seat_total` = 13 (providers with cap>0 in
  `tooling/fleet-ops/config/seat-caps.json`).
- The SLO numerator is the healthy-enrolled rollup (`_healthy_enrolled_seat_count`,
  fixed from the old 1/13 pin in PR #2377). Reproduced live from the per-seat ledgers:
  **8/13 healthy** — matches the exported 0.615385 exactly. No metrics-calculation bug; the
  burn is real seat supply.
- Unhealthy enrolled seats at query time:

  | provider | model | class | detail |
  |---|---|---|---|
  | commandcode | minimax/minimax-m3-free | corpse | seat_dead=true |
  | commandcode | poolside/laguna-s-2.1-free | overload_bench | 503, bench until 17:25:15Z |
  | cline | cline-pass/deepseek-v4-flash | quota_bench | bench until 2026-09-19 |
  | cline | cline-pass/minimax-m3 | quota_exhausted | usable_at 2026-09-19 |
  | minimax | MiniMax-M3 | quota_exhausted | held (not release-at-expiry) |
  | opencode | hy3-free | corpse | seat_dead=true |
  | opencode | mimo-v2.5-free, nemotron-3-ultra-free | rate_limited | wall clocks |
  | straitly | deepseek-v4-pro / gpt-5.6-sol / qwen3.8-max | quota_exhausted | HTTP 402, account-level |
  | cursor / zenmux | (no ledger) | unproven | enrolled cap>0, fail-safe unhealthy |

- Repair is **mechanism-impossible for workers** (fleet-ops#2429/#2441): quota exhaustion and
  credential corpses are money/credentials(Nish)-owned; no alert-repair worker can raise
  compliance. The durable repair track is live: PR #2835 (devin glm-5-2 cap 0->3 + grok restore,
  currently open) and the consolidating family issues (#2798 "Two corpse seats + 6 walled",
  #2818 "comeback never released", #2767 "not repaired — firing 47h").

**Answer to the issue's either/or, prong B: the SLO burn is real but operator/Nish-owned and
already skip-listed; the only worker-side fix (the #2377 rollup bug) was shipped and verified
clean — the current 0.615 is honest accounting.**

## Verdict

1. **The unit-escalation chain was stale and has closed** (auditor-resolved terminal closeout;
   0 failed units; metrics flip to `ue_open=0` the next tick — Verification below).
2. **The seat-availability SLO needs no worker repair** — the burn is real, the alert is
   skip-listed (mechanism-impossible, fleet-ops#2429/#2441), and repair is tracked by the
   operator-owned seat family + PR #2835.

Both branches of the issue's either/or are answered with live queries; no machinery change is
warranted by this issue. The escalated-no-green cycle row is a deliberate fossil of the
pre-skip era (and the duplicative per-cycle alert-quality filings it feeds are tracked as
fleet-ops#2440).

## Verification (commands run on netcup-rs2000, 2026-09-02 ~17:1x-17:2xZ)

Observed flip, same day:
- 17:07:41Z canary tick wrote `fleet-chains.prom` with `fleet_chain_open{plane="unit-escalation",hop="trip"} 1`
  (34th-in-class fleet-heartbeat trip still open, STOP-REASON non-terminal).
- 17:11:42Z STOP-REASON advanced to `reason=auditor-resolved` by the senior-auditor closeout.
- 17:22:39Z canary tick logged `ue_open=0` and rewrote `fleet-chains.prom` with
  `fleet_chain_open{plane="unit-escalation",hop="trip"} 0`.
- 17:23:3xZ Prometheus scrape converged: `fleet_chain_open{plane="unit-escalation",hop="trip"}` => **0**,
  all `fleet_chain_stalled` => 0.

```
$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=fleet_chain_open{plane="unit-escalation"}'   # after the closeout tick
...fleet_chain_open{...,hop="trip"} => 0

$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=fleet_slo_compliance{slo="seat_availability"}'
... => 0.615385                                     # healthy-enrolled rollup, target 0.9

$ systemctl --user list-units --state=failed --no-legend | wc -l   # 0 user failed
$ systemctl --user is-active stop-escalation.service               # inactive (closeout pipeline idle)
$ python3 -c "import json; d=json.load(open('$AGENT_STATE/STOP-REASON.json')); print(d['reason'])"   # auditor-resolved (terminal)
```

Full query transcripts: §1-§3 above. This PR adds no unit, timer, workflow, or bin/ file.