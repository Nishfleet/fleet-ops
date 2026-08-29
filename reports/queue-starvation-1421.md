# Queue starvation closeout — 222 ready, 1 claim/2h, 5017 cap=0 events (fleet-ops#1421)

Report date: 2026-08-29
Issue: fleet-ops#1421 — "Queue starvation: 222 ready items, 1 claim in 2h,
load1 0.14"
Host: netcup-rs2000

## The reported snapshot (2026-08-27T22:30:01Z)

- `ready_work = 222` (up from 219)
- `claims_last_2h = 1`, `dispatches_last_2h = 1`
- `at_capacity_events_last_2h = 5017` with samples showing `provider cap=0` /
  `model cap=0` on opencode, opencode-anthropic, orcarouter, inferx, grok
- `skips = 1`, `empty_runs = 0`, `redispatches = 0`
- `load1 = 0.14`, `ram 17.11%`, `seats_healthy = 16`
- No failed units, no red CI, `chain_stalled = 0`

## Root cause

Two independent defects, neither a crash — both intake/cap configuration
starving dispatch next to idle capacity, exactly as the issue framed it.

### 1. Surge-leverage-exhaustion (the binding constraint)

The snapshot landed at `2026-08-27T22:30:01Z`, inside the precedence-band
**surge phase** (cutoff `2026-08-28T02:30:00Z`). During surge, fleet-ops
intake claims **only** the 12 `surge_leverage_issues` in
`config/precedence-band.json`. The other ~210 ready items are non-leverage
machinery and are skipped-precedence-band by design.

When all 12 leverage issues were already claimed / blocked / done, a pure
skip left the fleet-ops queue at **0 dispatches for up to the whole surge
window**. `empty_runs = 0` and `redispatches = 0` confirm this was not a
claim-loop or retry fault — the dispatcher had nothing it was allowed to
claim. The 222 ready items sat because the surge hold correctly refused
them; the 1 claim in 2h was the last leverage issue draining.

Evidence: `lib/pi-intake-tick.sh` surge skip + the policy's
`surge_leverage_issues` list of 12 numbers. The healthy seats (bai, devin,
straitly, xai-oauth, ollama) were reachable — they simply had no
surge-eligible work.

### 2. cap=0 noise flood (the misleading counter)

`at_capacity_events_last_2h = 5017` was **not** the binding constraint. It
was benched seats (cap set to 0: dead_decoy / money_only / stale) emitting
one `provider cap=0` / `model cap=0` skip line per pass. With ~6 cap=0
providers at ~5 calls/sec, that is ~30 cap=0 lines/sec → thousands per 2h.
This is the counter that made the snapshot look like a capacity wall when
the real constraint was the surge hold. `empty_runs = 0` proves seats were
not being picked and rejected — they were never reached because no
leverage work was claimable.

## Mechanical fixes (already landed on main)

The root-cause class — a watcher / intake path misreading a legitimate
intake state as starvation — is mechanically prevented by three already-
merged PRs. This report cites them; no new machinery is added.

- **#1431** (PR #1904, merged 2026-08-29 05:51 UTC) — **surge floor**.
  When no `surge_leverage_issue` is agent-ready, the early surge skip
  relaxes and `precedence_band_allow_claim` admits exactly one
  machinery/repair lane (latched per tick). The queue can never hard-stall
  at 0 dispatches through a surge window. This is the direct fix for
  defect #1. Regression-pinned in `tests/fleet-precedence-band.test.sh`
  scenarios 16b / 17a2 / 17a3 (surge floor fires + is latched to one lane).
- **#1448** (PRs #1939/#1940, merged 2026-08-29) — **band-phase starvation
  floor**. In the band phase, starvation-class issues (the dispatch/claim
  pipeline not consuming the queue) get one floor lane per tick even when
  the machinery cap is consumed, so the throttle diagnostic can never be
  locked out by the cap. Pinned in scenarios 19f/19g/19h.
- **#1941** (merged 2026-08-29) — **cap=0 seat classification**. cap=0
  seats are classified intentional (`dead_decoy` / `money_only`) vs stale,
  and the per-pass cap=0/dead skip line is silenced (pre-computed excluded
  set, `fleet-ops#1449/#1456`). The 5017-events/2h cap=0 flood no longer
  exports. This is the direct fix for defect #2.

## Mechanical fix shipped in this PR (remaining instance of the class)

While verifying the closeout, a **live** remaining instance of the same
disease was found and fixed in this PR:

- The precedence-band canary (`lib/pi-packet/precedence-band-canary.py`,
  `check_band_phase`) was false-positiving on `machinery share 100% (=
  N/N) is over the cap 30%` whenever **zero product units were live** —
  e.g. 2026-08-29 07:02–08:00 UTC (10–15 machinery / 0 product, all 7
  0509 agent-ready issues `blocked-on`). The canary cried wolf for ~1h and
  would have auto-filed a false starvation cluster — the exact disease
  this issue is about.
- The rent-paying band is a **ratio among live units**. When zero product
  units are live (all product work blocked-on / between intake ticks),
  there is no product share to protect, so 100% machinery is the only
  possible value and the ratio is undefined. Flagging it as drift is the
  same watcher-misreads-legitimate-state failure as surge-leverage-
  exhaustion.
- Fix: `check_band_phase` now exempts `product_count == 0` (ratio
  undefined). "Is product intake healthy / is claimable product being
  starved" remains the undersaturation watchdog's job (it pages on ready
  supply vs running workers), not this canary's. Ratio enforcement among
  LIVE units is unchanged: the moment even one product unit is live,
  machinery over the cap is still rejected.
- Regression-pinned in `tests/fleet-precedence-band.test.sh`:
  - scenario10e — 10 machinery / 0 product → exit 0 (legitimate).
  - scenario10f — 9 machinery / 1 live product → exit 1 (real drift,
    negative control proving 10e does not weaken ratio enforcement).

## Throughput proof over a full cycle after the changes

Live state 2026-08-29T08:15Z (`fleet.prom` + `fleet-seat-selection.prom`):

- `fleet_ready_work = 72` (down from the reported **222**; ~68% reduction).
- `fleet_merged_prs_24h{repo="Nishfleet/0509"} = 21` — product throughput
  is live, not starved.
- Seat selection, trailing 24h: devin=2041, commandcode=1791, bai=1160,
  straitly=318, hetzner=173, opencode=141, cline=55, ollama=55,
  openrouter=47, xai-oauth=36, minimax=4. Every healthy seat named in the
  snapshot (bai, devin, straitly, xai-oauth, ollama) is being selected —
  the 1-claim/2h starvation is gone and the seats are reachable.
- The 5017/2h cap=0 flood no longer exports.
- Precedence-band canary post-fix: `PRECEDENCE-BAND-OK phase=band
  machinery=13 product=0 total=13 share=100%` (exit 0) — the live false
  positive is silenced; the canary stays honest about real drift.

## Scope note

No new retry/poll/dispatch machinery was added, per the issue's framing
and the deletion-first mandate. The fixes are: one already-landed surge
floor, one already-landed cap=0 classifier, one already-landed band
starvation floor, and one canary exemption shipped here. Net machinery
trend is negative (the cap=0 flood silencing alone removed thousands of
log lines/2h).
