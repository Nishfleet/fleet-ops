# Observe-close for #7710 — TIMER-NO-NEXT false-positive loop; the emitting pass was deleted in the rail cut

Issue #7710 (filed 2026-09-18, heartbeat tier-1 tick evidence) asked for a
root-cause and fix in `bin/fleet-heartbeat-tier1`'s timer-arm pass: its
`TIMER-NO-NEXT` branch read `systemctl --user show <t>
--property=NextElapseUSecRealtime --value`, saw empty/0 on healthy
enabled+active intake timers, ran a no-op `systemctl --user start`, counted
`timers_re_enabled++`, and re-fired the same two signal keys
(`loud/timer-no-next/0509.timer`, `loud/timer-no-next/fleet-ops.timer`) on
every tick since at least 2026-09-09T01:55Z — alarm noise that ate the
reconciler cap and could never observe-to-close.

By the time this re-claim ran (2026-09-22), the emitting organ no longer
exists. This report is the resolution record, same convention as the #7405
→ #8115, #7403 → #8111 and #7511 observe-closes.

## What was found

1. **Root cause confirmed live — the `show` call races the timer's own
   fire.** While a timer's triggered service is still active, systemd puts
   the timer in `SubState=running` and suppresses the calendar next-elapse:
   `TimersCalendar={ OnCalendar=*-*-* *:00/5:00 ; next_elapse=(null) }`,
   `NextElapseUSecRealtime=` empty, `NextElapseUSecMonotonic=infinity`.
   Live read 2026-09-22 05:28–05:32 IST:
   `pi-intake@fleet-ops.timer` was `UnitFileState=enabled`,
   `ActiveState=active`, `SubState=running` with empty
   `NextElapseUSecRealtime` because `pi-intake@fleet-ops.service` was
   `ActiveState=activating` (ExecMainStartTimestamp 05:25:33, fired by the
   timer's own 05:25:32 elapse). Its sibling `pi-intake@0509.timer` —
   identical template, service already finished — sat `SubState=waiting`
   with `NextElapseUSecRealtime=Tue 2026-09-22 05:30:02 IST`. The pass's
   alternative hypothesis ("the restart performed by the same pass resets
   the property") is falsified by ordering: the alarm fired *on* the empty
   read, so the value was empty before the pass's no-op `systemctl --user
   start` ever ran — and the same signal re-firing every tick since
   2026-09-09 means each fresh tick read empty again before any start of
   its own. The tick's `verify_timers` ran
   mid-pass lasting minutes while intake timers fired every 15–20 min and
   their services ran minutes — at the cited 2026-09-18T09:06Z tick the two
   signal-emitting timers were the mid-run pair, consistent with
   `timers_verified=2 timers_re_enabled=2` and the two signal keys
   observed.
2. **The emitter is deleted.** `ca33faa96` ("refactor(rail): the unit IS
   the worker — collapse intake/worker/scout to pi --print", 2026-09-18
   16:39 IST, first-parent of main) removed `bin/fleet-heartbeat-tier1`
   (3,185 lines — `verify_timers`, the TIMER-NO-NEXT branch and the
   `re_enabled` accounting with it), `bin/fleet-heartbeat`,
   `fleet-heartbeat-auditor`, `fleet-heartbeat-low-water-mark`,
   `fleet-heartbeat-red-pr-repair`, `fleet-heartbeat-undersaturation`,
   `fleet-heartbeat-tier2`, `systemd/fleet-heartbeat.{service,timer}`,
   `bin/intake-reconcile` and its units, and 20+ heartbeat tests including
   `tests/fleet-heartbeat-verify-timers.test.sh` — the suite that would
   have been the regression test's sibling. `git merge-base --is-ancestor
   ca33faa96 origin/main` passes at origin/main `07b6779a2`.
3. **No tick exists to emit the signal.** `systemctl --user list-timers
   --all` (2026-09-22 05:32 IST) lists ten timers — `fleet-heartbeat.timer`
   is not among them; `~/.config/systemd/user/` carries no heartbeat unit
   files; `journalctl --user -u fleet-heartbeat.service` returns "-- No
   entries --". The metric's alarm half — "the timer-no-next alarm fires
   zero times per tick" — is permanently satisfied: there is no tick and
   no emitter.
4. **The verify-block canary is deleted too.** `bin/fleet-timer-manifest-
   drift-canary` went in `ada87b543` ("chore(glue-sweep): delete
   canary-fleet (8517 lines, Jev 0.82)", 2026-09-18 15:43 IST). Its only
   reader was the heartbeat's timer-manifest pass, deleted in the same
   sweep, and the manifest itself went in `f8b567588` (see the #7511
   observe-close record).
5. **Nothing on main re-implements the check.** `git grep` over
   origin/main `07b6779a2` for `TIMER-NO-NEXT`, `timer-no-next`,
   `NextElapseUSecRealtime`, `timers_re_enabled` and `timers_verified`
   hits only `.fleet/bench7371/` benchmark fixtures and historical
   `docs/reports/` records — no code, config, or workflow. The surviving
   timer surface is the unit files themselves (intake/scout instance
   timers are symlinks into the deploy clone's `systemd/` tree) plus the
   unrelated `fleet-sync`, `fleet-gardener`, `fleet-metrics-export` and
   `daily-digest` timers.
6. **The metric's other half has one live gap.** "Every intake timer in
   config/intake-repos.json enabled, active, with a scheduled next
   firing": `pi-intake@0509`, `pi-intake@fleet-ops` and
   `pi-scout@fleet-ops` are enabled+active; `pi-scout@0509.timer` is
   `disabled`+`inactive` — its instance symlink is absent from
   `~/.config/systemd/user/` while 0509 stays enrolled in
   `config/intake-repos.json`. The reconciler that the file's description
   still names as the converger (`bin/intake-reconcile`) was deleted in
   `ca33faa96`. Filed as plain follow-up issue #8168 rather than worked
   here; whether the scout lane should run for 0509 is an enrolment call,
   and adjacent scout-lane drift is already tracked in #7655/#7835.

## Reconciled against the packet

- *Root-cause the empty/0 read and fix it — re-check next after the
  start, escalate TIMER-START-FAIL on persistent no-next*: root cause
  identified and proven live above (service-active window suppresses the
  calendar next-elapse). The pass itself is deleted — there is no read
  left to fix. The prescribed remedy is recorded in the residual path
  below should a timer-arm check ever be reintroduced.
- *Regression test under tests/heartbeat-timer-arm-no-next.test.sh*:
  nothing to test — the pass and its existing suite
  (`tests/fleet-heartbeat-verify-timers.test.sh`) were both deleted in
  `ca33faa96`. A test for deleted code is not shippable.
- *fleet-ops#533 FLEET-PAUSED guard untouched*: the guard went out with
  the organ; the pause contract survives as the agent-facing quick-minimum
  rule (this repo's `AGENTS.md` live-state section), not a unit.
- *verify commands*: `tests/heartbeat-timer-arm-no-next.test.sh` cannot
  exist (no subject); `bin/fleet-timer-manifest-drift-canary` was deleted
  in `ada87b543`.
- *metric*: `TIMER-NO-NEXT` fires zero times per tick — permanently, by
  deletion of the tick.

## Residual path

If a timer-health check is ever reintroduced, the read must treat
`SubState=running` (triggered service still active, calendar next-elapse
legitimately `(null)`) as healthy, re-read `NextElapseUSecRealtime` only
after the service deactivates, and escalate — not `re_enabled++` — when a
waiting timer still shows no-next. A new organ is a new organ: Nish's
explicit yes under the no-glue rule, and it belongs next to the unit
files, not inside a heartbeat tower that no longer exists.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7405 → #8115,
fleet-ops#7403 → #8111, fleet-ops#7511 →
`docs/reports/timer-manifest-stale-records-observe-close-7511.md`).
