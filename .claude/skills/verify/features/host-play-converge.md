# Host play converge

The deploy: `ansible/host.yml` applies on a fresh Ubuntu 24.04 host, and a second run changes nothing.

## Sub-features

- `converge` applies every task from an empty host.
- `idempotence` is the second run, which reports `changed=0`.

## How to get to it (user POV)

- A merge to main starts `deploy-box.yml`, and `fleet-host-config.service` runs the play through ansible-pull.
- The nightly timer runs the same service.

## Driving it with docker exec

- **Converge.** The Launch command in `SKILL.md`. `converge.log` ends with `PLAY RECAP` and `converge rc=0`.
- **Idempotence.** Run the converge command again, into `$EV/converge2.log`. The recap line reads `changed=0`.
- **Proof.** `grep -E '^localhost ' $EV/converge.log $EV/converge2.log`.

## Gotchas

- A container shares the host kernel, so `Apply a changed sysctl file` (tasks/system.yml) fails with `sysctl -p`. Report every task before it as proven, and that task and the rest as not run.
- The tasks marked `# noqa: no-changed-when` report `changed` on every run, so idempotence fails until #11706 is done.
- The real box runs the play from `/var/lib/fleet-ops/repo`. The container runs it from `/srv/fleet-ops`.
