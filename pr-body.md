fix(waste): class a SUCCESS-no-ship run as `empty-success` (verdict line + seat ledger), count the fleet-ops issue treadmill (fleet-ops#4457)

## Summary

Blind spot (24h population): 127 sessions logged `SUCCESS on <seat>` but only 62 shipped. **51% of "successes" shipped nothing**, and nothing counted them — the judge only reads shipped/24h and sessions-to-PR. Separate but related: workers filed 142 fleet-ops issues/day against a control-plane treadmill that is invisible because only merges are counted.

This makes the waste visible on existing rails (no new organis):

1. **`bin/pi-issue-run` — `empty-success` class.** In the SUCCESS path, a run that produces real output but opens **no PR** and closes **no issue** (the existing `_shipped=no` branch that kept the reclaim-count tall) is now classed `empty-success`: a `PACKET-VERDICT class=empty-success seat=<prov>/<model> output_bytes=<n>` line is appended to the `.out` packet, a per-seat counter (`*.empty-success.json`) is written to the seat ledger via a new `mark_seat_empty_success` in `lib/seat-lib.sh`, and the seat_log line carries the class. It is **NOT** benched (the seat produced real text — not a seat fault) and the exit code stays 0 (a real-output success), so the claim-loop cap (`reclaim-count` not reset, fleet-ops#2462/#2772) still protects the queue. The literal `class=empty-success` is the accept-criterion token.

2. **`measure.sh` (live out-of-repo: `agent-state/fleet-landing-watch/measure.sh`)** — now prints every run:
   - `waste: empty-success=<n>/<sessions> tiny-output=<n> top3-empty-success-seats=[...] pct=<p>%`
   - `fleet-ops issues filed by workers 24h=<n> closed=<n> ... product ready pool=0509:<m>`
3. **`fable-check.md` (the hourly judge packet, live out-of-repo)** — section 1a instructs the judge: `pct` above 40% two runs in a row = FAULT line (name the top-3 seats); the treadmill is named THE limiter when filed > 100/day while product ready pool < 20. Do not loosen the fleet-ops throttle to relieve it — fix product supply.

Items 2-3 are live edits to the judge's own measurement script/packet (not tracked by any repo), so they do not appear in this merged diff — this PR ships the durable detector/test (items 1+4); the live files are updated in place with `.bak-4457-<ts>` backups, per the established cross-project-edit pattern (see prior #4266 PR body).

## Changes

- `bin/pi-issue-run`: SUCCESS-no-ship path now writes `PACKET-VERDICT class=empty-success seat=../.. output_bytes=..` + `mark_seat_empty_success` ledger counter + a `class=empty-success` seat_log line. Reclaim-count still NOT reset.
- `lib/seat-lib.sh`: new `mark_seat_empty_success` (per-seat `*.empty-success.json` counter, best-effort, never blocks the exit-0 success path; not a bench).
- `tests/pi-issue-run-empty-success.test.sh`: fixture — SUCCESS + real output + no PR -> `class=empty-success` in the .out verdict, per-seat counter increments, seat NOT benched, reclaim-count NOT reset; shipped control -> no empty-success class, counter unchanged.
- `tests/seat-lib.test.sh`: hosts the new test (workers cannot push `.github/workflows/**`, so hosting from an already-listed test is the P14-compliant route).

Mechanical-fix (fleet-ops#366): the fixture test + the `class=empty-success` verdict are the detector/test that make the 51% blind spot measurable and gate-able; `mark_seat_empty_success` is the observe-to-close helper.

## Closes

Closes Nishfleet/fleet-ops#4457

## Verification

```
$ bash tests/pi-issue-run-empty-success.test.sh
OK: empty-success: PACKET-VERDICT class=empty-success seat=<np>/<nm> output_bytes=<n> appended to .out
OK: per-seat empty-success counter written to seat ledger (*.empty-success.json, count=1)
OK: empty-success is not benched (no empty_run/spawn-fail ledger) — seat produced real text
OK: reclaim-count NOT reset (claim-loop cap stays tall)
OK: shipped success (control): NOT classed empty-success, counter unchanged
OK: empty-success counter accumulates on the seat (count=2 after two runs)
OK: fleet-ops#4457: SUCCESS-no-PR is classed empty-success (verdict + seat ledger), not benched, shipped control stays clean

$ bash tests/p14-test-listing-gate.test.sh
OK: p14-test-listing-gate.test.sh: P14 test list is closed

$ bash tests/pi-issue-run-noop-bench.test.sh   # existing suite, not regressed
OK: fleet-ops#1378/#3531: in-process no-op retry and remote PR success both work
... (all OK)

$ bash tests/seat-lib.test.sh
passed=33 failed=0

$ bash tests/ci-standards-audit.test.sh
OK: ... (all OK)
```

run-proof: `bin/pi-issue-run` + `lib/seat-lib.sh` + `tests/pi-issue-run-empty-success.test.sh` + `tests/seat-lib.test.sh` (host); `class=empty-success` literal is written by pi-issue-run at runtime and read by the live measure.sh `waste:` line; sgscan clean (no new findings).

## move-safety

- No new organs, timers, or workflows.
- No rebuild/masking (existing files only — no new `bin/` file, so no `research:`/`help-first:` gate is triggered).
- The empty-success path is additive to an existing branch: it never changes exit codes, never benches a seat, never resets the reclaim-count that was already not being reset.
