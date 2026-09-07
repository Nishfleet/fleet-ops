# fleet-ops#3626 — fleet-ops main CI red (FleetMainRed firing): verification record

Snapshot at issue creation: 2026-09-05T12:30Z heartbeat reported
`fleet_main_ci_green{Nishfleet/fleet-ops}=0` (was green at 11:30Z);
FleetMainRed pending critical since 12:05:56Z;
FleetSloMainGreenSlowBurn pending. All other enrolled repos remained
green.

## Root cause (verified live)

The red was a false positive on a green trunk — the same class as
fleet-ops#3584. `_gh_latest_ci_verdict` in
`libexec/fleet-metrics-export.py` resolves a PENDING statusCheckRollup (a
fresh CI run in flight) by falling back to the latest completed CI run on
the default branch. It counted a `cancelled` run as a red verdict
(returned 0). A `cancelled` run is a superseded/abandoned run — a newer
push replaced it, or auto-revert / stop-the-line cancelled it while a
fresh run was queued — it is not a failed trunk.

In the firing window this is exactly what the run history shows. CI runs
`33964591314` (11:54:54Z) and `33964949374` (12:02:58Z) on 2026-09-05
completed `cancelled` while a fresh push's rollup was PENDING, with
genuine green runs `33963580258` (success at 11:31:59Z) before and
`33965369193` (success at 12:12:07Z) after. At the snapshot time the
fallback hit the most recent completed run (`33964949374`, cancelled),
emitted `fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 0`, and
FleetMainRed fired even though the true latest completed verdict was
green.

## Repair already landed (not shipped here)

The fix is #3827 (`fix(fleet-metrics): cancelled CI runs are not a red
verdict — stop false FleetMainRed flapping on a green trunk`), merged
2026-09-06T03:48:59Z (commit `48cd5aaa`, present on current main). It
treats `cancelled` like `skipped`/`neutral` — not a verdict — so the scan
keeps walking to the genuine success/failure run. It ships a regression
test (`tests/fleet-metrics-export.test.sh`, section 12) pinning the
contract, and the P14 CI job (which runs `fleet-metrics-export.test.sh`)
guards this class. No further code/config change is required.

## Verification

The section-12 regression test passes on current main
(`fleet-ops#3558: cancelled CI runs are not a red verdict`) — run on
2026-09-06 from this PR's base. Current main HEAD `cadd8652` sits on a
green trunk: the latest completed push-triggered CI run `34035447244`
(HEAD `476c571f`, the commit just before `cadd8652`) concluded success;
the newest run `34036497431` for `cadd8652` was mid-flight (PENDING
rollup) at verification time, exactly the situation the fix handles
without flapping. Live exporter gauge (timer-refreshed):
`fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`; no alert with
`repo="Nishfleet/fleet-ops"` present in `/api/v1/alerts`.

run-proof: `gh run list -R Nishfleet/fleet-ops --workflow CI --branch
main` shows `34035447244` concluded success and `34036497431`
`in_progress` for the current HEAD;
`curl -s http://localhost:9090/api/v1/query?query=fleet_main_ci_green`
(`Nishfleet/fleet-ops 1`); `/api/v1/alerts` shows no fleet-ops alert;
`./tests/fleet-metrics-export.test.sh` passes section 12.

## Mechanical-fix

Class: "the main-green exporter treats a non-verdict (`cancelled`) run as
a red verdict, emitting a false `fleet_main_ci_green 0` and firing
FleetMainRed on a green trunk whenever a fresh push's rollup is PENDING."

Prevention mechanism shipped by #3827 (already merged): the regression
test in `tests/fleet-metrics-export.test.sh` section 12 pins the
contract, and the P14 CI job guards it. No new code is shipped here.

## What this PR ships

One markdown file only:
`reports/main-ci-red-false-positive-3626-2026-09-06.md` — the
verification record, under `reports/` per convention. No code, no unit,
no timer, no workflow touched.

net-positive-because: the only deliverable left on #3626 is the durable
verification record — the code fix already merged as #3827 (same class as
the #3584 record, closed by #3837).

organ-heartbeat: reports/main-ci-red-false-positive-3626-2026-09-06.md not-an-organ: markdown verification record

Closes #3626
