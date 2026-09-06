# fleet-ops#3779 — main CI red on fleet-ops (FleetMainRed critical since 2026-09-05T23:15Z): verification record

Snapshot at issue creation: 2026-09-06T00:30:10Z —
`fleet_main_ci_green{Nishfleet/fleet-ops}=0`, all 8 other enrolled repos
green. This is the SAME 2026-09-05T23:15:56Z FleetMainRed firing that
already-filed #3748 tracked; #3779 was filed ~1 hour later, once the
`for: 30m` window elapsed and the alert escalated from pending to
critical.

## Root cause (verified live, identical to #3748)

A genuine P14 test-listing gate failure. PR #3740
(`feat(waste-cut): reusable close-and-archive-repo tool for dead repos`,
commit `385ac2e8`, merged 2026-09-05T22:50:42Z) added
`tests/fleet-close-and-archive-repo.test.sh` to the tree but did NOT list
it in `.github/workflows/ci.yml`'s P14 reachable set. The P14 listing
gate (`p14-test-listing-gate`) failed on the next push run and turned
main red. The worker token has no workflow scope, so the worker that
landed #3740 could not edit `ci.yml` itself.

## Repair already landed (not shipped here)

The fix is #3765 (`ci(p14): list tests/fleet-close-and-archive-repo.test.sh
— main red since #3740`, commit `4063c127`, merged 2026-09-05T23:58:27Z —
28 minutes after #3748's snapshot and well before #3779 was filed). It
lists the test in `ci.yml` with a citation comment. Main CI went green
from the next push and has stayed green since.

#3748's verification record
(`reports/main-ci-red-incident-3748-2026-09-06.md`) documents this
exact incident and its fix. #3779 is a duplicate alert for the same
firing; the repair and prevention were already in place when #3779 was
filed.

## Verification (fresh dispatch, not a rerun)

The alert input is the point-in-time Prometheus metric:
`fleet_main_ci_green{repo="Nishfleet/fleet-ops"}` = `1` (green) at
dispatch, and all 9 enrolled repos = 1. The FleetMainRed rule
(`expr: fleet_main_ci_green == 0`, `for: 30m`) is therefore not firing.

A confirmed-green **push-triggered** CI run on main — **`34050935200`**
(created 2026-09-06T18:11:45Z via push on commit `7b784862`, an ancestor
of the then-current main HEAD; a rerun would pin the old workflow SHA) —
completed with all 5 jobs SUCCESS (systemd-analyze, P14 tests/PR checks,
Gitleaks, Shellcheck, Semgrep). (Later pushes while this record was being
written were auto-superseded — P14 job cancelled by the next push — their
non-P14 jobs all SUCCESS; the metric stayed `1` throughout.)

Local proof (worktree on `claim/issue-3779`, rebased on current main +
the report file added by this PR):
- `bash tests/fleet-close-and-archive-repo.test.sh` — ALL 5 SCENARIO
  CHECKS PASSED (exit 0).
- `bash tests/repo-standards.test.sh` — 5 passed, 0 failed (exit 0).

run-proof: `gh run view 34050935200 -R Nishfleet/fleet-ops` (push,
conclusion success, all 5 jobs success); `bash tests/fleet-close-and
-archive-repo.test.sh` (exit 0); `bash tests/repo-standards.test.sh`
(exit 0); Prometheus `fleet_main_ci_green{repo="Nishfleet/fleet-ops"}`
= 1.

## Mechanical-fix

Prevention for this failure class already exists and is proven:
- The `p14-test-listing-gate` (P14 CI job) rejects any test file neither
  listed in `ci.yml`, nor hosted by a listed test, nor live/destructive,
  nor a known orphan — it is what surfaced #3740's omission on the next
  push.
- The red-on-main resolver (`bde3dbf8`, #3711) auto-closes `red-on-main`
  labelled alert issues once the workflow's latest completed main run is
  green.

#3765 closed the gap (added the missing `ci.yml` entry); the alert has
ceased because main is green. No new code/gate is shipped here — this PR
records the verification and closes the residual manually-filed alert
#3779 so it stops polluting the agent-ready queue.
