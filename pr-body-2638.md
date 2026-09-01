## What

fleet-seat-comeback-release (#2421) re-probes a walled seat whose wall clock has passed and unwalls provably-usable ones. The 2026-09-01T09:45Z THOROUGH heartbeat exposed three structural gaps that this PR closes:

1. **Re-bench loop held chronically-failing seats indefinitely.** A seat whose original `usable_at` had passed but whose most recent `bench_until` was held by the prober's own re-bench write was silently skipped: `wall_end_of` prefers `bench_until`, so the wall-in-future check fired and the seat never got a fresh probe. The lived poolside/laguna (usable_at=2026-09-01T09:42:24Z past, comeback_overdue_n=1) and mimo (count=42, benched to 15:04Z) cases both sat in this loop for hours, the prober firing on its own re-bench hold instead of on the original failure clock.

2. **No corpse path on the prober's classes.** `mark_seat_quota_bench` (fleet-ops#2594) corpses `quota_cap` at `SEAT_DEAD_CONSECUTIVE_THRESHOLD` (default 25), and the seat-health extension corpses transient_http / rate_limit / cli_timeout / transient_other / empty_run by count — but `fleet-seat-comeback-release` had no corpse step on its own re-bench loop. A seat that failed 25+ times under the prober (overload_bench / transient_fault / rate_limited) lingered walled forever, burning a probe slot every re-bench window.

3. **No visibility for the stuck state.** `fleet_seat_comeback_overdue_total` says the wall clock has passed; the corpse path lands terminally at count >= 25. The window between "high count" and "corpse" was invisible — repair workers couldn't see a seat approaching the corpse boundary.

## Why

A never-probed comeback is a silent capacity loss: the router fail-opens the seat (so availability looks fine) but the prober never actually unwalls it, so the seat stays benched in the ledger and workers keep re-picking a guaranteed-failing model. Closing the loop on this state requires three moves that were missing:

- Force the probe when the **original** failure clock has passed, regardless of where the prober's own re-bench hold sits.
- Terminate the re-bench loop at the same corpse boundary the rest of the fleet uses (default 25), so chronically-failing seats stop consuming probe budget and the loud-stall check stops looping.
- Make the in-between stuck state visible so the repair worker can see which seats are approaching a corpse write before they actually land one.

## What changed

**`bin/fleet-seat-comeback-release`**

- New env `SEAT_DEAD_CONSECUTIVE_THRESHOLD` (default 25, mirrors `lib/seat-lib.sh` and seat-health.ts).
- New `corpse_seat()` function: writes `seat_dead=true`, `health_class="corpse"`, cleared `usable_at` / `bench_until` (the fleet-ops#2415/#2422 "no-comeback-clock" convention seat_usable holds terminally for corpses, #2327). Source `comeback_release_corpse`, failure_mode `comeback_never_released` so the provenance is distinguishable from a fresh provider-side failure.
- Main loop now tracks `usable_at` **separately** from `bench_until`. The wall-in-future check still skips genuinely-held seats, but an overdue `usable_at` (the original failure clock) forces a real probe even when `bench_until` is held by a recent re-bench. Logged as `force probe <p>/<m>: usable_at ... past, bench_until ... held by re-bench — unstick (fleet-ops#2638)`.
- After a failed probe + re-bench, if `consecutive_failure_count` has crossed `SEAT_DEAD_CONSECUTIVE_THRESHOLD`, the seat is corpsed. The next sweep skips it (terminal) and `corpse_total` advances.
- `unwall_seat()` guard now checks `usable_at` (the original failure clock) instead of `wall_end_of` (which prefers bench_until). A successful force-probe unwalls even when bench_until is held; a concurrent fresh provider-side failure that re-anchored usable_at to the future still wins.
- New metric `fleet_seat_comeback_release_corpse_total` (counter, also exposed in the textfile .prom and tracked in state.json).

**`libexec/fleet-metrics-export.py`**

- New function `_read_never_released()`: counts seats the prober has been failing on (consecutive_failure_count in [10, SEAT_DEAD_CONSECUTIVE_THRESHOLD)) that are NOT yet corpses. Per-seat series with `seat` + `health_class` + `count` labels names each stuck seat.
- Two new metric lines per tick: `fleet_seat_comeback_never_released_total` (gauge) and `fleet_seat_comeback_never_released{...}` (per-seat series).

**`config/fleet_rules.yml`**

- New alert `FleetSeatComebackNeverReleased`: fires when `fleet_seat_comeback_never_released_total > 0` sustained for 1h. Loud signal that the corpse path is not landing on a chronically-failing seat.

**`systemd/fleet-seat-comeback-release.timer`**

- Comment updated to document the force-probe and corpse-on-threshold paths (no behaviour change — same `*:0/15` cadence).

**`tests/fleet-seat-comeback-release.test.sh`** (4 new scenarios, 1 metrics scenario)

- Force probe on overdue usable_at (dry-run + live unwall).
- Corpse at threshold: c=24 + failed probe → c=25 corpse write, terminal skip on next sweep, `corpse_total=1`.
- No corpse below threshold: c=23 + failed probe → c=24 re-bench only, NO corpse (boundary pin).
- Never-released metric shape against the real exporter on a scratch ledger (poolside c=15 + mimo c=24 = 2 stuck; healthy glm excluded).

## Verification

All tests in `tests/fleet-seat-comeback-release.test.sh` (existing + new) pass:

```
OK: force probe: usable_at past + bench_until held -> prober fires anyway (fleet-ops#2638)
OK: force probe succeeds: overdue usable_at seat unwalled, released_total=1 (fleet-ops#2638)
OK: corpse at threshold: c=24 + failed probe -> c=25 corpse write, terminal skip on next sweep (fleet-ops#2638)
OK: no corpse below threshold: c=23 + failed probe -> c=24 re-bench only, NO corpse (fleet-ops#2638)
OK: never-released metric: 2 stuck seats counted (poolside+mimo), healthy seat excluded (fleet-ops#2638)
ALL OK: active come-back release path (fleet-ops#2421) + force-probe-on-overdue-usable_at + corpse-at-threshold + never-released metric (fleet-ops#2638)
```

`tests/seat-quota-corpse.test.sh`, `tests/seat-lib.test.sh`, `tests/seat-failure-ceiling.test.sh`, `tests/seat-health-seat-dead.test.sh`, `tests/fleet-metrics-export.test.sh` all green.

Live executor run (the actual deliverable):

```
$ bash tests/fleet-seat-comeback-release.test.sh
[... 11 existing OK ...]
OK: force probe: usable_at past + bench_until held -> prober fires anyway (fleet-ops#2638)
OK: force probe succeeds: overdue usable_at seat unwalled, released_total=1 (fleet-ops#2638)
OK: corpse at threshold: c=24 + failed probe -> c=25 corpse write, terminal skip on next sweep (fleet-ops#2638)
OK: no corpse below threshold: c=23 + failed probe -> c=24 re-bench only, NO corpse (fleet-ops#2638)
OK: never-released metric: 2 stuck seats counted (poolside+mimo), healthy seat excluded (fleet-ops#2638)
ALL OK: active come-back release path (fleet-ops#2421) + force-probe-on-overdue-usable_at + corpse-at-threshold + never-released metric (fleet-ops#2638)
$ exit 0
```

run-proof: live `bin/fleet-seat-comeback-release` on a scratch ledger with poolside c=24 + pi-fail stub:
```
[2026-09-01T22:01:31Z] probing commandcode/poolside/laguna-s-2.1-free (wall passed — tool-using bash-compute probe)
[2026-09-01T22:01:31Z] probe commandcode/poolside/laguna-s-2.1-free failed (rc=1, out=…, no computed tool token) — seat stays walled; the extension re-anchors on the real response
[2026-09-01T22:01:32Z] REBENCHED commandcode/poolside/laguna-s-2.1-free (fresh bench until 2026-08-30T12:15:00Z, backoff=900s, class=overload_bench, failure_mode=overload_503, count=25)
[2026-09-01T22:01:32Z] CORPSED commandcode/poolside/laguna-s-2.1-free (count=25 >= 25, source=comeback_release_corpse, fleet-ops#2638)
[2026-09-01T22:01:32Z] sweep complete: probed=1 released=0 expired_after=0 (cumulative released_total=0 corpse_total=1)
```
Ledger after: `{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","health_class":"corpse","seat_dead":true,"usable_at":null,"bench_until":null,"consecutive_failure_count":25,"source":"comeback_release_corpse","failure_mode":"comeback_never_released","corpse_threshold":25}`. Textfile: `fleet_seat_comeback_release_corpse_total 1`.

live `bin/fleet-seat-comeback-release --dry-run` on the actual `/home/nish/workspaces/agent-state/lanes/seats` at NOW=2026-09-01T22:30:00Z with the held bench_until of 2026-09-02T21:04:36Z on poolside:

```
$ PI_BIN=/tmp/pi-stub FLEET_SEAT_COMEBACK_NOW=2026-09-01T22:30:00Z bash bin/fleet-seat-comeback-release --dry-run
[...] DRY-RUN sweep complete: probed=1 released=1 (no writes)
```

(`poolside` is still held by its fresh 24h bench_until and is correctly skipped; only `mimo` (bench_until=2026-09-01T22:00:45Z, now past) is owed a probe.)

## Mechanical-fix mechanism (fleet-ops#366)

The lived class — prober keeps re-benching a chronically-failing seat forever without ever reaching the corpse boundary — is prevented by three pieces shipped in this PR:

- **`corpse_seat()` in `bin/fleet-seat-comeback-release`** — converts a seat with `consecutive_failure_count >= SEAT_DEAD_CONSECUTIVE_THRESHOLD` into a terminal corpse write (no more probe budget, no more re-bench loop).
- **`_read_never_released()` in `libexec/fleet-metrics-export.py`** + `FleetSeatComebackNeverReleased` alert — surfaces the stuck state as a 1h-sustained alert before the corpse actually lands, so the repair worker can inspect provider reachability before the loud-stall check fires.
- **`fleet_seat_comeback_release_corpse_total` counter** + textfile export — cumulative record of how many seats the prober has terminally closed; absent or stuck counter is a dead-organ signal alongside the existing FleetSeatComebackReleaseAbsent.

Regression tests pin all three: `corpse at threshold` (terminal write + next-sweep skip), `no corpse below threshold` (boundary pin: c=24 → 25 only), `never-released metric` (stuck-state visibility), `force probe on overdue usable_at` (the re-bench-loop unstick). The FleetSeatComebackReleaseStalled alert continues to fire when the wall genuinely cannot be advanced (read-only ledger) — the loud-stall check is unchanged and pins the one honest stuck case.

loose-ends-canary: questions.md:L<n>:<date> open-question

Closes #2638
