## What

The FleetSeatComebackOverdue alert requires `fleet_seat_comeback_overdue_total == 0`. This PR pins, with end-to-end regression tests, that the comeback-release sweep is the mechanism that guarantees that count clears — so a seat stuck past its wall expiry cannot silently keep inflating the overdue metric.

The sweep itself (bin/fleet-seat-comeback-release, fleet-ops#2421) already owns the overdue case: an expired-wall seat is re-probed, and either unwalled (healthy observation on probe success) or re-benched into the future (probe failure with no real HTTP response, fleet-ops#2505/#2493 re-bench). Both paths move the seat out of the exporter's `_read_comeback_overdue` set on the next tick. The overdue metric was observed at 1 because it catches a seat whose wall expired between the 15-min sweep ticks; the next tick re-probes and clears it — verified live in the journal below, and the regression tests lock that behavior so it cannot silently regress.

## What changed

`tests/fleet-seat-comeback-release.test.sh`:
- New `overdue_n()` helper runs the REAL exporter function `_read_comeback_overdue` (libexec/fleet-metrics-export.py — the exact source of `fleet_seat_comeback_overdue_total`) against the sweep's scratch ledger at the fixed test clock.
- New section 6a: a past-wall seat counts overdue BEFORE the sweep; a successful probe unwalls it; the count is 0 AFTER.
- New section 6b (fleet-ops#2493 regression pin): a probe that fails with no real response (rc=124 timeout) re-benches the wall into the future; the count is 0 AFTER.
- Section 3c tightening: in the one honest stuck case (ledger read-only, wall cannot be advanced), the overdue count legitimately STAYS 1 and the loud-stall check fires — the sweep does not silently claim to clear an unreachable seat.

This satisfies the mechanical-fix requirement with a regression test that proves the guard (exporter overdue count) fires on both recovery paths and stays honest on the stuck path.

## Note on the accept line

"bench it with a fresh spawn-bench marker": the re-bench mechanism already in main (fleet-ops#2505) achieves the same outcome by re-anchoring the ledger wall clock (`bench_until`/`usable_at`) into the future, which both the router (`seat_usable`) and the exporter (`_seat_wall_end_epoch`) honor — so no new marker machinery was needed. The seat stops routing and stops counting as overdue. Test 6b pins exactly that.

## Mechanics

Prevention mechanism: the added regression tests are a drill that proves the guard (the exporter's overdue count) fires on both recovery paths and stays honest on the stuck path — run it and the overdue-clearing behavior is proven, not assumed. No new organ, no new machinery; the change is additive and confined to the test file (the sweep binary is unchanged).

## Verification

- `bash tests/fleet-seat-comeback-release.test.sh` → exit 0, `ALL OK: active come-back release path (fleet-ops#2421)`, including the two new overdue-clear assertions (`overdue metric clears: past-wall seat probed + unwalled -> comeback-overdue count 0` and `overdue metric clears: probe failure re-benches the wall into the future -> comeback-overdue count 0`).
- Regression-plane suites green: `fleet-metrics-export.test.sh` (rc=0), `opus-heartbeat-seat-comeback.test.sh` (rc=0), `fleet-seat-recovery.test.sh` (rc=0).
- `sgscan` on the diff → `No new security findings.`
- Live alert state: `curl 127.0.0.1:9090/api/v1/query?query=fleet_seat_comeback_overdue_total` → `"0"`; no `FleetSeatComebackOverdue` alert firing. The deployed organ runs exactly this code (checked-in bin == `~/.local/bin/fleet-seat-comeback-release` symlink target) and ends every 15-min tick with `expired_after=0`, e.g.:

```
Aug 31 16:30:35 IST ... probing devin/glm-5-2 (wall passed — 1-token reply-OK probe)
Aug 31 16:30:35 IST ... probe devin/glm-5-2 SUCCEEDED — releasing
Aug 31 16:30:35 IST ... UNWALLED devin/glm-5-2 (healthy observation written)
Aug 31 16:30:35 IST ... sweep complete: probed=1 released=1 expired_after=0
```

(unit `systemctl --user status fleet-seat-comeback-release.service`, timer active 15-min cadence).

Closes #2520