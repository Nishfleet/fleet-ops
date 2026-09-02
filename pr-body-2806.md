## What and why

fleet-ops#2806: at the 2026-09-02T09:45:01Z snapshot two seats
(commandcode/poolside-laguna-s-2.1-free, opencode/nemotron-3-ultra-free) were
past `usable_at` yet still counted walled (`usable_at_overdue=true`), the
comeback-overdue alert was pending, ready_work was 53, and the seat-availability
SLO was in slow burn.

Releaser investigation (journal `fleet-seat-comeback-release.service`, live
ledgers, state file): the organ was firing every 15-min tick and released
poolside twice in the snapshot hour (08:45Z, 09:16Z) — the extension re-anchored
it into the future seconds after each unwall (600s overload benches). Two real
gaps surfaced, and this PR closes both:

1. **No loud signal for "overdue by more than one probe interval".** The organ's
   stalled check keys on `wall_end_of` (`bench_until ?? usable_at`), a clock that
   the extension or a re-bench advances INTO THE FUTURE on every failed probe —
   so a chronically-failing seat (nemotron: 8h of 15-min failed probes, count
   15→17) ended every sweep with `expired_after=0` and never once rendered loud.
   Added an **interval-breach loud check**: post-sweep, any walled seat whose
   RAW `usable_at` is still in the past by more than MIN_INTERVAL (900s = one
   probe interval) exits the sweep 1 (OnFailure escalates, last-green goes
   stale) and writes `fleet_seat_comeback_release_interval_breached{seat=}` plus
   a total gauge. New `FleetSeatComebackReleaseIntervalBreached` alert rule
   (1h-for, severity=warning) keeps the sustained case visible at the alert
   plane. This is the mechanical prevention for the incident class
   (fleet-ops#366): the detector fails loud the moment a seat sits overdue by
   more than one probe interval.

2. **Corpse-out cadence hostage to the extension's counter.** The extension only
   increments `consecutive_failure_count` on real responses, at its own cadence
   (nemotron 15→17 across 8h), so the corpse-at-threshold path (fleet-ops#2638)
   could not terminate a chronically-failing seat in a useful window — it
   lingered walled and kept the overdue/SLO noise alive. The organ now keeps its
   own per-seat consecutive-failure streak (`own_failures` in the state file),
   seeded from the ledger count at first sighting, advanced on EVERY
   release-probe failure (even when the extension re-anchored first and the
   re-bench skips), reset on a successful probe or a healthy observation, and
   corpses on the MERGED streak (max of ledger count and own streak) at
   SEAT_DEAD_CONSECUTIVE_THRESHOLD (25). A chronically-failing seat now corpses
   within ~25 probe cycles (~6h at the 15-min tick), then the existing #2716
   retirement path physically removes the ledger from the roster — the
   "retire them so seats_dead stops padding the seat-availability SLO" arm.

3. **Overdue flag graced one probe interval.** The comeback-overdue metric
   (`fleet_seat_comeback_overdue_total` in `_read_comeback_overdue`) and the
   thorough snapshot's `usable_at_overdue` (installed `opus-heartbeat-gather`)
   fired the instant `usable_at` passed, even though the releaser re-probes
   within one 15-min cycle — a seat a few minutes past is MID-CYCLE, not
   overdue. Both now grace on COMEBACK_OVERDUE_GRACE_S=900 (matching the
   releaser's FLEET_SEAT_COMEBACK_MIN_INTERVAL_S default): only a wall past by
   MORE than one probe interval counts as overdue — the releaser had a full
   cycle to act and did not. Release-at-expiry itself (the #2407 fail-open +
   rollup release) is UNCHANGED: a seat still returns to the healthy pool the
   instant `usable_at` passes.

## Corpse triage (issue ask)

The two seats named as corpse at the snapshot (cline/cline-pass-minimax-m3,
opencode/mimo-v2.5-free) are NO LONGER corpse in live state: the corpse ledgers
were retired at 12:11Z (seats-corpse-retired-2026-09-02T12:11:48Z/) and
re-created later by real probes that re-classified them
(cline-pass-minimax-m3 -> quota_exhausted, a billing wall; mimo-v2.5-free ->
rate_limited 429, count 17, live comeback clock). No config/cap change is
warranted for either — both are legitimately-enrolled seats in wall classes,
not corpses — and repairing the quota wall is Nish-reserved spend. The DURABLE
"retire so seats_dead stops padding the SLO" path is the own-streak corpse +
#2716 retirement in (2): any seat that cannot be proven usable by
SEAT_DEAD_CONSECUTIVE_THRESHOLD failed probes now terminally corpses and is
physically retired out of the live roster.

## Verification (Execution IS the review)

All touched test suites run green on this branch; each new behavior is pinned
with a frozen clock:

- `bash tests/fleet-seat-comeback-release.test.sh` — 24 scenarios ALL OK,
  including: 3c extended (read-only ledger -> both LOUD channels +
  `interval_breached_total 1` + per-seat series), scenario 14 (own-streak 24 +
  failed probe -> merged 25 corpse write with count=25, terminal skip),
  scenario 15 (past-by-500s < interval -> re-bench, breach gauge 0, exit 0),
  scenario 16 (own streak resets on a healthy interlude).
- `bash tests/fleet-metrics-export.test.sh` — ALL OK, incl. #14 extended
  (mid-cycle seat past-by-300s excluded from comeback-overdue, count stays 3).
- `bash tests/opus-heartbeat-seat-comeback.test.sh` — ALL OK, incl. the new
  grace fixture (`usable_at_overdue` False inside the 900s grace).
- `python3 -m py_compile libexec/fleet-metrics-export.py` and an ast parse of
  the gather — OK. `yaml.safe_load(config/fleet_rules.yml)` — OK.
- Gates: fleet-rules-severity-page, fleet-organ-heartbeat, fleet-no-agent-names,
  fleet-token-efficiency, manifest-shape, timer-manifest, p14-test-listing-gate,
  fleet-seat-recovery — all PASS.

run-proof: live sweep of the changed bin against the real ledger
(`bash bin/fleet-seat-comeback-release` from this worktree, 2026-09-02T18:11Z):
probed opencode/mimo-v2.5-free (wall passed at 18:00:14Z), probe failed (still
429, rc=1), extension re-anchored to 18:26:41.700Z, `sweep complete: probed=1
released=0 expired_after=0`, exit 0. State `own_failures` seeded from live
ledger counts (mimo 17->18, minimax 20, poolside 5, devin 1) and
`fleet_seat_comeback_release_interval_breached_total 0` written, last-green
advanced. Live exporter re-run: `comeback_overdue_total=0` (mid-cycle seats no
longer false-flag), `never_released_total=3` (unprobed-comeback visibility
intact), healthy_enrolled 9/13.

The installed `opus-heartbeat-gather` was edited in place (it is a hand-placed
organ, NOT repo-tracked; only its tests live in this repo — the contract the
test header documents). The repo diff carries the tests that pin the change.

### Post-rebase re-verification (2026-09-03)

Rebased onto origin/main (4352d8b4, 9 new commits) — clean, no conflicts.
Re-ran every touched suite and gate on top of current main:

- `bash tests/fleet-seat-comeback-release.test.sh` — 24 scenarios ALL OK.
- `bash tests/fleet-metrics-export.test.sh` — ALL OK (incl. #14 mid-cycle grace).
- `bash tests/opus-heartbeat-seat-comeback.test.sh` — ALL OK (incl. 900s grace).
- `bash tests/fleet-seat-recovery.test.sh` — ALL OK.
- `bash tests/rule-enforcement.test.sh` — ALL OK (128 rules, organ-heartbeat drill green).
- `bash tests/manifest-shape.test.sh`, `bash tests/timer-manifest.test.sh` — OK.
- Gates: fleet-no-agent-names-check, fleet-token-efficiency-check,
  fleet-organ-heartbeat-check, fleet-exec-review-canary, fleet-wipe-lessons-check
  scan — all PASS.

Pre-existing (not this PR): `tests/p14-test-listing-gate.test.sh` reports
`fleet-deploy-quality.test.sh` is unhosted — that gap came from #2885 on main
and is already tracked as fleet-ops#2894. Not fixed here.

## mechanical-fix

`mechanism: interval-breach detector + merged-streak corpse termination` — the
prevention ships in this PR (items 1 and 2 above).

## organ-heartbeat

No new organ added; the existing seat-comeback-release organ gained a metric
and a loud exit. Its fleet-organs.json registry entry and absent-alert are
unchanged.

loose-ends-canary: pr:nishfleet/fleet-ops#2881 stale-worker-pr
Closes #2806
