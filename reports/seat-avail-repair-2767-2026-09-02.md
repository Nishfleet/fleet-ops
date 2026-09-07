# FleetSloSeatAvailSlowBurn escalated, not repaired — firing 47h (fleet-ops#2767)

Report date: 2026-09-02
Issue: fleet-ops#2767 — "FleetSloSeatAvailSlowBurn escalated, not repaired — firing 47h"
Host: netcup-rs2000

## The reported snapshot (issue body, filed 2026-09-02T03:30:11Z)

- `FleetSloSeatAvailSlowBurn` firing since `2026-08-31T04:49:33Z`.
- `fleet_chain_cycle_seconds` shows `terminal=escalated` at 28800s — the only alert
  class in the table that does not terminate green.
- Seat availability: 12 healthy / 5 walled / 1 dead of 19.
- Ask: "Repair the seat-availability burn (walled seats include 3 straitly 402s and
  1 quota_bench to 2026-09-19) or fix the SLO so an escalated terminal state gets a
  repair path instead of parking."

## Fork A — the seat-availability burn: worker-side repair done, live

The worker-repairable part of the burn is now repaired on the host. Two enrolled
providers — cursor and zenmux — had **no health ledger at all** (cap>0 in
seat-caps.json, never probed because nothing routes to them: cursor is
keystone/senior-review only, zenmux is bottom of the ladder). The SLO counts an
unproven enrolled provider as unhealthy (deliberate fail-safe, fleet-ops#1291), so
these two cost 2/13 = 15% of the denominator on zero evidence. Live 1-token probes
this session (writer: `pi --print --provider <p> --model <m> 'reply exactly with: PONG'`):

| provider | model | result | ledger (written by seat-health after_provider_response) |
|---|---|---|---|
| cursor | composer-2.5 | PONG | healthy, http 200, observed 18:15:46Z |
| cursor | cursor-grok-4.6-high | PONG | healthy, http 200, observed 18:16:19Z |
| zenmux | z-ai/glm-4.7-flash-free | PONG | healthy, http 200, observed 18:16:55Z |

Live SLO compliance trajectory (Prometheus, same box — `fleet_slo_compliance{slo="seat_availability"}`):

```
17:15Z  0.615385  (8/13)  closed-baseline (fleet-ops#2744 report)
18:10Z  0.538462  (7/13)  poolside overload_bench + openrouter empty-run spawn-bench holding
18:20Z  0.692308  (9/13)  +cursor +zenmux probes land in the export
18:26Z  0.769231  (10/13)  poolside wall passed -> auto-release (comeback-release organ)
18:30Z  0.846154  (11/13)  openrouter spawn-bench expired  -> mechanical ceiling
```

The auto-repair rail is alive and was observed working without a worker:
- `fleet-seat-comeback-release` (15-min timer) released `commandcode/poolside/laguna-s-2.1-free`
  at 17:45Z (`UNWALLED ... healthy observation written`), re-walled it on a real 503 at
  18:11Z, and the wall replay released it again at 18:21Z.
- The openrouter wrapper `spawn-bench` (empty-run marker, fleet-ops#2493) expired at 18:29Z
  and the seat re-entered the healthy count on the fresh 200 ledger.

Ceiling reached: **11/13 = 0.846154**. Every worker-repairable enrolled provider is now
healthy (bai, cline, commandcode, cursor, devin, hetzner, ollama, opencode, openrouter,
xai-oauth, zenmux).

## Remaining holds — operator/Nish-owned; mechanism-impossible for a worker

Probed live this session (same 1-token probe):

| provider/model | response | nature |
|---|---|---|
| straitly/deepseek/deepseek-v4-pro | HTTP 402 "Your credit balance is exhausted. Add credits at https://app.straitly.ai/console" | account billing wall (all 3 straitly seats share it) |
| minimax/MiniMax-M3 | HTTP 429 "Token Plan usage limit reached: Upgrade your Token Plan or purchase Credits" | usage-plan exhaustion (money) |
| cline/cline-pass/deepseek-v4-flash | HTTP 429 "You have reached your monthly Clinepass limit. The limit resets in 16d 13h" | monthly subscription cap, resets ~2026-09-19 |
| commandcode/deepseek/deepseek-v4-flash | (no ledger; credits wall documented fleet-ops#1890) | credit exhaustion (money) |

No worker mechanism exists to raise credits, a Token Plan, or a subscription cap
(fleet-ops#2429/#2441: the alert class is skip-listed as repair mechanism-impossible;
credentials/billing repair is operator-owned). The SLO cannot reach target 0.9 before
these clear and the 6h/30m smoothing windows flush >=0.9 samples; the remaining gap
above the ceiling is exactly the two billing walls (straitly + minimax).

## Fork B — the escalated terminal / repair-path: settled, no change warranted

- The `fleet_chain_cycle_seconds{alertname="FleetSloSeatAvailSlowBurn"} terminal=escalated
  28800s` row is the last REAL pre-skip dispatch record (2026-08-30/31). Since PR #2441
  the class is skip-listed in both the dispatcher (`libexec/alert-repair-dispatch`
  SKIP_SET) and the canary (`bin/fleet-completion-canary.py` SKIP_FIRING): no dispatch,
  no chain, no senior-conference summon. The repair path for this class **is** the
  class-park — a worker is never summoned into an unrepairable alert. 12 `SKIP ... reason=skip-list`
  lines in the alert-repair actions.log, latest 2026-09-02T11:19:59Z. This was proven
  with live queries in fleet-ops#2744 (report, merged).
- The SLO recording is deliberate fail-safe for unproven seats and correct since the
  #2377 rollup fix (healthy-enrolled count, not the old 1/13 pin); the rollup math is
  pinned by tests/fleet-metrics-export.test.sh.
- The per-seat census in the snapshot body ("12 healthy / 5 walled / 1 dead of 19") is
  the opus-heartbeat per-SEAT tally; the SLO uses the 13 enrolled PROVIDERS rollup
  (fleet-ops#1291). Both agree on direction; the SLO is the alert input.

No machinery change is warranted by this issue. No new organ, unit, timer, workflow,
or bin/ file is added.

## Verdict

1. **Fork A (repair the burn):** the worker-repairable part is done and self-maintaining.
   cursor + zenmux moved from fail-safe-unhealthy to proven healthy (ledger evidence);
   the auto-release rail handles expired walls and benches; compliance rose
   0.538 -> 0.846 on the live exporter this session.
2. **Fork B (SLO / escalated terminal):** already settled — class is skip-listed
   (fleet-ops#2441), the escalated row is the intended pre-skip fossil (fleet-ops#2864),
   the SLO math is correct and tested.
3. **Residual burn is operator-owned:** straitly credits 402, minimax Token Plan 429,
   cline monthly cap (16d13h), commandcode credits (fleet-ops#1890) — all money/
   subscription walls with live probe evidence above. Alert clears only after those
   recover + the smoothing windows flush.

mechanism-impossible: the residual seat_availability burn is billing/subscription-owned
(straitly credits, minimax plan, cline monthly cap, commandcode credits — fleet-ops#1890);
no worker mechanism can raise it, and the class is skip-listed (fleet-ops#2441) so no
repair worker is summoned into it. The worker-repairable portion is now healthy and
self-maintaining via fleet-seat-comeback-release + spawn-bench expiry, closing on the
observed 0.846 ceiling this session.

Sibling family stays tracked: fleet-ops#2798 (corpse triage), fleet-ops#2818
(wall-duration policy / come-back-never-released), fleet-ops#2440 (other WFR-input
alerts). This report is the worker-side repair evidence for #2767.

## Verification (commands run on netcup-rs2000, 2026-09-02 ~18:15-18:33Z)

```
$ pi --print --provider cursor --model composer-2.5 'reply exactly with: PONG'     # -> PONG rc=0
$ pi --print --provider cursor --model cursor-grok-4.6-high 'reply exactly with: PONG'  # -> PONG rc=0
$ pi --print --provider zenmux --model z-ai/glm-4.7-flash-free 'reply exactly with: PONG' # -> PONG rc=0
$ pi --print --provider straitly --model deepseek/deepseek-v4-pro 'reply exactly with: PONG'
    # -> 402: {"message":"Your credit balance is exhausted. ...","code":402}
$ pi --print --provider minimax --model MiniMax-M3 'reply exactly with: PONG'
    # -> 429 {"type":"error",...,"message":"Token Plan usage limit reached: ..."}
$ pi --print --provider cline --model cline-pass/deepseek-v4-flash 'reply exactly with: PONG'
    # -> 429: {"code":"INFERENCE_CAP_ERROR","message":"...monthly Clinepass limit. The limit resets in 16d 13h..."}

$ python3 - <<'PY'   # seat-health ledgers written by the probes
for f in cursor__composer-2.5 cursor__cursor-grok-4.6-high zenmux__z-ai_glm-4.7-flash-free:
    d=json.load(open('/home/nish/workspaces/agent-state/lanes/seats/'+f+'.json'))
    print(f, d['health_class'], d['http_status'], d['observed_at'])
PY
# -> cursor__composer-2.5 healthy 200 2026-09-02T18:15:46.533Z
#    cursor__cursor-grok-4.6-high healthy 200 2026-09-02T18:16:19.784Z
#    zenmux__z-ai_glm-4.7-flash-free healthy 200 2026-09-02T18:16:55.898Z

$ curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=fleet_slo_compliance{slo="seat_availability"}'
# -> 0.615385 (17:15Z baseline) ... 0.846154 (18:30Z, this session, mechanical ceiling)

$ journalctl --user -u fleet-seat-comeback-release.service --since '17:40' --no-pager | grep -E 'UNWALLED|released|probe '
# -> 17:45:12Z UNWALLED commandcode/poolside/laguna-s-2.1-free (healthy observation written)
#    sweep complete: probed=2 released=1 ... (cumulative released_total=108)

$ curl -s 'http://localhost:9090/api/v1/alerts' | grep FleetSloSeatAvailSlowBurn
# -> state=firing activeAt=2026-08-31T04:49:33Z (honest: 0.846 < 0.9 until billing walls clear)
```

This PR adds no unit, timer, workflow, or bin/ file.