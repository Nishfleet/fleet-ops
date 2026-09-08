## Summary

The fleet-blind-audit flagged a hand-placed (non-symlink) drop-in at
`~/.config/systemd/user/fleet-hourly-audit.service.d/override.conf`.

This is an **orphaned drop-in dir for a deleted unit** — exactly the same
class as fleet-ops#4112 / #4114 / #4126 / #4151. `fleet-hourly-audit` was
control-plane machinery (unit lived in the control-plane repo's
`systemd/fleet-hourly-audit.service`), deleted 2026-08-23 ("Everything runs
through Pi, directly. No launchers."). The live unit is `not-found`, no
timer is enabled, and the payload it referenced is gone on disk:

- `/home/nish/workspaces/agent-state/lanes/hourly-audit.py` — missing
- `/home/nish/workspaces/agent-state/lanes/gate-retry.sh` — missing
- `/home/nish/workspaces/agent-state/gate/fleet-gate` — missing

There is no unit in the repo to source the override to, so **absorb-into-repo
is wrong**; the correct action (per the issue's "or delete if superseded")
is **delete**. The drop-in dir also carries `.bak` cruft
(`override.conf.bak-timer-sweep-20260811`,
`zz-gate-retry.conf.bak-time-audit-20260812`).

## Change

- `install.sh`: new `remove_orphaned_fleet_hourly_audit_dropin()` that wipes
  the orphaned dir on a live user install, following the established
  orphaned-drop-in idiom.
- `bin/fleet-ops-deploy`: removes the same orphaned dir so a dirty/non-ff
  deploy still clears the invisible leftover.
- `tests/fleet-ops-deploy.test.sh`: new `scenario12b-orphan-hourly` scenario
  + static grep assertions locking the removal in place.

## Verification

Real run results:

- `bin/sgscan` — clean: "No new security findings."
- `tests/fleet-ops-deploy.test.sh` — **exit 0**, including the new
  `scenario12b-orphan-hourly: install.sh removes the orphaned
  fleet-hourly-audit.service.d drop-in dir (fleet-ops#4430)`.
- Full suite: 414/419 passed; 5 failures
  (`fleet-researcher`, `prometheus-retention-40d`, `rule-enforcement`,
  `system-dropins-shape`, `timer-manifest`) reproduce **identically on clean
  origin/main** in the clean deploy clone — all PRE-EXISTING live-state drift
  (live timers not in manifest, live rules-ledger rows, `--system` routing
  against live `/etc` state, and an unrelated researcher dispatch-log timing
  assertion). None are touched by this diff.

`run-proof:` unit/timer/workflow — no new units/timers/workflows are added;
this removes an orphaned drop-in dir only. `install.sh` self-proves via the
deploy test suite above.

`mechanism:` mechanical fix (fleet-ops#366) — shipped a detector+test to
observe-to-close: the orphaned dir is removed by install and by
fleet-ops-deploy, and the scenario proves it.

Closes #4430
