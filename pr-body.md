## What

DeployBlockedStuck fired for 4000s despite two rc=0 redispatches (2026-09-05 11:52:14Z, 12:22:13Z). The canary reported `redispatch-rc=0 dispatched=True` (success) while the alert kept firing.

**Root cause:** the redispatch was a no-op SKIP. The dispatcher only wrote `SKIPPED-CLAIMED` (reason=alert-repair-claim-already-held) — no new repair unit was spawned, so the deploy-blocked condition was never cleared. But `_dispatch_line_seen()` scanned the WHOLE actions.log for any DISPATCH line for the alertname and found a stale DISPATCH line from an earlier dispatch (04:22Z), so it returned True and the canary logged `dispatched=True` — a false success.

**Fix:** `_dispatch_line_seen()` now takes a `since` marker captured just before the redispatch runs, and only counts DISPATCH lines written at/after that marker. A redispatch that was SKIPPED-CLAIMED (no new DISPATCH line) now correctly reports `dispatched=False` and escalates to STOP-REASON / senior conference instead of reporting success — the same escalation path as the existing no-op-redispatch detection (fleet-ops#2247/#2651).

## Verification

- New regression test `9e-stale` reproduces the exact live shape: a stale 04:22Z DISPATCH line seeded, then a SKIPPED-CLAIMED redispatch at 11:52:14Z. Asserts `dispatched=False` and STOP-REASON written.
- `bash tests/fleet-completion-canary.test.sh` → 39 OK, 0 FAIL.
- Full P14 CI test list (44 tests) → all pass.
- `bash tests/fleet-deploy-quality.test.sh` → all pass.
- `bin/sgscan` → no new security findings.

run-proof: tests/fleet-completion-canary.test.sh (39 OK), full P14 CI list (44 pass), fleet-deploy-quality.test.sh, sgscan rc=0

net-positive-because: adds a regression test (59 lines) for the stale-DISPATCH-line bug plus a 22-line fix; the test is the durable guard that prevents the false-success redispatch from recurring.

Closes #3625
