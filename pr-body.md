## What broke

Heartbeat 2026-08-30T17:30Z raised FleetChainStalled pending critical with
`fleet_chain.stalled{plane=dispatch,hop=run}=2`. Two dispatch items —
`alert-repair-SystemUnitFailed-20260830T153750Z` and
`alert-repair-FleetSloMainGreenSlowBurn-20260830T153813Z` — sat at the run
hop and never terminated for ~105 minutes, then were re-dispatched past their
deadlines. The re-dispatch tick exported `redispatched=2`, lighting the rail.

Root cause (proven against the live ledger + journals): **both units actually
RAN and completed** (SystemUnitFailed finished 15:39:48Z, SloMainGreenSlowBurn
finished 15:58:07Z, each with full `PACKET-VERDICT` output). But the canary's
`journal_text()` read only the **last 20 lines** of each unit's journal
(`journalctl -o cat -n 20`). A verbose pi run pushes the systemd
`Started <unit>.service` line — always the FIRST journal entry — out of that
tail window (both incident journals are 24 lines). So `journal_verdict()`
returned None and `journal_has_started()` returned False, and
`classify_dispatch()` mislabeled a completed, healthy run as an **orphan**.
The orphan stayed open past the 90-min deadline, was re-dispatched (a
duplicate full pi run — pure waste), and the redispatch tick tripped the
`fleet_chain_stalled{plane="dispatch"}` rail.

Confirmed live: `classify_dispatch()` against the real units returned
`orphan` pre-fix and `completed-success` post-fix.

## The fix (smallest durable change)

`journal_text()` now reads the **full** journal instead of the last 20 lines.
The Started line survives on any run length, so a completed `--collect` unit
is recognized as `completed-success` on the very next tick — the run hop
terminates without a human noticing, no duplicate re-dispatch, no stalled-rail
spike. Failure markers (`Failed with result` / `status=1/FAILURE`) land at the
END of the journal, so the full scan still detects genuine failures first.
`journal_verdict` and `journal_has_started` semantics are unchanged; only the
reader no longer throws away the receipt for verbose runs. This repairs both
consumers: the dispatch plane (`classify_dispatch`) and the alert-repair plane
(`unit_status`), which shared the same truncated reader.

## Prevention mechanism (regression test)

The test fake journalctl now models real `journalctl`: it truncates to `-n N`
only when `-n N` is passed, and returns the full fixture otherwise. New test 18
feeds a 24-line journal (Started line FIRST, 23 worker lines) — the exact live
incident shape, Started outside any tail-20 window — and asserts the entry
closes `completed/verdict=success` with no re-dispatch and
`fleet_chain_stalled{plane="dispatch",hop="run"} 0`.

**This test fails against the pre-fix code and passes post-fix** (proven):
old code classifies `id-18` as `status=redispatched verdict=orphan` and spawns
`synth-18-r1`; fixed code closes it `completed/success`.

## Verification

- `python3 -m py_compile bin/fleet-completion-canary.py` → OK
- `bash tests/fleet-completion-canary.test.sh` → exit 0, all cases green incl.
  new case 18
  `OK: dispatch plane: verbose --collect journal (Started past tail window) -> completed-success, not orphaned (fleet-ops#2414)`
- Pre-fix run of the same suite → case 18 FAILS with
  `{'status': 'redispatched', 'verdict': 'orphan', 'new_unit': 'synth-18-r1'}`,
  tick log `dispatch={'redispatched': 1, ...}` — the exact incident shape.
- Live-environment classification with the fixed reader against the two real
  incident units → both now `completed-success` (were `orphan`):

  ```
  alert-repair-SystemUnitFailed-20260830T153750Z  -> completed-success
  alert-repair-FleetSloMainGreenSlowBurn-20260830T153813Z -> completed-success
  ```

run-proof: no new unit/timer/workflow; the deliverable is the canary itself. Its
hermetic suite (which exercises the exact journal-receipt path end-to-end) is
green (exit 0), and the failing-then-passing case-18 transcript is included
above.

Closes #2414
