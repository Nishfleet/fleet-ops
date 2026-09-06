## Summary

fleet-ops#3626 reported `fleet_main_ci_green{Nishfleet/fleet-ops}=0` at
2026-09-05T12:30Z with FleetMainRed pending. Verification shows this was
a **false positive on a green trunk** — the same root cause as the
fleet-ops#3584 record and fixed by the already-merged #3827.

`_gh_latest_ci_verdict` in `libexec/fleet-metrics-export.py` resolves a
PENDING rollup by falling back to the latest completed CI run, and
counted a `cancelled` run as a red verdict. In the firing window a fresh
push's rollup was PENDING while two cancelled runs sat ahead of the
genuine green run, so the fallback emitted a spurious 0.

The fix (#3827, merged 2026-09-06T03:48:59Z, commit `48cd5aaa`) treats
`cancelled` as a non-verdict and ships regression test
`tests/fleet-metrics-export.test.sh` section 12, guarded by the P14 CI
job. No further code change is required; this PR is the durable
verification record under `reports/`, following the #3584 record
(closed by #3837) precedent.

## Verification

- Current main HEAD `cadd8652` sits on a green trunk: latest completed
  push-triggered CI run `34035447244` (HEAD `476c571f`) concluded
  success; the newest run `34036497431` for `cadd8652` was mid-flight
  (PENDING rollup) at verify time — exactly the case #3827 handles
  without flapping.
- Live exporter gauge (timer-refreshed):
  `fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`.
- No alert with `repo="Nishfleet/fleet-ops"` in `/api/v1/alerts`.
- `./tests/fleet-metrics-export.test.sh` passes section 12
  (`fleet-ops#3558: cancelled CI runs are not a red verdict`).

run-proof: `gh run list -R Nishfleet/fleet-ops --workflow CI --branch
main` (34035447244 success, 34036497431 in_progress);
`curl -s http://localhost:9090/api/v1/query?query=fleet_main_ci_green`
(`Nishfleet/fleet-ops 1`); `/api/v1/alerts` (no fleet-ops alert);
`./tests/fleet-metrics-export.test.sh` (section 12 passes).

## What this PR ships

One markdown file only:
`reports/main-ci-red-false-positive-3626-2026-09-06.md`. No code, no
unit, no timer, no workflow touched.

organ-heartbeat: reports/main-ci-red-false-positive-3626-2026-09-06.md not-an-organ: markdown verification record

Closes #3626
