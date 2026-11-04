# System units

Every unit under `rootfs/etc/systemd/system/` and `systemd/` loads on the box, and a started oneshot ends in `Result=success`.

## Sub-features

- `unit-load` shows `LoadState=loaded` for each installed unit.
- `unit-start` starts a unit and reads its result.
- `unit-hardening` gives the `systemd-analyze security` exposure score of a unit file.

## How to get to it (user POV)

- Add or change a unit file, merge, and the deploy installs it and reloads systemd.

## Driving it with docker exec

- **Load.** `docker exec "$RUN" systemctl show -p LoadState,ActiveState fleet-runner@1.service` prints `LoadState=loaded`.
- **Start.** `docker exec "$RUN" systemctl start <unit>`, then `docker exec "$RUN" systemctl show -p Result,ExecMainStatus <unit>` prints `Result=success`.
- **Logs.** `docker exec "$RUN" journalctl -u <unit> -o short-iso --no-pager > $EV/<unit>.journal`.
- **Hardening.** `docker exec "$RUN" systemd-analyze security --offline=yes /etc/systemd/system/<unit>` prints the exposure score.

## Gotchas

- `fleet-runner@N` runs the stub `runsvc.sh` from the stand-ins, so a start proves the unit, not the runner.
- Units that need Tailscale, Docker, real secrets or a GitHub login fail in a container. Report them as not run.
