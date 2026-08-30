fix(seat): active come-back release — re-probe and unwall seats whose wall clock has passed (fleet-ops#2421)

## What broke

Snapshot 2026-08-30T18:30:09Z: straitly/gpt-5.6-sol (quota_exhausted) had
usable_at an hour in the past yet walled=true, released=false;
FleetSeatComebackOverdue was pending at value=3 and released_n stayed 0
across the whole roster — nothing had EVER been released back. The
fleet-ops#2407 metric-side release (gather seat_table released flag,
`_seat_is_released` in fleet-metrics-export.py) only reclassifies the
CENSUS; it releases nothing. The one organ that did probe walled seats
was deleted (fleet-ops#2394) after a 14-day 100% failure on stale
test__ fixtures. So a seat whose wall expired lingered walled until a
worker happened to re-pick it — the "comeback path may never fire at
all rather than merely being late" the issue names.

## The fix — bin/fleet-seat-comeback-release (new organ, 15-min timer)

The ACTIVE release path. On a wall clock (bench_until ?? usable_at)
passing, it sends a 1-token "Reply with exactly: OK" probe through the
real router (`pi --print --provider P --model M`, the same dispatch
seat-health.ts classifies):

- probe success (exit 0 + non-empty output with OK) -> the seat is
  provably usable: the organ writes the healthy observation ITSELF
  (health_class=healthy, seat_dead=false, count 0, wall clock cleared),
  so the release does not depend on the out-of-repo extension's response
  hook. The healthy write lands in the per-seat ledger ->
  fleet-seat-recovery.path fires -> pi-intake is primed immediately.
- probe failure -> the extension re-anchors usable_at from the real
  response (fresh wall); the seat stays walled until that window passes.
  A corpse reclassification (seat_dead=true / class corpse) is respected
  as terminal (fleet-ops#2327/#2415) and never released.

Excludes the predecessor-killers (fleet-ops#2394): test__ fixtures and
.spawn-bench pseudo-seats are never probed; corpses are never probed.
Per-seat min-probe interval (900s, matches seat-caps.json
walled_comeback.min_probe_interval_s) prevents hammering.

Loud check (the issue's second ask): after the sweep, walled seats
still holding EXPIRED wall clocks with released_this_run=0 (a probe
blocked / extension not re-anchoring / provider unroutable) -> the run
exits 1, writes fleet_seat_comeback_release_stalled=1 and does NOT
update the last-green timestamp. Two new rules back it: the stalled
alert (1h sustained, mirrors FleetSeatComebackOverdue) and the
absent/stale organ-heartbeat alert (2h); registered in
config/fleet-organs.json per fleet-ops#1010.

## Verification

- `bash tests/fleet-seat-comeback-release.test.sh` -> ALL OK (dry-run
  selection, release-unwall, loud-stall exit 1, min-interval skip).
- Hosted from tests/fleet-seat-recovery.test.sh (P14 closure, no
  ci.yml edit needed): `bash tests/fleet-seat-recovery.test.sh` -> OK.
- `bash tests/fleet-organ-heartbeat.test.sh`, `tests/timer-manifest.test.sh`,
  `tests/manifest-shape.test.sh`, `tests/fleet-metrics-export.test.sh`,
  `tests/escalation-coverage-canary.test.sh`, `tests/seat-lib.test.sh`,
  `tests/opus-heartbeat-seat-comeback.test.sh` -> all pass.
- `promtool check rules config/fleet_rules.yml` -> SUCCESS (53 rules).

run-proof: journal (systemctl --user, 2026-08-30, first live tick; the
timer fired and RELEASED a real seat whose wall had just expired):

```
Aug 31 00:38:05 netcup-rs2000 bash[2450650]: probing commandcode/poolside/laguna-s-2.1-free (wall passed — 1-token reply-OK probe)
Aug 31 00:38:18 netcup-rs2000 bash[2450650]: probe commandcode/poolside/laguna-s-2.1-free SUCCEEDED — releasing
Aug 31 00:38:18 netcup-rs2000 bash[2450650]: UNWALLED commandcode/poolside/laguna-s-2.1-free (healthy observation written)
Aug 31 00:38:19 netcup-rs2000 bash[2450650]: sweep complete: probed=1 released=1 expired_after=0 (cumulative released_total=1)
Aug 31 00:38:19 netcup-rs2000 systemd[1038]: Finished fleet-seat-comeback-release.service
```

Ledger after the run (the released seat now healthy, wall cleared):
`/home/nish/workspaces/agent-state/lanes/seats/commandcode__poolside_laguna-s-2.1-free.json` ->
health_class=healthy, usable_at=null, bench_until=null,
consecutive_failure_count=0, source=comeback_release. fleet-seat-recovery
state flipped to "usable" on the same write. `fleet_seat_comeback_release_released_total 1`
in /var/lib/prometheus/node-exporter/fleet-seat-comeback-release.prom.

research: last30days pass (live search marker: the fleet's own 30-day seat-wall history — git log + issues #1348 original probe organ, #2394 its deletion, #2407 passive census release, #2152 gather comeback arithmetic, #2327/#2415 corpse terminal semantics) — compared options: (a) rebuild seat-walled-probe (rejected: it probed test__ fixtures "Unknown provider test", 14-day 100% fail, never wrote the unwall itself, filed agent-ready issues outside scope); (b) keep only the #2407 metric reclassification (rejected: that is exactly what stayed at released_n=0); (c) NEW active release organ (adopted: re-probe + self-write the unwall so release does not depend on the extension hook, plus the stalled loud check, with the predecessor-killers excluded — the smallest change that makes released_n > 0 real).

help-first: ran `pi --help` — pi has no built-in seat-probe/release command
(only --print non-interactive dispatch, which the seat-health extension
already classifies on after_provider_response), so the 1-token reply-OK
probe is composed here rather than reusing a nonexistent flag. Also read
the deleted seat-walled-probe (git show a5e6994^:bin/seat-walled-probe):
its probe invocation is the shape re-adopted; its fixture-bug is excluded.

Closes #2421