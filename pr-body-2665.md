## What

Verification record for the 2026-09-01 FleetMainRed incident (trunk red 13:05Z -> 17:11Z, two windows). The red is already resolved by fix-forward PRs #2669 and #2693; this PR records the chain, proves main green with a fresh run on the current head, and files the out-of-scope defect discovered while tracing (broken action pins in two scheduled alert workflows).

## Root cause (verified live)

Two distinct main-CI red windows, both P14 test failures, both fixed forward:

1. Window 1 (12:55Z -> 14:43Z): PR #2655 (`449c318d`) added
   `tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh` and
   `tests/fleet-escalation-completion-orphan-sweep.test.sh` outside the P14
   reachable set -> `p14-test-listing-gate` failed push runs 33510331696 /
   33512839197 / 33519725795 -> FleetMainRed. Fix-forward: #2669
   (`713eff0a`, merged 14:43:21Z) hosted both tests. Main CI green from
   14:51:00Z.
2. Window 2 (16:35Z -> 17:11Z): PR #2685 (`37055948`) seat tool-probe work;
   push run 33531943541 (16:28:05Z, `bf943450`) failed P14 at
   "pong-ok: inline-only probe failure must register 1 overload strike
   (got 0)" — seat-lib.sh never loads on hosted CI without
   `PI_PACKET_SEAT_LIB`, so the strike never registers. Fix-forward: #2693
   (`4756aca4`, merged 17:11:47Z) exported `PI_PACKET_SEAT_LIB` in the test.

"P14 tests / PR checks" is a NON-required check by documented design, so the
auto-merge landed before the P14 verdict and auto-revert correctly halted
(scenario A) with this fix-forward-tracked issue.

## Verification

- Fresh remote run on current main head `9c6de004`: push-triggered CI run
  33566562283 (created 2026-09-01T22:29:34Z, run_attempt=1, conclusion=
  success); all check-runs on the head completed (P14, Shellcheck, Gitleaks,
  Semgrep, systemd-analyze success; auto-revert + mass-close guard skipped)
  -> rollup SUCCESS -> fleet_main_ci_green = 1 (live fleet.prom confirms).
- Local (worktree at `9c6de004`, no local changes):
  `bash tests/p14-test-listing-gate.test.sh` -> all OK (324 test files
  accounted, both previously-orphaned tests now reachable);
  `bash tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh` -> OK;
  `bash tests/fleet-escalation-completion-orphan-sweep.test.sh` -> OK;
  `bash tests/fleet-seat-comeback-release.test.sh` -> ALL OK incl. the
  PONG-ok overload-strike scenario that was red in window 2.

run-proof: fresh push run https://github.com/Nishfleet/fleet-ops/actions/runs/33566562283 conclusion=success on 9c6de004 (event=push, run_attempt=1, not a rerun).

## Mechanical-fix

Class: "a new tests/*.test.sh (or test-env gap) merged outside the P14
reachable set / hosted-CI seat-lib context turns main red until a fix lands".
Mechanisms that fired: p14-test-listing-gate (detector, caught both window-1
orphans by basename), auto-revert scenario A (halts + tracks the fix), and
the PI_PACKET_SEAT_LIB pin now carried by the seat-comeback-release test
(regression-fails the same gate if the load path drops).
mechanism-impossible: binding "P14 tests / PR checks" as a required check —
the only change that stops a P14-red merge at merge time — is
branch-protection config under Administration scope; the worker app token is
403 there and workers are platform-rejected from `.github/workflows/**`
edits. P14 non-required is the fleet's documented design.

## Out-of-scope finding (filed as a new issue)

`.github/workflows/ci-failure-escalation.yml` pins checkout
`3d3d42e5...` (one char off the canonical `3d3c42e5...`); every run of the
CI failure escalation bridge fails with "Unable to resolve action" (root
cause of never-green #719). `.github/workflows/ci-standards-audit.yml`
carries two equally invalid pins (checkout `3d3c42e5...10b18...`,
upload-artifact `507de32f...`) — root cause of never-green #1626. Filed as a
new issue #2735 (plain, no labels); the fix touches `.github/workflows/**`,
which workers cannot push.

Closes #2665