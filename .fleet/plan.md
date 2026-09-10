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

- [ ] phase 1: accept 1 + 2 — `_seat_registry_unit_live` bounds an `activating/start` oneshot by the unit's own `TimeoutStartSec` (`_seat_duration_to_s` + `_seat_liveness_bound_s`, fallback `PI_SEAT_ACTIVATING_MAX_S` on infinity/0/unparseable); the hardcoded `SubState == "start"` -> 300s branch is deleted; `ExecMainStartTimestampMonotonic=0` and `SubState=auto-restart` stay fail-closed at the short bound; comment cites #5141/#993/#1361
- [ ] phase 2: accept 3 + 4 — new `tests/seat-registry-liveness.test.sh` with stubbed `systemctl`: (a) `activating/start` 400s and 40min LIVE, (b) 50min reaped, (c) `ExecMainStartTimestampMonotonic=0` 6min reaped, (d) `activating/auto-restart` not live; plus the drift block asserting the liveness bound is not below `TimeoutStartSec` in `systemd/pi-issue@.service`; hosted from the ci.yml-listed `tests/ci-standards-audit.test.sh`
- [ ] phase 3: accept 5 + 6 — prove (a) red on `origin/main`'s `lib/seat-lib.sh` and green after; full touched-suite run; `git diff origin/main -- config/seat-caps.json systemd/ .github/workflows/` empty; nothing written under `~/.config/systemd/user`; file the `fleet-heartbeat-undersaturation` follow-up issue

## Owner's decisions

- Dropped the planner's optional named pin in `tests/p14-test-listing-gate.test.sh`:
  the gate's transitive-closure check already covers a test hosted from a listed
  test, so the pin is extra machinery for a convention already enforced.
- Dropped the planner's `tests/seat-lib-org-reserve.test.sh` run from phase 1's
  list: it never reaches the activating branch.

## Stall log

(none)
