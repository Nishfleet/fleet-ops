# fleet-ops#3748 — fleet-ops main CI red (FleetMainRed pending 2026-09-05T23:15Z): verification record

Snapshot at issue creation: 2026-09-05T23:30Z heartbeat reported
`fleet_main_ci_green{Nishfleet/fleet-ops}=0`; FleetMainRed pending since
2026-09-05T23:15:56Z. fleet-ops was the only red repo of 9 enrolled.

## Root cause (verified live)

A genuine P14 test-listing gate failure, not a false positive. PR #3740
(`feat(waste-cut): reusable close-and-archive-repo tool for dead repos`,
commit `385ac2e8`, merged 2026-09-05T22:50:42Z) added
`tests/fleet-close-and-archive-repo.test.sh` to the tree but did NOT list
it in `.github/workflows/ci.yml`'s P14 reachable set. The P14 listing
gate (`p14-test-listing-gate`) failed on the next push run
(`33997046369`, created 22:50:42Z) with:

```
FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test,
  live/destructive, nor a known orphan:
  fleet-close-and-archive-repo.test.sh
Add the test to ci.yml (requires workflow scope) or invoke it from a
listed test.
```

The worker token has no workflow scope, so the worker that landed #3740
could not edit `ci.yml` itself; the listing gate caught the omission on
the next push and turned main red.

## Repair already landed (not shipped here)

The fix is #3765 (`ci(p14): list tests/fleet-close-and-archive-repo.test.sh
— main red since #3740`, commit `4063c127`, merged 2026-09-05T23:58:27Z —
28 minutes after the snapshot). It lists the test in `ci.yml` with a
citation comment (`fleet-ops#3740 landed tests/fleet-close-and-archive-repo
.test.sh without a ci.yml entry, so the P14 listing gate went red on main
and blocked every PR (orchestrator fix, 2026-09-06). Drill: 5 scenarios,
stubbed gh.`). Main CI went green from the next push and has stayed green
since (17+ hours of green runs through current HEAD `085f0a2c`).

The prevention mechanism is the P14 listing gate itself: any new test
file not reachable from `ci.yml` (and not live/destructive/known-orphan)
turns main red on the next push. #3765 added the missing entry; no
further code/config change is required.

## Verification (fresh dispatch, not a rerun)

Current main HEAD `085f0a2c` carries a brand-new **push-triggered** CI
run — **`34045967217`** (created 2026-09-06T16:36:01Z via push; a rerun
would pin the old workflow SHA) — all 5 jobs SUCCESS (Shellcheck,
Gitleaks, Semgrep, systemd-analyze, P14 tests/PR checks).

Local proof (worktree at `085f0a2c`, no local changes before the report
file added by this PR):
- `bash tests/fleet-close-and-archive-repo.test.sh` — ALL 5 SCENARIO
  CHECKS PASSED (exit 0).
- `bash tests/repo-standards.test.sh` — 5 passed, 0 failed (exit 0);
  includes the stray-worker-notes guard added by #3693.

run-proof: `gh run view 34045967217 -R Nishfleet/fleet-ops` (push,
conclusion success, all 5 jobs success); `bash tests/fleet-close-and
-archive-repo.test.sh` (exit 0); `bash tests/repo-standards.test.sh`
(exit 0).

## Mechanical-fix

Class: "a worker PR adds a new test file under `tests/` but cannot list
it in `ci.yml` (no workflow scope), so the P14 test-listing gate turns
main red on the next push."

Prevention mechanism already in place: the `p14-test-listing-gate` (run
by the P14 CI job) rejects any test file neither listed in `ci.yml`, nor
hosted by a listed test, nor live/destructive, nor a known orphan. #3765
added the missing `ci.yml` entry with a citation comment. No new code is
shipped here — this PR records the verification only.
