# Host play converge

The deploy: `ansible/host.yml` applies on a fresh Ubuntu 24.04 host, and a second run changes nothing.

## Sub-features

- `converge` applies every task from an empty host.
- `idempotence` is the second run, which reports `changed=0`.

## How to get to it (user POV)

- A merge to main starts `deploy-box.yml`, and `fleet-host-config.service` runs the play through ansible-pull.
- The nightly timer runs the same service.

## Driving it with podman exec

- **Converge.** The Launch command in `SKILL.md`. In the rootless container `converge.log` holds a `PLAY RECAP` line with `failed=` above 0, and the first failed task is `Apply tmpfiles on every run` (see Gotchas). Every task before it is proven, and that task and every task after it are not run. `converge rc=0` happens only on a host with a writable `/sys`.
- **Idempotence.** Run the converge command again, into `$EV/converge2.log`. The recap line reads `changed=0`.
- **Proof.** `grep -E '^localhost ' $EV/converge.log $EV/converge2.log`.

## Gotchas

- The rootless container has `/proc/sys` and `/sys` read-only, so `Apply tmpfiles on every run` (tasks/system.yml) stops on `/sys/module/zswap/parameters/*`. Report every task before it as proven, and that task and the rest as not run.
- The tasks marked `# noqa: no-changed-when` report `changed` on every run, so idempotence fails until #11706 is done.
- The real box runs the play from `/var/lib/fleet-ops/repo`. The container runs it from `/srv/fleet-ops`.
