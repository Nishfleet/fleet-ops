# #3428 — fleet-ops main CI red (FleetMainRed escalated): verification record

Snapshot at issue creation: 2026-09-05T00:30Z heartbeat reported
`fleet_main_ci_green{Nishfleet/fleet-ops}=0`; FleetMainRed critical
firing since 2026-09-04T20:35:56Z, alert-repair chain terminal=escalated
after 9974s. All 8 other enrolled repos remained green.

This red was self-healed by the fleet's own normal PR cycle before a
repair PR landed. The failing run is identified, the contract mismatch
that caused it is repaired on current main, and current main is proven
green with a fresh push-triggered CI run (not a rerun).

## The failing run (identified)

Run `33914558910` ("main CI", commit `76d23493`, created
2026-09-04T20:06:26Z) is the completed main-branch run the heartbeat
snapshot resolved. Its P14 job failed in the Verify step:

```
[2026-09-04T20:07:18Z] pick_seat: unusable 1 seats [devin/swe-1-7]
[2026-09-04T20:07:18Z] seat-floor: fail-open devin/swe-1-7 (bench had 3600s left)
FAIL: all seats walled: pick_seat returned 0, expected 1 (refuse to route outside cap map)
##[error]Process completed with exit code 1.
P14 tests / PR checks: .github#693
```

PR #3371 (`fix(seat-floor): fail-open the shortest recoverable bench
instead of stalling`, fleet-ops#3324) changed the seat-floor contract so
a fully-walled seat pool fail-opens to the shortest-bench seat instead
of stalling with exit 1. An existing P14 assertion
(`tests/repair-rotation.test.sh`, "refuse to route outside cap map")
still asserted the old exit-1-stall contract, so that commit red'd the
P14 suite. That mismatch then propagated through the subsequent
seat-cap / repair / scout churn commits that merged while the contract
was stale.

## Repair already landed (not shipped here)

The green-main repair loop fixed the contract in the normal cycle:

- `d1051243` `test(repair-rotation): pin the seat-floor fail-open
  contract from fleet-ops#3324 instead of the pre-#3371 exit-1 stall`
  (`#3474`) — CI success (run 33949923782).
- `0bbd41d4` `test+config(p14): green main — repair-rotation (#3474),
  pi-audit-run scenario9 (#3387), devin AIMD pin as ceiling==cap`
  (`#3486`) — CI success (run 33949420193).

Every commit from `0bbd41d4` (2026-09-05T06:17:42Z) onward is green.
No further code or config change is required; the cause is repaired on
current main.

## Proof green — fresh dispatch, not a rerun

Current main HEAD `ebe1f135` has a fresh **push-triggered** CI run —
**run `33950389921`** (created 2026-09-05T06:38:56Z via push; a rerun
would pin the old failing workflow SHA, this is a brand-new run on the
latest workflow definition):

```
✓ main CI · 33950389921  (Triggered via push)
  ✓ systemd-analyze      (19s)   ID 101263961076
  ✓ P14 tests / PR checks (8m30s) ID 101263961220
  ✓ Gitleaks              (7s)   ID 101263961229
  ✓ Shellcheck            (59s)  ID 101263961243
  ✓ Semgrep               (40s)  ID 101263961343
```

All check-runs on the head commit confirm success:

```
Semgrep: success | Shellcheck: success | Gitleaks: success
P14 tests / PR checks: success | systemd-analyze: success
```

Live exporter gauge (refreshed by the fleet-metrics-export timer):

`curl -s 'http://localhost:9090/api/v1/query?query=fleet_main_ci_green'`
returns `fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 1`. All 9
enrolled repos green; FleetMainRed no longer present in
`/api/v1/alerts`.

## Mechanical-fix

Class: "a fleet-ops PR that changes a production contract (here:
seat-floor stall -> fail-open) red's the P14 suite because a
still-authoritative test asserts the old contract, keeping main red
until a follow-up test-contract commit lands."

Mechanisms that already fired correctly (no new code shipped):

1. `ci-required-check-purity.yml` / auto-merge-arm — the head's CI
   annotations show "CI red on consecutive commits; auto-merge arming
   paused" and, once green, "CI green again; auto-merge arming resumed".
   The merge path pauses on recurring red so the red does not spread
   while the contract is stale.
2. P14 suite is the authoritative canary — it caught the exact
   contract mismatch (`pick_seat returned 0, expected 1`) at the merge
   point; the green-main repair loop (#3474, #3486) is the self-healing
   response that cleared it within the same rotation.
3. `red-on-main-watch` / `red-on-main-detector` — the alert fired and
   escalated to a ticket (#3428), which is the intended path; the red
   was transient within the fleet's own push/PR cycle and resolved
   before a durable defect existed.

mechanism-impossible: converting this class into a hard stop on merging
any PR whose P14 is red would forbid the very self-healing test-contract
commit that clears it (the repair PR must merge to fix main). That
trades a transient red for a permanent merge deadlock and is why the
existing pause-and-resume auto-merge gate (mechanism 1) is the correct
floor. A tighter prevention belongs to the alert-repair chain's
prompt-repair timing, which is fleet-ops-owned tuning covered by its own
canary; per fleet-ops#366 I do not add a checker for conventions the
existing canary already enforces.
