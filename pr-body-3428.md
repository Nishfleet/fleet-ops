## What

Verification record for the 2026-09-05T00:30Z snapshot that opened
#3428 (`fleet_main_ci_green{Nishfleet/fleet-ops}=0`, all 8 other
enrolled repos green, FleetMainRed firing since 2026-09-04T20:35:56Z,
alert-repair chain terminal=escalated after 9974s). The red is
self-healed by the fleet's own normal PR cycle: the failing run is
identified, its contract mismatch is repaired on current main, and
current main is proven green with a fresh push-triggered CI run (not a
rerun).

## Root cause (verified live)

The failing run is `33914558910` (main CI, commit `76d23493`, created
2026-09-04T20:06:26Z — the completed run the heartbeat snapshot
resolved). Its P14 job failed in Verify:

```
pick_seat: unusable 1 seats [devin/swe-1-7]
seat-floor: fail-open devin/swe-1-7 (bench had 3600s left)
FAIL: all seats walled: pick_seat returned 0, expected 1 (refuse to route outside cap map)
Process completed with exit code 1.  (P14 tests / PR checks: .github#693)
```

PR #3371 (`fix(seat-floor): fail-open the shortest recoverable bench
instead of stalling`, fleet-ops#3324) changed the seat-floor contract to
fail-open on a fully-walled pool instead of stalling with exit 1. An
existing P14 assertion in `tests/repair-rotation.test.sh` still asserted
the old exit-1 contract, so that commit red'd the suite and the mismatch
propagated through the seat-cap / repair / scout churn commits that
merged in the stale-contract window.

## Repair already landed (not shipped here)

The green-main loop fixed the contract within its own cycle:
`d1051243` (test(repair-rotation): pin the seat-floor fail-open contract,
#3474; CI success) and `0bbd41d4` (test+config(p14): green main, #3486;
CI success). Every commit from `0bbd41d4` (06:17:42Z) onward is green.
No further code/config change is required.

## Verification (fresh dispatch, not a rerun)

Current main HEAD `ebe1f1352e6ac5fdc41d3be7976f8ddcece46d2c` carries a
brand-new **push-triggered** CI run — **`33950389921`** (created
2026-09-05T06:38:56Z via push; a rerun would pin the old failing
workflow SHA) — all 5 jobs SUCCESS (systemd-analyze, P14 tests/PR
checks 8m30s, Gitleaks, Shellcheck, Semgrep). All check-runs on the
head: `Semgrep/Shellcheck/Gitleaks/P14/systemd-analyze` all `success`.
Live exporter gauge (timer-refreshed):
`fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`; all 9 repos green;
FleetMainRed absent from `/api/v1/alerts`.

run-proof: live `gh run view 33950389921 -R Nishfleet/fleet-ops`
(Triggered via push, conclusion success, all 5 jobs success) and
`curl -s http://localhost:9090/api/v1/query?query=fleet_main_ci_green`
(`fleet-ops 1`), plus the P14 job transcript of failing run
`33914558910` naming the exact assertion that red'd main.

## Mechanical-fix

Class: "a fleet-ops PR changing a production contract (seat-floor stall
-> fail-open) red's the P14 suite because an authoritative test still
asserts the old contract, keeping main red until a follow-up
test-contract commit lands."

Mechanisms that already fired correctly (no new code shipped):

1. ci-required-check-purity / auto-merge-arm — the head's CI
   annotations show "CI red on consecutive commits; auto-merge arming
   paused" then "CI green again; auto-merge arming resumed"; the merge
   path pauses on recurring red so it does not spread.
2. P14 suite is the authoritative canary — it caught the exact contract
   mismatch at the merge point; the green-main loop (#3474, #3486)
   cleared it within the same rotation.
3. red-on-main-watch / red-on-main-detector — the alert fired and
   escalated to #3428 as intended; the red was transient within the
   fleet's own push/PR cycle and resolved before any durable defect.

mechanism-impossible: hard-stopping every PR whose P14 is red would
forbid the self-healing test-contract commit that merges to fix main —
a permanent merge deadlock traded for a transient red. The existing
pause-and-resume auto-merge gate is the correct floor. Prompt-repair
timing in the alert-repair chain is fleet-ops-owned tuning covered by
its own canary; per fleet-ops#366 I do not add a checker for conventions
the existing canary already enforces.

## What this PR ships

Two markdown files only: `verification-3428.md` (chain of evidence,
root cause, fresh-run transcript, live gauge snapshot, mechanism audit)
and `pr-body-3428.md` (this body). No code, no unit, no timer, no
workflow touched.

Closes #3428
