## Summary

The fleet-blind-audit flagged a hand-placed (non-symlink) drop-in at
`~/.config/systemd/user/fleet-idea-intake.service.d/override.conf`.

This is an **orphaned drop-in dir for a deleted unit** — exactly the same
class as fleet-ops#4112 / #4114 / #4126 / #4151 / #4430. `fleet-idea-intake`
was hand-placed control-plane machinery (never in the repo `systemd/` tree
or git history). The live unit is `not-found`, no timer is enabled, and the
payload it referenced is gone on disk:

- `/home/nish/workspaces/agent-state/idea-intake/run-intake.py` — missing
- `/home/nish/workspaces/agent-state/idea-intake/run-bootstrap.py` — missing
- `/home/nish/workspaces/agent-state/campaigns/campaignlib.py` — missing
- `/home/nish/workspaces/agent-state/gate/fleet-gate` — missing
- `/home/nish/workspaces/agent-state/lanes/gate-retry.sh` — missing

There is no unit in the repo to source the override to, so **absorb-into-repo
is wrong**; the correct action (per the issue's "or delete if superseded")
is **delete**. The drop-in dir also carries `.bak` cruft
(`override.conf.bak-audit-timeout-20260811`,
`override.conf.bak-timer-sweep-20260811`,
`zz-gate-retry.conf.bak-time-audit-20260812`).

## Change

- `install.sh`: new `remove_orphaned_fleet_idea_intake_dropin()` that wipes
  the orphaned dir on a live user install, following the established
  orphaned-drop-in idiom.
- `bin/fleet-ops-deploy`: removes the same orphaned dir so a dirty/non-ff
  deploy still clears the invisible leftover.
- `tests/fleet-ops-deploy.test.sh`: new `scenario12b-orphan-idea` scenario
  + static grep assertions locking the removal in place.

## Verification

Real run results:

- `bin/sgscan` — clean: "No new security findings."
- `tests/fleet-ops-deploy.test.sh` — **exit 0**, including the new
  `scenario12b-orphan-idea: install.sh removes the orphaned
  fleet-idea-intake.service.d drop-in dir (fleet-ops#4435)`.
- `tests/fleet-ops-deploy-rescue.test.sh` — **exit 0**.
- Full suite: 3 failures (`system-dropins-shape`, `rule-enforcement`,
  `timer-manifest`) reproduce **identically on clean origin/main** in a
  clean worktree — all PRE-EXISTING live-state drift (live timers not in
  manifest, `--system` routing against live `/etc` state). None are touched
  by this diff.

`run-proof:` unit/timer/workflow — no new units/timers/workflows are added;
this removes an orphaned drop-in dir only. `install.sh` self-proves via the
deploy test suite above.

`mechanism:` mechanical fix (fleet-ops#366) — shipped a detector+test to
observe-to-close: the orphaned dir is removed by install and by
fleet-ops-deploy, and the scenario proves it.

Closes #4435
