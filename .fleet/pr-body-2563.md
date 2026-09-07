## fix(seat): cap quota_bench walls at the provider reset horizon

Closes #2563

### Problem

`pi-seat-health` showed `cline/cline-pass/minimax-m3` walled as
`quota_bench` with `usable_at=2026-09-19` — a 19-day bench on a provider whose
`seat-caps.json` row declares `quota_window: "weekly"`. A 19-day wall on a
weekly-resetting seat is not a quota window; it freezes the seat for nearly
three reset cycles.

### Root cause

The 19-day wall was **not** computed from the failure count. The escalating
backoff (`_escalated_backoff`) caps at `SPAWN_FAIL_BACKOFF_CAP_S=1h`, and the
failure-ceiling park needs `consecutive_failure_count >= 20` (live count was
6–10). Nothing in the fleet bounded the wall — the vendor's own `Retry-After`
(1530000s = 17.7 days) was honoured verbatim by the out-of-repo seat-health
extension, which writes `quota_bench` markers straight from the vendor's
response.

### Fix

The bound already exists in config as `quota_window` (loaded into
`SEAT_PROVIDER_QUOTA_WINDOW`, previously read by one consumer). This gives it
a second consumer — the wall ceiling — so no new config key is needed:

- `provider_wall_ceiling_s <provider>` maps `quota_window` to the reset
  horizon in seconds (hourly/daily/weekly/monthly; absent → 0 = no ceiling,
  legacy behaviour).
- `seat_usable` caps an honoured `quota_bench` `bench_until` at
  `observed_at + horizon` (read side — the live marker was written by the
  out-of-repo extension, which the write-side geometric cap cannot reach;
  same fence shape as the fleet-ops#2288 transient_fault park).

The cap is a **re-probe cadence**, not a claim the quota reset: `seat_usable`
fail-opens at the horizon and the probe either works or re-benches for one
more cycle. Cost of being wrong is one failed probe per cycle; cost of
honouring the vendor number is a dead seat for weeks.

### Verification

Ran `tests/seat-wall-reset-horizon.test.sh` (new, offline) — ALL OK:

```
OK: H1 quota_window maps to the reset horizon (hourly/daily/weekly/monthly)
OK: H2 no quota_window -> no ceiling (legacy behaviour preserved)
OK: H3 read side: extension-written 19-day wall held now, released at the horizon
OK: H4 read side: a short bench_until still holds the seat
OK: H5 read side: no quota_window -> long wall honoured verbatim
OK: H6 the cap never widens a wall and is defensive on bad input
ALL OK: seat wall reset-horizon cap (fleet-ops#2563)
```

Also ran `tests/seat-lib-degraded.test.sh` and
`tests/seat-lib-org-reserve.test.sh` — both ALL OK.

`tests/seat-lib.test.sh` fails on `modelcap0` (expected a free lane, got a
cap=0 prepaid model) — this is **pre-existing red-main**, reproduced on
`origin/main` without this change, and out of scope for this issue.

run-proof: `tests/seat-wall-reset-horizon.test.sh` (new, added to
`.github/workflows/ci.yml` unit-verify job) — one real end-to-end run, ALL OK.

net-positive-because: adds the wall-ceiling cap (71 lines in `lib/seat-lib.sh`)
plus a 186-line offline test locking the invariants; the cap is the durable
fix for a seat frozen for three reset cycles and the test is the regression
guard. No new machinery — no new unit/timer/workflow, no new `bin/` file.

research: the fix reuses the already-declared `quota_window` config key as a
second consumer instead of adding a new one; no new `bin/` file, so
`research-before-build-check` does not apply.

help-first: no new `bin/` file, so `--help` does not apply.

organ-heartbeat: `lib/seat-lib.sh` is not an organ; no heartbeat rule change.
