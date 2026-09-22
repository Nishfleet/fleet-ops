# Observe-close for #8324 — the worker start-timeouts were a too-short `TimeoutStartSec` on the devin/router lanes, fixed by one unit value each

fleet-ops#8324 (filed 2026-09-22T13:03:10Z by `nish3451`) reports 35 worker
start-timeouts that day with devin carrying 23 of them, clustering in the
17:00-19:00 IST window at 21-28 concurrent. It asks for a **population**
diagnosis with controls, not one unit: was the worker still working at the
45-minute mark, idle waiting on a seat cooldown, or stuck on a build step
under CPU load — then a fix "at the lowest rung: one unit line or one config
value, in this repo, by PR. No scripts, no wrappers."

This report is the measurement record the `termination:` criterion needs
("the next 24h show the devin timeout rate below 5%, measured the same way").
It ships with the fix itself. Everything below is re-derived in this run from
the user journal plus the per-unit transcripts; no number is carried over
from the issue.

## Method — the join

Three sources, joined per timeout event:

1. **The event itself** — `Result=timeout` for a worker lane in the user
   journal (`journalctl --user -o json`; message
   `<lane>-issue@<key>.service: start operation timed out`). 62 such events on
   2026-09-22 00:00-19:30 IST across all lanes (see `Population` below).
2. **systemd's own resource accounting** — the
   `Consumed <cpu> CPU time, <mem> memory peak` line emitted at the same stop.
3. **The unit's own transcript**, which is lane-specific and must be joined
   correctly or the analysis is fiction:
   - `router-issue@` and `pi-issue@` write a Pi session JSONL at
     `~/.pi/agent/sessions/<lane>-issue-<key>/<ts>_<uuid>.jsonl`. These units
     restart, so a unit owns **several** files and the join must pick the file
     whose session start is the latest one *before* the stop timestamp — taking
     any other file mislabels the row.
   - `devin-issue@` and `cursor-issue@` write **no** Pi session file. Their
     transcript is the devin CLI log at
     `~/.local/share/devin/cli/logs/devin_<ts>_<pid>.log`, matched to the unit
     by the workspace path `issue-<key>` it runs in. This join exists and was
     verified for every devin timeout unit today; it is what makes finding 2
     below evidence rather than inference.

Tool calls are counted from `role=assistant` / `content[].type=toolCall`
records; span is first-to-last transcript timestamp; tool rate is calls/span.

## Population (all lane start-timeouts, 2026-09-22 00:00-19:30 IST)

| lane | `Result=timeout` events | `Finished` events | joined to a transcript |
|---|---|---|---|
| devin-issue | 26 | 99 | via devin CLI log |
| router-issue | 24 | 13 | via Pi session JSONL |
| pi-issue | 5 | 96 | via Pi session JSONL |
| cursor-issue | 4 | 33 | via devin-class CLI log |
| **worker lanes** | **59** | **241** | |
| pi-intake (not a worker lane) | 3 | 128 | n/a |

The router count is live and rising while this runs: 23 of its 24 events are
after 17:00 IST, 13 of them in the 19:00 hour alone, from a mass start burst
(`3967/3969/3970` then `3971/3979/3984/3989/3999/4001/4005`, each ~11 s apart,
each timed out ~45 min later because `TimeoutStartSec=45min` and the burst
started them together). That burst is the same signature the issue describes.

## Findings, with controls

1. **The router lane is killed mid-work, not while idle.** 21 of 24 router
   timeout events join to a Pi session censored at the wall: span p50 **44.2
   min**, p50 **162 tool calls**, p50 **3.75 tools/min**. The same-lane units
   that finished early today ran p50 8.0 min / 56 calls — the censored units
   are not a slower variant of the completed ones, they are *longer* sessions
   doing the same kind of work at a normal rate, still going at the 45-minute
   mark.
2. **Devin is the same class, and it is joinable.** Every devin timeout unit
   today matches a devin CLI log that spans the full 45-min wall with real
   tool activity: `0509-3927` 08:23:56→09:08:46 UTC with 43
   vitest/playwright/npm/tsc command starts, `0509-3884` 12:08:26→12:53:24
   with 17, `0509-3879` with 33, `0509-3925` with 40. This is not the seat-
   cooldown class (finding 3) and not the governor class (finding 4).
3. **The seat-wall class is empty.** No timed-out unit's own transcript
   (Pi session or devin log) carries a 429 / quota / walled signature for
   *its own* seat. Prior runs that mention seat walls are other workers
   discussing the SuperGrok 402 wall, not this unit's seat failing.
4. **It is not a concurrency-governor value.** The timed-out units burn a
   small fraction of one core across the wall — 1.0-11.3% of the 45 min
   (max 299 s CPU), median ~5% — and the implicated hour's host load was 4.85
   on 8 vCPU with ~5 GB MemAvailable. Neither RAM admission nor `CPUQuota` is
   the binding constraint; true peak concurrent workers (17) never reached the
   declared `target_concurrent` (25).
5. **The decisive control: more wall finishes the work.** Of the 20 units
   (router + pi lanes) whose first session today was censored at the wall,
   **15 finished the same work on the restart in a shorter session**. That is
   the same work re-run to the end given more wall, not a different outcome.

**Class totals for the events in this run (as of 19:30 IST):**

| class | definition | count | basis |
|---|---|---|---|
| A — still working at the wall | session span >= 35 min, tool rate >= 2/min | 26 | joined Pi session (router/pi) |
| A* — CLI lane, log-joined to the wall | devin/cursor, classed on the devin CLI log join + systemd CPU | 30 | devin CLI log, CPU |
| H — short-span hang | session span < 35 min on a 45-min wall | 3 | joined Pi session (router/pi) |
| B — idle / seat-cooldown starved | own transcript carries a 429/quota/walled signature | **0** | transcript search |

The class-C subset (build/CI-poll wall time) is not a separate population
count: it is the subset of A whose long stalls are `timeout
vitest/playwright/wrangler` runs and `for i in $(seq 1 30); sleep 1` CI polls,
and it is described in finding 3 rather than double-counted here.

Short-span hangs exist (3 events: `fleet-ops-4403` first attempt 6.5 min,
`0509-3985` first attempt 11.3 min, `0509-3990` first attempt 2.2 min) —
they are a small minority and each is a unit that was re-run, which is why
they do not change the direction. They are named rather than dropped: the
raise costs those 3 an extra 10 min each, which is the accepted price of the
other 26.

## The fix (one value per lane, no scripts)

`TimeoutStartSec=45min -> 55min` on the two lanes whose own population shows
mid-work censoring, each commented in place with the join and the numbers
above. **55min, not 90min, because the worker's own `GH_TOKEN` is minted in
`ExecStart` at t=0 and is a <=1h GitHub App installation token**: a wall past
~60min runs the worker with an expired token, so the extra minutes buy a
failed artifact check instead of a landed PR. 55min clears the lane's measured
demand and still leaves the token alive for the final push/PR steps. A longer
wall needs a token refresh inside the run, which one unit value cannot do.

- `systemd/devin-issue@.service` — devin, 26 of the day's 59 worker-lane
  timeout events, every one joined to a devin log spanning the wall.
- `systemd/router-issue@.service` — router, 24 events, 21 of them joined to
  censored Pi sessions.

`pi-issue@` and `cursor-issue@` keep `45min`: they are 9 events between them
and `pi-issue@` is deliberately masked (`-> /dev/null`) while SuperGrok is
walled. This is a two-lane raise, not a fleet-wide one. The value is `55min`
(the token bound above), which clears the CI-poll headroom the lane needs.
because lane demand measured at p50 44.2 / p90 45 min, and the CI-poll loops
need the headroom; it is the lowest rung because the alternatives (a governor
value, a seat cap) are contradicted above.

## Measuring the termination criterion the same way

The issue's own table is `devin-issue | 98 | 23 | 19%`, and 23/121 = 19.0%
while 23/98 = 23.5%. So the issue's "rate" is **timeouts / (finished +
timeouts)** — the share of the lane's starts that ended in a timeout — not
timeouts / finished. An earlier draft of this report used timeouts / finished
and so could not reproduce the issue's 19%; that is corrected here.

    rate = timeouts / (finished + timeouts)          <- the issue's own arithmetic
           (finished = `Finished <unit> ...` lines in the same window)

    t0   = 2026-09-23 00:00 IST (first full hour the 55min wall is live)
    read = at t0 + 24h, same host, same journal query

Baseline 2026-09-22 00:00-19:30 IST, re-derived from the journal in this run:
**26 devin timeout events / (99 finished + 26) = 20.8%**, against the issue's
snapshot 23/121 = 19.0% at 18:50 (the difference is the three devin events
between 18:50 and 19:30, all from the 17:34 burst completing its retry loop).
Target at t0+24h: **below 5%**.

The measurement is a `journalctl` query, not a new emitter — no-glue bars
adding one and the issue's own "no scripts, no wrappers" clause forbids it.
The exact command line and window are recorded here so the reading is
reproducible by anyone holding the host.

## Residual, named

- **The join for `pi-issue@`/`router-issue@` must be done per restart.** A
  unit owns several session files; the wrong file mislabels the row (the
  first draft of this analysis did exactly that and produced short spans for
  units that were really censored at the wall). The PR body's table carries
  the corrected join.
- **`cursor-issue@` has 4 timeout events** and is classed on its CLI log, the
  same evidence as devin; it is not raised because it is 4 events and its
  units run a different toolchain. If tomorrow's population shows cursor
  censored at the wall too, it gets the same treatment.
- **`pi-issue@` contains this issue's own worker** (`pi-issue-fleet-ops-8324`
  at 19:19:29 IST): its session ran 42.9 min with 152 tool calls and was
  killed at the 45-minute wall while working. That is the phenomenon under
  diagnosis, measured on the diagnosing process.
- `~/.config/systemd/user/pi-issue@.service` is deliberately masked
  (`-> /dev/null`) per the 2026-09-22 intake decision while SuperGrok is
  walled; its timeout events are not actionable while the lane is parked.
  That is why `pi-issue@` is not raised here.
