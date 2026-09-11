# fleet-ops#5141 — seat registry reaps LIVE Type=oneshot workers after 300s

Manager plan (difficulty: heavy). One line per acceptance bullet, grouped into 3 phases.

## Scope line

`lib/seat-lib.sh` `_seat_registry_unit_live` only, plus its tests. The identical
defect mirrored in `bin/fleet-heartbeat-undersaturation` `reap_stale_active_seats`
(measures `ActiveEnterTimestampMonotonic`, which is 0 for every `activating`
oneshot) is the same class but outside this issue's acceptance list — filed as a
follow-up issue, not fixed here.

## Live evidence (read-only, this session)

- 63 `wedged pi, reaping seat` lines in `/home/nish/.local/state/pi-packet/watch.log`,
  all `(SubState=start, threshold=300s)`; last at 2026-09-10T23:11:37Z.
- `pi-issue@0509-2373.service` -> `ActiveState=activating SubState=start
  ExecMainStartTimestampMonotonic=1040856606175 TimeoutStartUSec=45min Type=oneshot`.
- 14 `pi-issue@*` activating units vs 7 files in `active-seats/`.
- `ActiveEnterTimestampMonotonic` = 0 on that live activating unit; uptime 1041146s.

## Phases

- [x] phase 1: accept 1 + 2 — `_seat_registry_unit_live` bounds an `activating/start` oneshot by the unit's own `TimeoutStartSec` (`_seat_duration_to_s` + `_seat_liveness_bound_s`, fallback `PI_SEAT_ACTIVATING_MAX_S` on infinity/0/unparseable); the hardcoded `SubState == "start"` -> 300s branch is deleted; `ExecMainStartTimestampMonotonic=0` and `SubState=auto-restart` stay fail-closed at the short bound; comment cites #5141/#993/#1361. (Salvaged from the prior run's banked worktree — commit `salvage: bank uncommitted work`; rebased onto current main 2026-09-11.)
- [x] phase 2: accept 3 + 4 — new `tests/seat-registry-liveness.test.sh` with stubbed `systemctl`: (a) `activating/start` 400s and 40min LIVE, (b) 50min reaped, (c) `ExecMainStartTimestampMonotonic=0` 6min reaped, (d) `activating/auto-restart` not live; plus the drift block asserting the liveness bound is not below `TimeoutStartSec` in `systemd/pi-issue@.service`; hosted from the ci.yml-listed `tests/seat-lib.test.sh` (manager amendment: the seat-lib suite host, not ci-standards-audit — seat-lib.test.sh already hosts every seat-lib child test and is directly listed). Review fix: `unset -f systemctl awk` hermeticity added (fleet-ops#449 precedent) — the host's exported functions shadowed the child's PATH stub.
- [x] phase 3: accept 5 + 6 — proved (a) red on `origin/main`'s lib (FAIL: 400s unit reaped at threshold=300s) and green after; `tests/seat-lib.test.sh`, `fleet-seat-recovery-units.test.sh`, `pi-issue-run-per-seat-timeout.test.sh` all green; `git diff origin/main -- config/seat-caps.json systemd/ .github/workflows/` empty; nothing written under `~/.config/systemd/user`; follow-up filed as fleet-ops#5263 (`reap_stale_active_seats` ages from ActiveEnterTimestampMonotonic=0 and additionally `systemctl stop`s the unit). Review fix: `state` moved into the top `local` — it was assigned before `local state` and leaked a global into seat-lib.sh sourcers.

## Owner's decisions

- Dropped the planner's optional named pin in `tests/p14-test-listing-gate.test.sh`:
  the gate's transitive-closure check already covers a test hosted from a listed
  test, so the pin is extra machinery for a convention already enforced.
- Dropped the planner's `tests/seat-lib-org-reserve.test.sh` run from phase 1's
  list: it never reaches the activating branch.

## Review adjudication (manager, post-salvage)

- Act on #1 (fixed, in-flight): liveness test's `now_s > 3600` uptime guard would fail a fresh GitHub runner (minutes of uptime) — the #94/#98 auto-revert class. Fix: keep `unset -f systemctl awk`, add a test-local awk floor shim (3700s) so lib clock and `mono_ago` share one fakeable clock; drop the dead guard.
- Act on #2 (fixed, in-flight): auto-restart comment overclaimed ("a normal restart keeps its seat") — age runs from process start, so a >300s-at-crash unit is reaped mid-wait. Behaviour kept (spec fail-closed; pi-issue-run re-picks the seat on restart), comment corrected.
- Consider #3 (no change): with ExecMainStart=0 the ts fallback is ActiveEnterTimestampMonotonic=0 → `return 0` live; on real systemd the 300s no-process bound can never fire (identical to main — parity, not a regression). `StateChangeTimestampMonotonic` would make it real; out of scope, noted for #5263's author.
- Consider #4 (fixed, in-flight): `for tok in $v` glob-expands against cwd; anchored regex already fails closed, but `read -ra` removes the expansion entirely. Cheap, taken.
- Noted #5-8: ms floor-division, int64 wrap, /proc/uptime-vs-CLOCK_MONOTONIC skew, stub `--type=` non-parsing — all fail-safe or unexercised; recorded, no change.

## Stall log

- Prior unit run died at StartLimitBurst mid-phase-2; salvage banked lib + test commits. This run transplanted the net diff (git apply --3way) onto the recreated claim branch (= current main b963c45) after `.fleet/plan.md` collided with #5140's scratch file — resolved by restoring this issue's plan from the pre-rebase tip.
