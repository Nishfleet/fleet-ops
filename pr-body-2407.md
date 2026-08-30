## Why

Three seats were still counted walled past their own usable_at at the
2026-08-30T15:45:04Z snapshot (commandcode/minimax/minimax-m3-free,
commandcode/poolside/laguna-s-2.1-free, opencode/ling-3.0-flash-fin-free;
seats_walled=14, healthy=14, excluded=9). The wall-release path only clears
on the NEXT observation — a healthy write reclassifies the ledger, a fresh
failure re-anchors usable_at — so a seat whose wall expired and nothing
re-probed it lingered classed overload_bench/transient_fault as long as the
census and the seat_availability rollup counted by class alone.

The router already releases these seats at now >= usable_at: lib/seat-lib.sh
seat_usable FAIL-OPENS overload_bench / quota_bench / hang_bench /
transient_fault / rate_limited once their wall clock (bench_until ??
usable_at) passes. The reporting side did not know that, so released
capacity kept depressing the census and the SLO until a lucky re-observe.

## Scope

- **libexec/fleet-metrics-export.py**:
  - `_seat_is_released()` — router-mirroring release: a non-dead ledger on a
    fail-open class whose wall clock has passed is RELEASED. quota_exhausted /
    credentials_bad / corpse never release (held until a healthy observation).
  - `_read_comeback_overdue()` — seats still classed non-healthy whose wall
    clock has passed (unobserved since). Excludes .spawn-bench markers,
    test__ fixtures and seat_dead corpses.
  - `_healthy_enrolled_seat_count()` counts a released ledger toward the
    seat_availability rollup (fleet-ops#2377 rollup + release-at-usable_at).
  - main() emits `fleet_seat_comeback_overdue_total` (gauge) and per-seat
    `fleet_seat_comeback_overdue{seat=...,health_class=...}` series.
- **config/fleet_rules.yml**: new `FleetSeatComebackOverdue` alert
  (fleet_seat_comeback_overdue_total > 0, 1h sustained) — the loud backstop
  for seats that linger past their comeback unobserved.
- **opus-heartbeat-gather** (installed organ at
  ~/.local/libexec/opus-heartbeat-gather, NOT repo-tracked — same precedent
  as fleet-ops#2152): seat_table() classifies a seat RELEASED once its wall
  clock passes on the fail-open classes and adds `released` / `released_n` /
  `bench_until` / `wall_end` to the census, so seats_walled reflects only
  actively held walls. quota_exhausted and corpses stay walled.
- **tests/opus-heartbeat-seat-comeback.test.sh**: pins the released
  classification in the installed gather (released_n=2, per-row released
  flags, future-wall quota stays walled).
- **tests/fleet-metrics-export.test.sh**: pins `_seat_is_released`,
  `_read_comeback_overdue` (3 past-wall seats incl. one quota),
  the release-aware rollup (released provider stays in, quota drops out),
  and rule presence in fleet_rules.yml.

## Tradeoffs

- The comeback-overdue gauge counts ANY past-wall non-dead seat, including
  quota_exhausted whose reset window elapsed — a hard billing wall past its
  advertised reset IS an overdue comeback and deserves the loud signal.
- `for: 1h` on the alert keeps the well-behaved loop quiet: the fleet's own
  dispatch re-observes a released seat within minutes (re-wall or healthy
  write), so only seats NOBODY probes for an hour actually page.

## Blast Radius

- Read-side only. Nothing routes differently: seat_usable in seat-lib.sh is
  unchanged; the extension writer is unchanged. This fixes how released
  capacity is COUNTED (census, rollup) and adds the overdue alarm.
- `_healthy_enrolled_seat_count` feeds fleet_slo_seat_availability; released
  seats now restore commandcode to the rollup (live 2026-08-30T16:55Z:
  10/13 -> 11/13). Quota holds and corpses still do not count — no dead seat
  is masked; the comeback-overdue metric + alert keeps them loud.
- Gate-owned paths: none touched.

## Verification

- `bash tests/opus-heartbeat-seat-comeback.test.sh` (against the installed
  gather) → `ALL OK: seat comeback arithmetic fixed` incl. the new
  release-at-usable_at assertions.
- `bash tests/fleet-metrics-export.test.sh` → all OK, incl. promtool check
  rules on the updated fleet_rules.yml and the new #2407 section.
- Live exporter run (module main() against the live ledger, scratch OUT):
  `fleet_seat_comeback_overdue_total 2` +
  `fleet_seat_comeback_overdue{seat="commandcode__minimax/minimax-m3-free",health_class="overload_bench"} 1` +
  `{seat="commandcode__poolside/laguna-s-2.1-free",...} 1` — the two seats
  whose bench_until (16:55:35Z / 16:59:48Z) had passed at run time, router-
  released and unobserved since. Rollup 10/13 (class-only) → 11/13
  (release-aware), restoring commandcode.
- Seat regression suite green (rc=0): seat-lib, slo-budget,
  seat-health-seat-dead, seat-health-classifier, seat-health-quarantine,
  seat-failure-ceiling, seat-lib-aimd, pi-issue-run-noop-bench,
  opus-heartbeat-thorough-mode.
- The three named seats verify per the issue: ling-3.0-flash-fin-free is
  health_class=healthy (observed 16:26:02Z); minimax-m3-free and
  laguna-s-2.1-free were re-walled with fresh observed_at (16:33:02Z /
  16:35:16Z then 16:55:35Z / 16:59:48Z) and when a wall passes before the
  next re-probe the new metric names them instead of the census silently
  over-counting walls.

Closes #2407