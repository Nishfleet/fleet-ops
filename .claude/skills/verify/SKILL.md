---
name: verify
description: Prove a fleet-ops change on a fresh box. Applies the real host play (ansible/host.yml) inside a throwaway Ubuntu 24.04 systemd container, drives one feature from features/, and keeps the evidence. Use before review for any change under ansible/, rootfs/, systemd/ or config/, and whenever a PR needs a run-proof.
---

# Verify fleet-ops on a fresh box

The product is the box. A change is proven when the host play applies it on a
fresh Ubuntu 24.04 host, and the feature it touches behaves as its file in
`features/` says. CI only parses the play, so this is the only real run before merge.

The container is rootless Podman with `--systemd=always`
(https://docs.podman.io/en/latest/markdown/podman-run.1.html#systemd-true-false-always).
Never run it `--privileged`: a privileged container writes `/proc/sys` and `/sys`, so the play's
sysctl and tmpfiles tasks would set the kernel values of the machine that runs the test. `NET_ADMIN` in a
rootless container covers only the container's own network namespace, which the nft
tasks need.

Run every command from the repo root. `RUN` names one run. Two runs with
different `RUN` values share nothing.

## Launch

```sh
RUN=verify-$(date +%s); EV="out/verify/$RUN"; mkdir -p "$EV"
podman run -d --name "$RUN" --systemd=always --cap-add=NET_ADMIN \
  docker.io/geerlingguy/docker-ubuntu2404-ansible@sha256:29e6f9d736c3401815d98f626a41c55a54a4ef1edb9d1d1223018746d3acba14 \
  /usr/lib/systemd/systemd
podman exec "$RUN" sh -c 'until systemctl is-system-running | grep -qE "running|degraded"; do sleep 1; done'
podman exec "$RUN" sh -c 'usermod -l nish -d /home/nish -m ubuntu && groupmod -n nish ubuntu && mkdir -p /srv'
podman cp . "$RUN":/srv/fleet-ops
podman exec -i "$RUN" sh -e <<'STANDINS'
H=$(getent passwd nish | cut -d: -f6)
for i in $(seq 1 15); do mkdir -p $H/.local/share/agent-runner/$i; printf '#!/bin/sh\nexec sleep infinity\n' > $H/.local/share/agent-runner/$i/runsvc.sh; chmod 755 $H/.local/share/agent-runner/$i/runsvc.sh; done
mkdir -p /etc/fleet-ops && touch /etc/fleet-ops/tether-off
install -d -o nish -g nish -m 700 $H/.config $H/.config/fleet-ops $H/.config/fleet-ops/seats $H/.config/cloudflare $H/.hermes
printf 'LITELLM_API_KEY=dummy\n' > $H/.config/fleet-ops/seats/litellm-agent.env
printf 'LITELLM_API_KEY=dummy\n' > $H/.config/fleet-ops/seats/litellm-reviewer.env
printf 'TELEGRAM_BOT_TOKEN=dummy\nTELEGRAM_HOME_CHANNEL=1\n' > $H/.hermes/.env
printf 'CLOUDFLARE_API_TOKEN=dummy\n' > $H/.config/cloudflare/deploy-ci.env
printf 'GRAFANA_POSTGRES_PASSWORD=dummy\n' > $H/.config/fleet-ops/grafana-postgres-password.env
chown -R nish:nish $H
STANDINS
podman exec -e ANSIBLE_PIPELINING=1 "$RUN" sh -c 'cd /srv/fleet-ops && ansible-playbook -i localhost, -c local ansible/host.yml' > "$EV/converge.log" 2>&1; echo "converge rc=$?" >> "$EV/converge.log"
```

The play makes its own packages and folders on a fresh host only from #11712 on. Before
that, the run stops at the first apt or promtool task.

Ready means `converge.log` holds a `PLAY RECAP` line. `features/host-play-converge.md`
names the two failures that are expected in a container (the tmpfiles task and the oomd restart handler).

The `STANDINS` block places what a human or a secret places on the real box: runner
registrations (a stub `runsvc.sh` in nish's runner folder, which the play copies to
fleet-runner), dummy secret files, and the tether off marker (tether's
release needs a GitHub login). A run proves nothing about those steps. List them in
the PR body.

## Doctor

```sh
podman exec "$RUN" sh -c 'systemctl is-system-running; ansible --version | head -1; id nish; test -d /srv/fleet-ops/ansible && echo repo-ok'
```

Drive only a container this run started. The image has ansible-core 2.21 and the box
has 2.16, so a module that behaves differently between them is not proven here.

## Drive

Open the feature file that matches the change. Run its steps with `podman exec "$RUN" ...`.

- A unit: `systemctl start <unit>`, then `systemctl show -p Result,ExecMainStatus <unit>`.
- A timer: start its service the same way.
- Idempotence: run the converge command again, into `converge2.log`. The second
  recap's `changed=` count is the number of tasks that are not idempotent.

## Evidence

Write every artifact under `$EV` (`out/` is git-ignored): `converge.log`,
`journalctl -u <unit> -o short-iso`, `systemctl show` output, `stat` of every path
the change writes, and `systemd-analyze security --offline=yes <unit file>`. Prove the
side effect (the file, the unit state), not only the play's `ok`.

## Cleanup

```sh
podman rm -f "$RUN"
ls "$EV"
```

The container goes. The evidence in `$EV` stays.
