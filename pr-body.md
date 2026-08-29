test(completion-canary): pin twin verify-stall drain regression (fleet-ops#1623)

## What / why

#1623 is the re-fire of #1610: `chain_stalled_total` went 1.0 -> 2.0 in the
16:30Z->17:30Z window, with BOTH rows `hop=verify plane=alert-repair`, and
FleetChainStalled critical since 2026-08-28T10:22:34Z. The verify hop holds a
SUCCEEDED repair unit whose alert is still firing, so the alert chain stays
open at `hop=verify` until a mechanical break terminates it.

The mechanical stall-break already exists on `main` (shipped by #1610, PR
#1689, commit 36f51c8): a laddered verify chain gets a `verify_deadline_ts`
and, once `now >= deadline`, terminates as `detector-red` and writes a
cooldown state so the chain cannot hold the FleetChainStalled rail open
indefinitely. This issue's live incident (two stalled verify rows) is drained
by that same mechanism — there is no remaining code gap, verify cannot hold an
item indefinitely.

What was missing was regression coverage for the exact #1623 re-fire shape:
TWO concurrent, never-laddered verify-stall chains. Existing test 9 covers the
pre-existing-laddered (zero-grace) drain path; this PR adds a 9b block that
injects two firing alerts whose repair units already SUCCEEDED, asserts both
ladder on tick 1 with a verify deadline and `fleet_chain_stalled{...verify} 2`,
then drains BOTH as detector-red at the deadline so verify open/stalled return
to 0 and the ledger records both detector-red closes.

Mechanical-fix rule (fleet-ops#366): this is a failure-fix (detector re-fire).
The prevention mechanism is the regression test that proves the guard fires
and drains the twin shape — a future refactor that lets verify hold a chain
indefinitely fails the test.

## Verification

Ran the repo's own completion-canary test suite (the execution-is-the-review
inner loop) on the exact diff; it is green, including the new 9b block:

```
$ bash tests/fleet-completion-canary.test.sh
OK: verify stall deadline → detector-red terminal + cooldown gate (fleet-ops#1577/#1610)
OK: two concurrent verify-stall chains both drain via deadline (fleet-ops#1623)
OK: fleet-completion-canary: stall ladder, green cycle, skip-list, ue observe, verify deadline, dispatch plane, --collect success
```

`sgscan tests/fleet-completion-canary.test.sh` -> "No new security findings."

No new bin/ file, no new organ, no systemd/workflow change -> no
research:/help-first:, no absent-rule/organ registry entry, no run-proof unit
needed for this test-only diff.

Closes #1623
