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
   `tests/ci-standards-audit.test.sh` (line 324). Main CI green since.

## Fresh-run proof (current head)

- Remote: run 33331499649 on `da10f9950` (current main head, event=push,
  created 2026-08-30T19:39:54Z, conclusion=success) — a fresh run, not a
  rerun (a rerun would pin the old reusable-workflow SHA). All check-runs on
  the head completed: P14 tests, Gitleaks, Semgrep, Shellcheck,
  systemd-analyze all success (auto-revert + mass-close guard skipped) ->
  rollup SUCCESS, so `fleet_main_ci_green` resolves 1.
- Local at `da10f9950` (this worktree, no local changes):
  - `bash tests/p14-test-listing-gate.test.sh` -> OK (previously-orphaned
    `unit-escalation-write-journal-evidence.test.sh` is now in the reachable set).
  - `bash tests/unit-escalation-write-journal-evidence.test.sh` -> OK
    (journal evidence-pinning proven).
  - `bash tests/escalation-units-shape.test.sh` -> OK.

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
  -> 403 Resource not accessible by integration), and workers are
  platform-rejected from `.github/workflows/**` edits. P14 non-required is the
  fleet's documented design (tests/auto-revert-required-check-gate.test.sh);
  flipping it is an admin/design decision with a merge-throughput cost, not a
  worker change.

## Out-of-scope finding (filed, then resolved)

`tests/ci-standards-audit.test.sh` on the VPS failed at
`tests/seat-health-seat-dead.test.sh` D10 (c25-wall: got null, expected
86400) — pre-existing on main, unrelated to #2402: the live
`~/.pi/agent/extensions/seat-health.ts` (hot-patched 2026-08-30T18:21Z for the
open #2415) sets `usable_at=null` for corpse-class seats, and the in-repo
closure test expectation was stale. CI cannot see it (the test skips when the
extension is not installed). Filed as #2422; since resolved by #2425
(`c455587`, fix(seat-health): corpse carries no usable_at retry clock, merged
2026-08-30T19:05Z) — current main's `tests/seat-health-seat-dead.test.sh`
D10 expectation matches the extension's null `usable_at`.