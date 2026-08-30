# Verification for issue #2402

## Issue

fleet-ops main CI red (FleetMainRed pending 2026-08-30T15:05Z). Monitoring
snapshot 2026-08-30T15:30:10Z showed
`fleet_main_ci_green["Nishfleet/fleet-ops"]=0`, all 8 other enrolled repos
green. Directive: find the failing run on main, identify the breaking commit,
fix forward or revert, and prove main green with a fresh run.

## Root cause chain (each step verified live)

1. Breaking commit: `35964e8` (PR #2399, feat(enforcement): pin journal
   evidence into STOP-REASON) added `tests/unit-escalation-write-journal-evidence.test.sh`
   with no ci.yml listing, no host from a listed test, no live/destructive
   tag, and no known-orphan entry.
2. The `p14-test-listing-gate` (hosted from `tests/ci-standards-audit.test.sh`)
   failed main's push run 33317457363 with the orphan FAIL. Main turned red
   ~15:05Z; FleetMainRed and FleetSloMainGreenSlowBurn fired (this issue).
3. "P14 tests / PR checks" is a NON-required check by documented design
   (`tests/auto-revert-required-check-gate.test.sh` scenario A). PR #2399's
   auto-merge (armed 14:38:22Z) landed 14:39:12Z before the P14 verdict
   (14:45:10Z, failure). The fleet deliberately accepts a P14-red merge and
   fixes forward.
4. Auto-revert for `35964e8` ran 14:45:10Z (workflow success) but correctly
   halted with this fix-forward-tracked issue (scenario A: only the
   non-required P14 check failed) instead of reverting.
5. Fix-forward: PR #2406 (`b7e19b5`, merged 15:40:33Z) hosted the orphan from
   `tests/ci-standards-audit.test.sh` (line 324). Main CI green since; current
   head `dc2c566` fresh push run 33326410637 = success.

## Fresh-run proof

- Remote: run 33326410637 on `dc2c566` (event=push, created 17:51:14Z,
  completed 17:58:30Z, conclusion=success) — a fresh run, not a rerun (a
  rerun would pin the old reusable-workflow SHA). All 9 check-runs on the head
  completed: 7 success, 2 skipped (auto-revert, mass-close guard) -> rollup
  SUCCESS, so `fleet_main_ci_green` resolves 1.
- Local at `dc2c566` (this worktree, no local changes):
  - `bash tests/p14-test-listing-gate.test.sh` -> all OK (311 files accounted
    for; the previously-orphaned test is now in the reachable set).
  - `bash tests/unit-escalation-write-journal-evidence.test.sh` -> OK
    (journal evidence-pinning proven).
  - `bash tests/manifest-shape.test.sh`, `bash tests/intake-repos-shape.test.sh`,
    `bash tests/escalation-units-shape.test.sh` -> all OK.

## Prevention (mechanical-fix for the failure class)

Class: a new `tests/*.test.sh` merged outside the P14 reachable set turns main
CI red until a fix-forward lands.

- Existing mechanisms that FIRED in this incident:
  1. `p14-test-listing-gate` (tests/p14-test-listing-gate.test.sh, hosted in
     tests/ci-standards-audit.test.sh) detects the orphan and fails the P14
     suite with the basename — it caught `unit-escalation-write-journal-evidence.test.sh`
     exactly.
  2. Auto-revert scenario A auto-files the halt issue (this issue), so the
     break is tracked, never silent, and is fixed forward (#2406).
- `mechanism-impossible`: binding "P14 tests / PR checks" as a REQUIRED status
  check — the only change that would stop a P14-red merge at merge time — is
  branch-protection config under Administration scope. The nishfleet-worker
  app token is 403 on branch-protection read/write (verified:
  GET /repos/Nishfleet/fleet-ops/branches/main/protection/required_status_checks
  -> 403 Resource not accessible by integration; bin/fleet-escalation-canary
  documents the same), and workers are platform-rejected from
  `.github/workflows/**` edits. P14 non-required is the fleet's documented
  design (tests/auto-revert-required-check-gate.test.sh); flipping it is an
  admin/design decision with a merge-throughput cost, not a worker change.

## Out-of-scope finding filed separately

`tests/ci-standards-audit.test.sh` on the VPS fails at
`tests/seat-health-seat-dead.test.sh` D10 (c25-wall: got null, expected
86400). Pre-existing on current main, unrelated to #2402: the live
`~/.pi/agent/extensions/seat-health.ts` (hot-patched 2026-08-30T18:21Z for
the open #2415) now deliberately sets `usable_at=null` for corpse-class
seats, and the in-repo closure test expectation is stale. CI cannot see it
(the test skips when the extension is not installed). Filed as its own issue.