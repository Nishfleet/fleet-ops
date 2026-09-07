## Summary

The `fleet-e2e-heartbeat` unit is gone (no unit file, no timer, not active; the
control-plane lane `fleet-e2e-heartbeat.py` and the `gate/fleet-gate` binary it
called are also gone). Only the hand-placed drop-in dir
`~/.config/systemd/user/fleet-e2e-heartbeat.service.d/` survived, invisible to a
unit-name-only hunt (fleet-ops#2924 / #1548) because the unit no longer exists.
Not new machinery — there is no unit to source it — so absorb-into-repo is
wrong. Remove the orphaned dir.

This mirrors the fleet-cheap-triage fix (fleet-ops#4126): `install.sh` removes
the orphaned drop-in dir on a user-scope install, `bin/fleet-ops-deploy` clears
it on a dirty/non-ff deploy, and the test suite covers both.

## Verification

- `bash tests/fleet-ops-deploy.test.sh` → exit 0, includes
  `OK: scenario12b-orphan-e2e: install.sh removes the orphaned fleet-e2e-heartbeat.service.d drop-in dir (fleet-ops#4151)`
- `bash -n install.sh bin/fleet-ops-deploy tests/fleet-ops-deploy.test.sh` → clean
- `sgscan` → no new security findings
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → OK

run-proof: `bash tests/fleet-ops-deploy.test.sh` exit 0 (scenario12b-orphan-e2e green)

net-positive-because: adds the same three-file orphaned-drop-in removal pattern
already shipped for fleet-auto-deploy/fleet-auto-ship/fleet-cheap-triage
(fleet-ops#4112/#4114/#4126); the lines are the durable cleanup that closes this
gap-audit finding.

Closes #4151
