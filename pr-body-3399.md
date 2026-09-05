## What changed and why

This closes heartbeat #3399 (FleetMainRed / main CI "red").

The genuinely failing main run behind the incident (seat-floor P14 contract
mismatch, #3428) was already repaired on main by the normal PR cycle. But the
live exporter gauge still reported `fleet_main_ci_green{Nishfleet/fleet-ops} 0`
and FleetMainRed stayed firing even on a proven-green trunk. This PR fixes the
proximate cause that kept the false-red alive.

`_gh_latest_ci_verdict` in `libexec/fleet-metrics-export.py` resolves a
PENDING statusCheckRollup (a fresh CI run in flight) by falling back to the
latest completed CI run. It counted a `cancelled` run as a red verdict
(returned 0). A `cancelled` run is a superseded/abandoned run — a newer push
replaced it, or auto-revert / stop-the-line cancelled it while a fresh run was
queued — it is not a failed trunk. So whenever main's rollup was PENDING and a
cancelled run sat in the recent window, the fallback emitted
`fleet_main_ci_green{...} 0` and FleetMainRed fired even though the true latest
completed verdict was green.

Fix: treat `cancelled` like `skipped`/`neutral` — it is not a verdict, so the
scan keeps walking to the genuine success/failure run. This both stops the
false red and still catches a real `failure` behind the cancelled runs.

## Mechanical-fix (fleet-ops#366)

Class: the main-green exporter treats a non-verdict (`cancelled`) run as a red
verdict, emitting a false `fleet_main_ci_green 0` and firing FleetMainRed on a
green trunk whenever a fresh push's rollup is PENDING.

Prevention mechanism shipped here: a regression test
(`tests/fleet-metrics-export.test.sh`, section 12) that pins the contract —
`cancelled` runs never resolve to a red verdict, a genuine `failure` still
resolves red behind them, and a window of only non-verdict runs omits rather
than emits a false 0. The P14 CI job (which runs `fleet-metrics-export.test.sh`)
now guards this class.

## Verification

Live run of the shipped function against current GitHub state (`gh run list` on
Nishfleet/fleet-ops main, in_progress HEAD + two superseded cancelled runs +
a genuine green run):

```
python3 - libexec/fleet-metrics-export.py <<'PY'
... m._gh_latest_ci_verdict("Nishfleet/fleet-ops","main")
PY
fleet-ops PENDING-fallback verdict (fixed): 1   (was 0 pre-fix)
```

Before the fix the same call resolved 0 (red); after the fix it resolves
1 (green) — the exporter now reports main green while the fresh run is still in
flight, matching the actual trunk state.

Run cue (regression + syntax):

```
bash tests/fleet-metrics-export.test.sh   # full suite green, incl. new section 12
python3 -m py_compile libexec/fleet-metrics-export.py   # OK
shellcheck tests/fleet-metrics-export.test.sh           # OK
sgscan --base origin/main                                # no new findings
```

run-proof: `fleet-metrics-export.test.sh` and `py_compile`/`shellcheck` exit 0
above; the exporter logic is exercised live against real `gh run list` output
and returns 1 (green) for Nishfleet/fleet-ops during the PENDING-window that
previously produced a false 0.

net-positive-because: removes a false-red class that repeatedly surfaced as
FleetMainRed incidents on an actually-green trunk; net +66/-3 lines, one logic
correction plus one regression test, no organ metric or rule churn.

Closes #3399
