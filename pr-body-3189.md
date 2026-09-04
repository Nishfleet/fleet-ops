## What changed

The pi-scout@ timers (`pi-scout@0509.timer`, `pi-scout@fleet-ops.timer`) fire on a deliberate 4h cadence (`OnCalendar=*-*-* 00/4:00:00` + `RandomizedDelaySec=300`, max consecutive-trigger gap 14700s — the "floor" the low-water-mark and the work-supply canary rely on, fleet-ops#1144). But the opus-heartbeat-gather's scout staleness gate compared timer ages against a **2h window** (`stale_scouts_2h`, `age > 7200`), which matches no live cadence: every healthy 4h cycle looked "drifting" and the 2026-09-04 heartbeat filed this issue (#3189) at age 11452s — inside the cadence, rising 10554 -> 11452 because the age only resets every 4h.

Per the issue's own options, the gate threshold is the mismatch (the 4h timer is the intended floor, not the defect): fix the gate.

- `SCOUT_STALE_S = 15000` in the gather (parity with `fleet-work-supply-canary`'s `FLEET_WORK_SUPPLY_MAX_IDLE_S` default — "must exceed OnCalendar 4h + RandomizedDelaySec 5m = 14700s, so a healthy cadence never false-positives", fleet-ops#1144).
- The scout snapshot block now exports `stale_after_s` so consumers compare `oldest_age_s` against the real cadence bound, not the 2h snapshot window.
- The hygiene count key is renamed `stale_scouts_2h` -> `stale_scouts` (the 2h name encoded the wrong bound).
- Regression test `tests/opus-heartbeat-scout-staleness-gate.test.sh` drives a new hermetic `--check-scout-staleness-gate` subcommand (4h-healthy, past-bound, null-age, boundary, source-pin, live-snapshot scenarios) and is allowlisted live/VPS-only in the p14 test-listing gate.

Ship path: `/home/nish/.local/libexec/opus-heartbeat-gather` (machine-local, outside any git worktree, per the launcher's own header — same convention as fleet-ops#2751). Test + gate listing ship here.

## Verification

- `bash tests/opus-heartbeat-scout-staleness-gate.test.sh` -> ALL PASS (scenarios 1-6).
- All 9 `bash tests/opus-heartbeat-*.test.sh` -> PASS (no sibling regression).
- `bash tests/p14-test-listing-gate.test.sh` -> "P14 test list is closed" (all 346 test files accounted for).
- Live gate, regenerated with the new gather: `scout.oldest_age_s=13047`, `scout.stale_after_s=15000` -> not stale; `t_hygiene_counts()` -> `stale_scouts: 0` (was 2 under the 2h bound at the same instant).
- Consecutive trigger pairs under the window (live `systemctl --user show`):
  - `pi-scout@0509.timer`: last 12:04:08 -> next 16:01:48 IST, gap 14260s < 15000s
  - `pi-scout@fleet-ops.timer`: last 12:04:08 -> next 16:01:49 IST, gap 14261s < 15000s
  - Schedule math: `systemd-analyze calendar '*-*-* 00/4:00:00'` -> exact 4h period; + 300s jitter -> max gap 14700s < 15000s. The old 2h bound flagged every one of these pairs.
- `/home/nish/.local/bin/sgscan` on the diff -> "No new security findings".
- `python3 -m py_compile` on the installed gather -> OK.

run-proof: journal/transcript above + live `systemctl --user show pi-scout@0509.timer pi-scout@fleet-ops.timer -p LastTriggerUSec -p NextElapseUSecRealtime` (12:04:08 -> 16:01:48/16:01:49 IST, gaps 14260s/14261s; the next opus tick consumes the regenerated snapshot with stale_after_s=15000 and stale_scouts=0).

organ-heartbeat: opus-heartbeat-gather is not a fleet-ops registry organ (config/fleet-organs.json has no opus entry and the file lives outside this repo) — changed in place per the launcher's own header, same as fleet-ops#2751; no absent() rule or registry entry applies.

mechanism: regression test + source-pin (scenarios 1-5) mechanically prevent reverting the corrected bound; the `stale_after_s` export prevents the drain from conflating scout age with the 2h snapshot window.

Closes #3189