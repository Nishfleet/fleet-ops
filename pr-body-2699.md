## What

Verification record for the 2026-09-01T18:30:06Z snapshot that opened
#2699 (`failed_user=1 (pi-scout-repair@0509.service)`, Nishfleet/0509
the only repo with `fleet_main_ci_green=0`, FleetMainRed firing since
17:10:56Z). The red is self-healed: the wrapper (`bin/pi-scout-run` ->
`pick_seat`) rotated off the bench-held and 429-walled free seats on
each retry, the next timer tick took a usable seat, and the unit has
been `code=exited, status=0/SUCCESS` since 2026-09-02T01:55:49Z with no
failed user units. Nishfleet/0509 main CI is green: last 19 completed
main-branch runs all `success`; Deploy production `success` on most
recent push; live `fleet_main_ci_green{repo="Nishfleet/0509"}=1`.

## Root cause (verified live)

Two transient seat-provider fault windows, both auto-resolved by
`pick_seat` rotation between ticks; the unit definition
(`/home/nish/.config/systemd/user/pi-scout-repair@.service`) was never
at fault.

### Window A (Sep 1 18:30:00Z -> 23:55:44Z): NO USABLE SEAT flood

1. 18:30:00Z: `pick_seat: NO USABLE SEAT -- every allowlisted seat is
   dead/capped/rate-limited` on bench-held
   `openrouter/deepseek/deepseek-v4-flash-0731` (spawn-bench until
   18:32:06Z) and `commandcode/minimax/minimax-m3-free` 503 overloaded
   (free, no purchase wall -- see fleet-ops#130).
2. 18:30:10Z, 18:30:16Z: OnFailure= chain re-dispatched, same outcome.
3. 18:30:16Z -> 23:55:44Z: StartLimitBurst=2 /
   StartLimitIntervalSec=21600 silenced auto-redispatch for ~5h25m.
4. 00:00:00Z (Sep 2): timer tick landed a usable
   `openrouter/deepseek/deepseek-v4-flash-0731` (post-bench), finished
   `PACKET-VERDICT tools=4 class=worked`; the next 6 ticks all exited 0.

### Window B (Sep 2 06:56:18Z -> 07:25:07Z): 429 rate-limit, then green

1. 06:56:18Z: bench-expired `opencode/mimo-v2.5-free` returned
   `429: FreeUsageLimitError` on its first pick (free seat, no money
   boundary).
2. 07:00:01Z (4 minutes later): `pick_seat` rotated to
   `opencode/nemotron-3-ultra-free`, completed with
   `PACKET-VERDICT tools=27 class=worked` -> `code=exited, status=0/
   SUCCESS`. Unit stayed `inactive (dead)` thereafter.

The unit has been healthy ever since; the issue snapshot caught the
unit mid-recovery.

## Verification

- `systemctl --user status pi-scout-repair@0509.service --no-pager`
  (live, post-claim): `Active: inactive (dead) since Wed 2026-09-02
  07:25:07 IST`, `Main PID 365196 (code=exited, status=0/SUCCESS)`,
  `CPU 6.277s`, no failed marker. `systemctl --user list-units
  --state=failed` returns 0 fleet units (the unrelated fleet-heartbeat
  failure shown earlier in the day is its own #2797 ticket).
- Fresh `systemctl --user start pi-scout-repair@0509.service --no-block`
  at 2026-09-02T09:06:18Z IST finished at 14:37:07 IST with
  `Process 2781390 (code=exited, status=0/SUCCESS)`, `Main PID
  2781390 (code=exited, status=0/SUCCESS)`, `tools=4 class=worked`,
  `CPU 3.468s`, `Memory peak 84.3M`. Picked `minimax/MiniMax-M3
  (weight=heavy)` (free lane, not pinned -- unit file comment cites
  fleet-ops#130).
- **Freshest live re-verification this turn (2026-09-02T10:04:03Z IST)**: a
  second timer-driven tick ran 15:34:03 -> 15:53:34 IST after a brand-new
  transient fault on a different free seat (`commandcode/poolside/laguna-s-2.1-free`
  returned HTTP 503 `overloaded_error`). Wrapper logged a seat-fault
  rotation message, the tick re-armed, and the run completed
  `Process 3118102 (code=exited, status=0/SUCCESS)`, `Main PID 3118102
  (code=exited, status=0/SUCCESS)`, `tools=5 class=worked`,
  `CPU 3.108s`, `Memory peak 83.2M`. Two `scout-candidate` issues (#1567,
  #1568) were filed as the unit's normal product.
- 0509 main-branch runs: last 5 completed all `success`
  (Ratchet auto-tighten, Cross-browser matrix, Meta discovery canary,
  D1 restore proof auto-refresh, Daily market-signal D1 snapshot).
  Last 6 push runs on main all `success` or unrelated-skip; head
  commit `ed2d02847b37846284d0c2b01abdb13f20469c79`.
- `curl -s 'http://localhost:9090/api/v1/query?query=fleet_main_ci_green'`
  (live fleet.prom): `repo=Nishfleet/0509 value=1`. The only red repo
  in the snapshot is Nishfleet/fleet-ops (separate #2797, out of scope).

run-proof: live `systemctl --user start pi-scout-repair@0509.service` at
2026-09-02T09:06:18Z IST (run PID 2781390, journal starting "Starting
pi-scout-repair@0509.service ...", ending "Finished
pi-scout-repair@0509.service ... code=exited, status=0/SUCCESS",
PACKET-VERDICT tools=4 class=worked on minimax/MiniMax-M3); **second
live re-verification 2026-09-02T10:04:03Z IST (PID 3118102,
tools=5 class=worked, same exit 0)**; 0509 main CI rollup SUCCESS across
all 19 recent completed main-branch runs.

## Mechanical-fix

Class: "transient seat-provider faults (503 overloaded_error on free
tier; 429 rate-limit on bench-expired `opencode/mimo-v2.5-free`; NO
USABLE SEAT when all free seats are bench-held or dead at once) trip
`pi-scout-repair@<repo>.service` to `failed` for one snapshot window
even though the wrapper auto-rotates."

Mechanisms that already fired correctly (no new code shipped):

1. `bin/pi-scout-run` -> `pick_seat` -- the wrapper does not pin
   provider/model. Unit file comment cites fleet-ops#130
   ("a hardcoded repair seat is how this unit sat activating on
   quota_exhausted glm-5-2"). Every retry rotated to a different free
   seat; once a seat was usable, the unit finished `PACKET-VERDICT
   class=worked` on the next tick.
2. Self-healing via timer cadence -- `pi-scout@0509.timer` fires
   `OnCalendar=*-*-* 00/4:00:00` with `RandomizedDelaySec=300`. Each
   tick is a fresh `pick_seat`; within 4h of the snapshot the bench
   expired and the wall cleared.
3. Failure-floor recovery in `bin/fleet-heartbeat` (PR #102,
   fleet-ops#28) -- tier-1 `unit_recovery_class recover` for
   `pi-scout-repair@*` runs `systemctl --user reset-failed` +
   `start --no-block`.
4. Recent seat-class fixes (PR #2654 / #2594; PR #2661 / #2574) --
   lower `SEAT_FAILURE_CEILING` to 20 and corpse-reclassify `quota_cap`
   at 25 consecutive failures, so chronic 503/429 seats leave the
   ladder before they cause a sustained outage.

mechanism-impossible: tightening the heartbeat snapshot interval so
transient failures cannot land in a tick window. That is fleet-ops-owned
tunable config, and a snapshot interval change without a paired
alert-repair canary would just file noise; fleet-ops#366 forbids
checkers for conventions the existing canary already enforces.

## What this PR ships

Two markdown files only: `verification-2699.md` (the chain of evidence,
journal transcript, fleet_main_ci_green live snapshot, and the
mechanism audit) and `pr-body-2699.md` (this body). No code, no unit,
no timer, no workflow touched. Unit file
`/home/nish/.config/systemd/user/pi-scout-repair@.service` unchanged
(both header and ExecStart line; the wrapper rotation that fixed this
is what fleet-ops#130 / #136 shipped).

Closes #2699
