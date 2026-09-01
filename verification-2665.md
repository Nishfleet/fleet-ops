# Verification for issue #2665

## Issue

fleet-ops main CI red since 2026-09-01T13:05Z (FleetMainRed). Monitoring
showed `fleet_main_ci_green["Nishfleet/fleet-ops"]=0` at issue creation
(2026-09-01T14:32:01Z), all 8 other enrolled repos green. Directive: find
the failing workflow run on main, fix the root cause, prove main green.

## Root cause chain (each step verified live)

Two distinct main-CI red windows, each a P14 test-suite failure, each fixed
forward by a fleet PR that landed before this repair worker claimed the
issue. Both commits `713eff0a` (#2669) and `4756aca4` (#2693) are ancestors
of current main.

### Window 1 (12:55Z -> 14:43Z): unhosted P14 tests

1. PR #2655 (`449c318d`, merged 2026-09-01T12:49Z) shipped the fleet-ops#2614
   escalation fix with two new tests:
   `tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh` and
   `tests/fleet-escalation-completion-orphan-sweep.test.sh`.
2. Neither test was in the P14 reachable set (no ci.yml listing, no host
   from a listed test, no live/destructive tag, no known-orphan entry).
   `p14-test-listing-gate` failed the main push runs 33510331696
   (12:55Z), 33512839197 (13:20Z) and 33519725795 (14:28Z) with
   "2 test file(s) are neither in ci.yml, hosted by a listed test,
   live/destructive, nor a known orphan" -> trunk red -> FleetMainRed
   (this issue).
3. Auto-revert for the red commits ran and correctly halted (scenario A:
   only the non-required P14 check failed) with this fix-forward-tracked
   issue. "P14 tests / PR checks" is a NON-required check by documented
   design (`tests/auto-revert-required-check-gate.test.sh` scenario A).
4. Fix-forward: PR #2669 (`713eff0a`, merged 14:43:21Z) hosted both tests
   from `tests/ci-standards-audit.test.sh`. Main CI green since the
   14:51:00Z run on `325b8581`.

### Window 2 (16:35Z -> 17:11Z): pong-ok seat-lib miss

1. PR #2685 (`37055948`, merged 2026-09-01T16:26:30Z) shipped the
   fleet-ops#2661 seat tool-probe/overload-wedge work; its main push run
   33531943541 (16:28:05Z, commit `bf943450`) failed P14 at
   `FAIL: pong-ok: inline-only probe failure must register 1 overload
   strike (got 0)` -> main red again (FleetMainRed firing from 16:35Z).
2. Root cause (per #2693, verified): `bin/fleet-seat-comeback-release`
   sources `seat-lib.sh` optionally via `[[ -f "$SEAT_LIB" ]]`. On hosted
   CI `$HOME/.local/lib/pi-packet/seat-lib.sh` is absent, seat-lib never
   loads, `seat_is_overload_bench` returns 1, `register_overload_strike`
   is never called, and the pong-ok scenario gets 0 strikes.
3. Fix-forward: PR #2693 (`4756aca4`, merged 17:11:47Z) exported
   `PI_PACKET_SEAT_LIB` in `tests/fleet-seat-comeback-release.test.sh`,
   mirroring every other fleet-ops seat-lib test. Main CI green since the
   17:11:51Z run on `4756aca4`, continuously through current head.

## Fresh-run proof (current head)

- Remote: run 33566562283 on `9c6de004` (current main head, event=push,
  created 2026-09-01T22:29:34Z, run_attempt=1, conclusion=success) — a
  fresh run, not a rerun. All jobs success: P14 tests / PR checks,
  Shellcheck, Gitleaks, Semgrep, systemd-analyze. Check-runs on the head
  all completed (auto-revert + mass-close guard skipped) -> rollup SUCCESS
  (GraphQL `statusCheckRollup.state=SUCCESS` on `9c6de004`), so
  `fleet_main_ci_green` resolves 1. Live fleet.prom confirms
  `fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`.
- Local (this worktree at `9c6de004`, no local changes):
  - `bash tests/p14-test-listing-gate.test.sh` -> all OK (all 324 test
    files accounted; the two previously-orphaned tests now in the reachable
    set).
  - `bash tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh` ->
    OK (fleet-ops#2614 same-unit re-fire dedupe proven).
  - `bash tests/fleet-escalation-completion-orphan-sweep.test.sh` -> OK
    (orphan-chain sweep + GC proven).
  - `bash tests/fleet-seat-comeback-release.test.sh` -> ALL OK, including
    "PONG-ok inline answer -> seat stays benched (1 overload strike, no
    release)" — the exact scenario that was red in window 2.

run-proof: fresh push run https://github.com/Nishfleet/fleet-ops/actions/runs/33566562283 conclusion=success on 9c6de004 (event=push, run_attempt=1, not a rerun).

## Prevention (mechanical-fix for the failure class)

Class: "a new tests/*.test.sh (or a test-env gap) merged outside the P14
reachable set / hosted-CI seat-lib context turns main red until a fix lands".

- Existing mechanisms that FIRED in this incident:
  1. `p14-test-listing-gate` (tests/p14-test-listing-gate.test.sh, hosted
     in tests/ci-standards-audit.test.sh) caught both window-1 orphans by
     basename and failed the P14 suite — it detected the exact files.
  2. Auto-revert scenario A auto-filed the halt issue (this issue), so the
     break was tracked, never silent, and fixed forward (#2669, then #2693).
  3. The pong-ok miss is now pinned: `PI_PACKET_SEAT_LIB` is exported in
     the test, so a regression that drops the seat-lib load path fails the
     same gate (proven by the local run above).
- `mechanism-impossible`: binding "P14 tests / PR checks" as a REQUIRED
  status check — the only change that stops a P14-red merge at merge time —
  is branch-protection config under Administration scope. The
  nishfleet-worker app token is 403 on branch-protection read/write and
  workers are platform-rejected from `.github/workflows/**` edits. P14
  non-required is the fleet's documented design
  (tests/auto-revert-required-check-gate.test.sh); flipping it is an
  admin/design decision with a merge-throughput cost, not a worker change.

## Out-of-scope finding (filed as a new issue)

While tracing main-CI red I found `.github/workflows/ci-failure-escalation.yml`
pins `actions/checkout@3d3d42e5aac5ba805825da76410c181273ba90b1` (one char
off the canonical pinned checkout SHA used everywhere else:
`3d3c42e5aac5ba805825da76410c181273ba90b1`). Every run of the CI failure
escalation bridge fails before any step with "Unable to resolve action" —
including run 33027882177 on 2026-08-27, so the workflow has never been
green (open #719 observes the never-green state; this is its root cause).
`.github/workflows/ci-standards-audit.yml` carries two equally invalid pins
(checkout `3d3c42e5aac5ba805825da76410b181273ba90b1` and
upload-artifact `507de32f7b3f094b774c69e437be4eb0721c607a`), the root cause
of the never-green CI standards audit (open #1626). These are scheduled
alert workflows, not the main-CI rollup, so they do not gate
`fleet_main_ci_green`; they are filed as a new issue (plain, no labels) —
the fix pins to `.github/workflows/**`, which workers cannot push.
Filed as #2735.

## Previous incident record

This is the third FleetMainRed incident of the same class: #2402
(2026-08-30, breaking commit 35964e8, fix-forward #2406) and #2665 (this
one, breaking commits 449c318d + 37055948, fix-forwards #2669 + #2693).

Closes #2665