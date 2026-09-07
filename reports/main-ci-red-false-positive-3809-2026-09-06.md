# fleet-ops#3809 — fleet-ops main CI red (FleetMainRed firing): verification record

Snapshot at issue creation: the 2026-09-06T02:30:19Z heartbeat reported
`fleet_main_ci_green{Nishfleet/fleet-ops}=0` and a critical FleetMainRed
firing with `activeAt` 2026-09-06T01:35:56Z `value 0`,
FleetSloMainGreenSlowBurn firing since 01:38:03Z. All 8 other enrolled
repos stayed green.

## Root cause (verified live)

The red was a false positive on a green trunk — the same class as the
fleet-ops#3584 (record #3837) and #3626 (record #3975) incidents.
`_gh_latest_ci_verdict` in `libexec/fleet-metrics-export.py` resolves a
PENDING statusCheckRollup (a fresh CI run in flight) by falling back to
the latest completed CI run on the default branch. Before #3827 it
treated a `cancelled` run as a red verdict (returned 0). A `cancelled`
run is a superseded/abandoned run — a newer push replaced it, or
auto-revert / stop-the-line cancelled it while a fresh run was queued —
it is not a failed trunk.

In the firing window this is exactly what the run history shows. CI run
`34004256261` (push 2026-09-06T01:34:39Z) completed `cancelled`: its P14
job (`P14 tests / PR checks`) was cancelled mid-run by a higher-priority
run for a newer push (`fix(seat-lib): empty-run spawn-bench marker write
is required, not be…`). Its non-P14 jobs succeeded. Adjacent runs
`34004426491` and `34003752099` also completed `cancelled`, while genuine
green runs `34004547736` (success at 01:41:34Z) and later runs
concluded success. At the 01:35:56Z snapshot the cancelled-run fallback
emitted `fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 0` and
FleetMainRed fired even though the true latest completed verdict was
green.

The same window had a plausible-looking but unrelated candidate: one P14
job on `ci-refs/heads/main` was `cancelled` (not failed). No
`fleet-seat-recovery.test.sh` or `fleet-seat-comeback-release.test.sh`
assertion failed anywhere — a probe of the flagged run's log shows the
verification command was interrupted by cancellation, not by a FAIL line.
The exporter's `SEAT_CAPS_JSON` handling was a red herring: the test
passes on unfixed main, and origin/main has since merged #4047
(`SEAT_CAPS_LIVE`, fleet-ops#3811) which already honors `SEAT_CAPS_JSON`.

## Repair already landed (not shipped here)

The fix is #3827 (`fix(fleet-metrics): cancelled CI runs are not a red
verdict — stop false FleetMainRed flapping on a green trunk`), merged
2026-09-06T03:48:59Z (commit `48cd5aaa`, present on current main). It
treats `cancelled` like `skipped`/`neutral` — not a verdict — so the scan
keeps walking to the genuine success/failure run. It ships a regression
test (`tests/fleet-metrics-export.test.sh` section 12) pinning the
contract, and the P14 CI job guards this class. No further code or
config change is required.

## Verification

Current main sits on a green trunk. Confirmed-green push-triggered CI
run `34052776390` (docs verification record for #3779, `#4043`,
2026-09-06T18:46:23Z) concluded success with all six jobs SUCCESS
(Semgrep, CI checklist gate, Gitleaks, Shellcheck, systemd-analyze, P14
tests / PR checks). Later pushes were auto-superseded (P14 cancelled by
the next push — the exact condition #3827 handles) while the metric
stayed green. Live exporter gauge (timer-refreshed):
`fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`. No alert with
`repo="Nishfleet/fleet-ops"` is firing in `/api/v1/alerts`.

run-proof: `gh run view 34052776390 -R Nishfleet/fleet-ops` (push,
conclusion success, all 6 jobs success);
`curl 'http://localhost:9090/api/v1/query?query=fleet_main_ci_green'`
(`Nishfleet/fleet-ops 1`);
`curl 'http://localhost:9090/api/v1/alerts'` (no fleet-ops firing
alert); local worktree: `bash tests/fleet-seat-recovery.test.sh` (ALL
OK, exit 0) and `bash tests/fleet-metrics-export.test.sh` (section 12,
`cancelled CI runs are not a red verdict`, PASS) on the unfixed main.

## Mechanical-fix

Class: "the main-green exporter treats a non-verdict (`cancelled`) run
as a red verdict, emitting a false `fleet_main_ci_green 0` and firing
FleetMainRed on a green trunk whenever a fresh push's rollup is PENDING."

Prevention mechanism shipped by #3827 (already merged): the regression
test in `tests/fleet-metrics-export.test.sh` section 12 pins the
contract, and the P14 CI job guards it. No new code is shipped here.

## What this PR ships

One markdown file only:
`reports/main-ci-red-false-positive-3809-2026-09-06.md` — the
verification record, under `reports/` per convention. No code, no unit,
no timer, no workflow touched.

net-positive-because: the only deliverable left on #3809 is the durable
verification record — the code fix already merged as #3827 (same class
as the #3584 and #3626 records). An earlier code-only attempt at this
issue (#4045) mis-diagnosed the red as a `fleet-seat-recovery` failure
and was withdrawn; this record is the paper that closes it.

organ-heartbeat: reports/main-ci-red-false-positive-3809-2026-09-06.md not-an-organ: markdown verification record

Closes #3809
