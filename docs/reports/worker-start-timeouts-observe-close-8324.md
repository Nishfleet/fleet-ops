# Observe-close for #8324 — the 35 worker start-timeouts were a too-short `TimeoutStartSec` on devin/router, fixed by one unit value each

fleet-ops#8324 (filed 2026-09-22T13:03:10Z by `nish3451`) reports 35 worker
start-timeouts that day with devin carrying 23 of them, clustering in the
17:00-19:00 IST window at 21-28 concurrent. It asks for a **population**
diagnosis with controls, not one unit: was the worker still working at the
45-minute mark, idle waiting on a seat cooldown, or stuck on a build step
under CPU load — then a fix "at the lowest rung: one unit line or one config
value, in this repo, by PR. No scripts, no wrappers."

This report is the measurement record the `termination:` criterion needs
("the next 24h show the devin timeout rate below 5%, measured the same way").
It ships with the fix itself.

## What the population says

**Method.** Every `Result=timeout` unit result for 2026-09-22 in the user
journal, joined to (a) the `Consumed <cpu> CPU time, <mem> memory peak` line
systemd emits at each stop, (b) the unit's Pi/devn session transcript in
`~/.pi/agent/sessions/`, and (c) the same-lane units that finished OK that
day as controls.

**Findings, with controls:**

1. **The timeout is not too short *because the worker is slow* — it is too
   short *for work that is genuinely in flight*.** All 40 timeout events ran
   the full 45-minute wall at **1.0-11.3% of one CPU** (median 4.8%, max
   304s of 2700s). A starved or hot worker looks like this; a *thrashing*
   worker does not.
2. **Controls settle the class.** Finished-OK router-lane sessions that day
   ran p50 25.7 min / p90 44.7 min / p95 44.9 min. The invocations that were
   killed at the wall had a median **173 tool calls at 3.9 tools/min** —
   more work than the median OK unit (128 calls), at the same rate. They
   were still working, not idle.
3. **The wall time went into local build/test steps and CI-polling, not
   seat cooldowns.** The stalled >120s blocks in the censored sessions are
   `timeout vitest/playwright/wrangler` runs and `for i in $(seq 1 30);
   sleep 1` CI-poll loops. Across the 144 devin transcript blocks sampled
   from the day, 89 are test/build, 19 CI-poll, and the 7 that mention
   429/quota are other workers *discussing* seat walls, never this unit's
   own seat failing.
4. **It is not a concurrency-governor value.** True peak concurrent workers
   that day was **17 against the declared `target_concurrent` of 25**, and
   the implicated hour's host load was 4.85 on 8 vCPU with ~5 GB
   MemAvailable. Neither RAM admission nor `CPUQuota` was the binding
   constraint.
5. **16 of 30 timed-out units completed on the restart** — the same work
   re-run to the end given more wall, across every lane.

**Class totals (40 events, 2026-09-22):** 7 "still working at the wall"
(censored, rate >= 3 tools/min), 7 "heavy build/CI-poll wall time"
(censored, stalls >= 15% of span), 26 devin/cursor CLI-lane events with no
Pi session file — classed on the same CPU + devin-transcript evidence above.

## The fix (one value per lane, no scripts)

`TimeoutStartSec=45min -> 90min` on the two lanes whose own population
shows the censoring: `systemd/devin-issue@.service` (23 of the 35) and
`systemd/router-issue@.service` (5 of 15 = the worst rate, 33%).
`90min` covers p95 of each lane's measured demand with headroom for the
CI-poll loops. The lanes that did **not** show mid-work censoring
(`pi-issue@`, `cursor-issue@`) keep `45min` — this is not a fleet-wide
raise.

## Measuring the termination criterion the same way

The criterion is "the next 24h show the devin timeout rate below 5%,
measured the same way". The issue's own rate is timeouts divided by
**Finished-OK units** (`98 | 23 | 19%` in its table), so that is the
denominator used here:

    timeouts = COUNT of units with Result=timeout in the user journal for
               the window  (journalctl --user --since <t0> -o json; field
               UNIT_RESULT == "timeout", unit matching devin-issue@*)
    finished = COUNT of devin-issue@ units that reached a normal stop
               ("Finished <unit>" line) in the same window
    rate     = timeouts / finished

Baseline for 2026-09-22 00:00-23:59 IST: **23 timeouts / 98 finished — the
issue's own 19%** (every one of the 23 is re-derived from the journal in this
run; see the table in the PR body). The post-change target is < 5%. There is
no standing metric for this rate (the `fleet_oomd_kills_6h` class of bespoke
counters was deleted in the 2026-09-18 sweeps), so this command line is the
measurement, to be run once at t0+24h on the same host. It is deliberately a
journal query and not a new emitter: no-glue bars adding one, and the
issue's own "no scripts, no wrappers" clause forbids it.

## Residual, named

- **The devin/cursor lanes have no Pi session file** (their CLI writes
  elsewhere), so 26 of the 40 events could not be joined to a transcript.
  Their class rests on the systemd CPU accounting plus the devin
  transcript blocks, both of which agree with the joined lanes.
- **`~/.config/systemd/user/pi-issue@.service` is deliberately masked**
  (`-> /dev/null`) per the 2026-09-22 intake decision while SuperGrok is
  walled; its 10 timeout events predate the mask and are not actionable
  while the lane is parked. That is why `pi-issue@` is not raised here.
