# fleet-ops#3584 — fleet-ops main CI red (FleetMainRed firing): verification record

Snapshot at issue creation: 2026-09-05T10:30:01Z heartbeat reported
`fleet_main_ci_green{Nishfleet/fleet-ops}=0`; FleetMainRed pending since
2026-09-05T10:20:56Z (value 0), FleetSloMainGreenSlowBurn pending since
10:23:03Z. All 8 other enrolled repos remained green.

## Root cause (verified live)

The red was a false positive on a green trunk. `_gh_latest_ci_verdict` in
`libexec/fleet-metrics-export.py` resolves a PENDING statusCheckRollup (a
fresh CI run in flight) by falling back to the latest completed CI run on
the default branch. It counted a `cancelled` run as a red verdict
(returned 0). A `cancelled` run is a superseded/abandoned run — a newer
push replaced it, or auto-revert / stop-the-line cancelled it while a
fresh run was queued — it is not a failed trunk.

In the firing window this is exactly what the run history shows: CI runs
`33959961153` (10:11:06Z) and `33960086209` (10:13:54Z) on 2026-09-05
completed `cancelled` while a fresh push's rollup was PENDING, with a
genuine green run (`33960111982`, success at 10:14:28Z) interleaved. The
fallback hit a cancelled run, emitted `fleet_main_ci_green 0`, and
FleetMainRed fired even though the true latest completed verdict was
green. This made the alert flap all day on 2026-09-05/06 (10 cycles in
`chains.terminated.jsonl`; the 02:06Z dispatch on 09-06 still fired on a
proven-green trunk).

## Repair already landed (not shipped here)

The fix is #3827 (`fix(fleet-metrics): cancelled CI runs are not a red
verdict — stop false FleetMainRed flapping on a green trunk`), merged
2026-09-06T03:48:59Z. It treats `cancelled` like `skipped`/`neutral` —
not a verdict — so the scan keeps walking to the genuine success/failure
run. It ships a regression test (`tests/fleet-metrics-export.test.sh`,
section 12) pinning the contract: `cancelled` runs never resolve to a
red verdict, a genuine `failure` still resolves red behind them, and a
window of only non-verdict runs omits rather than emits a false 0. The
P14 CI job (which runs `fleet-metrics-export.test.sh`) now guards this
class. No further code/config change is required.

## Verification (fresh dispatch, not a rerun)

Current main HEAD `45cbfa69ce` carries a brand-new **push-triggered** CI
run — **`34011541022`** (created 2026-09-06T04:27:19Z via push; a rerun
would pin the old workflow SHA) — all 5 jobs SUCCESS (systemd-analyze,
P14 tests/PR checks 13m38s, Gitleaks, Shellcheck, Semgrep). Live exporter
gauge (timer-refreshed): `fleet_main_ci_green{repo="Nishfleet/fleet-ops"}
1`; no alert with `repo="Nishfleet/fleet-ops"` present in
`/api/v1/alerts`. Live exporter call
`_gh_latest_ci_verdict('Nishfleet/fleet-ops','main')` returns `1`.

run-proof: `gh run view 34011541022 -R Nishfleet/fleet-ops` (push,
conclusion success, all 5 jobs success);
`curl -s http://localhost:9090/api/v1/query?query=fleet_main_ci_green`
(`Nishfleet/fleet-ops 1`); `/api/v1/alerts` shows no fleet-ops alert.

## Mechanical-fix

Class: "the main-green exporter treats a non-verdict (`cancelled`) run as
a red verdict, emitting a false `fleet_main_ci_green 0` and firing
FleetMainRed on a green trunk whenever a fresh push's rollup is PENDING."

Prevention mechanism shipped by #3827 (already merged): the regression
test in `tests/fleet-metrics-export.test.sh` section 12 pins the
contract, and the P14 CI job guards it. No new code is shipped here —
this PR records the verification only.
