## What and why

`fleet-ops#1431` reported a "dispatcher starved" snapshot: 222 ready items, 0
dispatches/claims in 2h, 16 healthy seats. Investigation shows this is **not**
a broken dispatcher — it is the precedence-band **surge** phase working as
configured while the starvation watchers cannot tell the difference.

Root cause (verified from code + live journal):

- During the precedence-band surge phase (before `cutoff_utc` in
  `config/precedence-band.json`), fleet-ops intake claims ONLY the
  `surge_leverage_issues` list. Every other ready fleet-ops issue is skipped
  with `skip-surge-leverage` (lib/pi-intake-tick.sh early surge skip +
  `precedence_band_allow_claim`).
- When NONE of the surge leverage issues are still agent-ready (all
  claimed / blocked / done), a pure skip leaves the fleet-ops queue at **0
  dispatches for up to the whole surge window**. The band phase has a
  machinery floor (one repair lane always runs when live machinery == 0,
  fleet-ops#1452/#1474) — the surge phase never got that floor.
- Watchers read the hard 0-outflow as "dispatcher starvation" and auto-file
  a duplicate issue cluster (#1377, #1415, #1421, #1423, #1431, #1448 all
  still open, same phenomenon).

Fix — the mechanism, not the instance:

- `lib/precedence-band.sh`: the surge branch of `precedence_band_allow_claim`
  now applies the band-phase machinery floor — when live machinery == 0 and
  the latch is free, exactly ONE non-leverage repair lane is admitted
  (`allow-surge-floor`), then the rest are skipped. Leverage issues keep
  strict precedence; a live machinery worker also keeps the queue from being
  flagged starved. One lane per tick, latched — never a drain of the queue.
- `lib/pi-intake-tick.sh`: the early surge-phase skip is relaxed when surge
  work is exhausted (no leverage issue in the ready set) so the floor can be
  reached; otherwise the cheap skip stands.

This makes a hard 0-dispatch through a surge window impossible while
preserving the deliberate surge hold for leverage work.

## Verification

- `bash tests/fleet-precedence-band.test.sh` → EXIT 0 (incl. new
  scenario17a / 17a2 / 17a3 for surge floor + latch, and scenario16b for the
  intake-tick exhaustion probe).
- `bash tests/pi-intake-tick-seat-gate.test.sh` → EXIT 0 (shellcheck clean).
- `bash tests/pi-intake-tick-spawn-postcondition.test.sh` → EXIT 0.
- `bash tests/p14-test-listing-gate.test.sh` → EXIT 0 (no test-listing drift).
- `sgscan` → "No new security findings."
- Direct live run of the lib (surge phase pinned via `PRECEDENCE_BAND_NOW`):

  ```
  phase=surge
  allow-surge-leverage   (leverage issue 1223)     -> rc 0
  allow-surge-floor      (non-leverage, 0 machinery) -> rc 0  (one lane)
  skip-surge-leverage    (2nd non-leverage same tick)  -> rc 1  (latched)
  skip-surge-leverage    (non-leverage, live machinery) -> rc 1
  ```

Closes #1431
