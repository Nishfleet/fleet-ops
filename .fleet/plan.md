# Plan — fleet-ops#4773 (manager re-entry: verify merged fix, harden live-shape test, close)

## Context (manager investigation, 2026-09-10 third claim)

The implementation for this issue is ALREADY MERGED to main:
- #4998 (15:33Z): auto-file-or-link critical-path claim when
  FleetSloSeatAvailSlowBurn fires past 1h — extends libexec/alert-repair-dispatch
  with `_slowburn_file_or_link`, no new organ.
- #5012 (16:19Z): parse AMX epoch start (production sends AMX_ALERT_<i>_START
  as a Unix epoch integer, e.g. 1789050374 in packet files) with ISO fallback;
  switched the test's start to epoch +%s.

Both merged with "Relates to #4773" — never "Closes" — so the issue stays
open and keeps being re-claimed (4 claims today; this is the 3rd/4th).

Live state verified by manager:
- Alert firing since 2026-09-08T09:51:03Z (56h); active=true on
  127.0.0.1:9093. startsAt literal: `2026-09-08T09:51:03.742Z` (ISO with ms).
- No open critical-path issue with the signal key `slo/seat-availability-slowburn`
  (only #4773 itself). So the first post-fix AMX tick (~21:52Z, 6h repeat) will
  FILE the first claim.
- Tests green on main:
  bash tests/alert-repair-slo-slowburn-skip.test.sh (a-e all OK)
  bash tests/alert-repair-claim-mutex.test.sh (exit 0)
- Parser proven against live shape: `2026-09-08T09:51:03.742Z` -> 202296s (>>3600).

## Remaining gap (reason this PR exists)

accept-5 demands a prevention mechanism proving BOTH directions. The test
exists and covers (a) file / (b) link+idempotent / (c) short skip /
(d) multi-alert index / (e) ISO-no-ms backward-compat. But the LIVE
Alertmanager payload shape is ISO WITH fractional milliseconds
(`2026-09-08T09:51:03.742Z`) — no test locks that exact shape. Two
consecutive bugs (#4998's ISO-only parse, #5012's epoch discovery) were
timestamp-shape mismatches; the exact live shape must be locked so a
future regression of the ms-fraction handling is caught. This is the
smallest durable hardening: extend test (e) to also cover the live
ms-fraction + Z shape with a literal from the live alert.

## Phase 1: lock the live Alertmanager payload shape in the prevention test
- [x] tests/alert-repair-slo-slowburn-skip.test.sh: add one case proving an
      ISO 8601 start WITH fractional milliseconds + trailing Z (the exact
      literal `2026-09-08T09:51:03.742Z` from the live Alertmanager alert)
      fires the file path past 1h — the parser's `s[:19]` fallback must hold.
      Keep all existing (a)-(e) assertions intact.
- [x] Run termination: bash tests/alert-repair-slo-slowburn-skip.test.sh &&
      bash tests/alert-repair-claim-mutex.test.sh (both exit 0).
- [x] Adjacent: py_compile libexec/alert-repair-dispatch; yaml load
      config/fleet_rules.yml; run tests/signal-reconcile.test.sh (all green).
- [x] No new organ, no skip-list raise, no seat cap change, no live issue
      filed by the worker.

_Phase 1 done 2026-09-10 by worker-4773 (commit f63c9a16, pushed). Worker
run output: (a)-(f) all OK; mutex exit 0; py_compile OK; yaml OK;
no-agent-names OK; live verify receipt: alert active startsAt
2026-09-08T09:51:03.742Z; gh issue search returns only #4773._

## Acceptance mapping (unchanged from merged work)
1. Check existing claim before filing (find_existing by signal key) -> merged #4998. ✓
2. Routes through existing organs (alert-repair-dispatch + fleet-issue-file + gh) -> merged. ✓
3. Does NOT raise the skip-list -> unchanged. ✓
4. Notifies am-executor, never pages Nish -> merged. ✓
5. Prevention test proves both directions + idempotence -> merged + THIS phase locks live shape. ✓
6. No money decision -> unchanged. ✓

## Phase 2: manager opens PR with Closes #4773 + Verification + run-proof
- [ ] PR body: Verification (real run output), run-proof, research/help-first
      not needed (no new bin/), organ-heartbeat (alert-repair-dispatch is an
      existing organ; tests/ is a test), loose-ends: none.
- [ ] Closes #4773 (not Relates — this is the closing PR).
- [ ] Review round (fleet-ops PRs exempt from product-seat reviewer per
      intake config; manager runs review-adjudication manually).
- [ ] gh pr merge --auto --squash.