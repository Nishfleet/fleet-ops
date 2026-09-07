# Bare-metal fleet rebuild runbook

fleet-ops#1135. Box death during Nish's 2026-08-28..09-08 absence would page a
human who is on vacation. This runbook and the manifest make the rebuild
mechanical, versioned, and provable.

The source of truth is `config/bare-metal-rebuild-manifest.json`. The rebuild
script is `bin/fleet-bare-metal-rebuild`. The drill that proves the manifest is
complete is `bin/fleet-bare-metal-rebuild-drill`, scheduled by
`systemd/fleet-bare-metal-rebuild-drill.timer`.

## What we assume

- The restic backup in Cloudflare R2 is intact. See `bin/fleet-restore-drill`
  (#388) for the proof that the backup mechanism works.
- You have the restic repository password and `RESTIC_REPOSITORY` env. The
  location is in the manifest; the value is not.
- The new box is a fresh Ubuntu 24.04 LTS install with SSH (Tailscale-only)
  working.
- This is a one-person fleet on one box; high availability is explicitly
  rejected until revenue exists. See `docs/resilience-blueprint.md`.

## Rebuild order

Do not skip a step. Each step has a verification command.

### 1. Fresh Ubuntu baseline

- Install from the netcup ISO or rescue image.
- Create the non-root user `nish` with UID 1000, home `/home/nish`, shell
  `/bin/bash`.
- Add `nish` to `sudo` and `docker` groups.
- Lock SSH: no root login, no password auth, no public `0.0.0.0:22`. See
  `docs/break-glass-access.md` if you lose Tailscale.
- Set timezone to `Asia/Kolkata` (IST).
- Enable `unattended-upgrades` for security updates only.

### 2. Network and Tailscale

- Bring the box online.
- Install Tailscale and authenticate with the existing tailnet.
- Confirm `tailscaled.service` has `Restart=always` and `StartLimitIntervalSec=0`.
- Confirm `ss -ltn | grep :22` only shows Tailscale addresses (100.x or fd7a:*).

### 3. Install base packages

Run on the box as root or with sudo:

```
apt-get update
apt-get install -y systemd systemd-oomd git git-lfs jq curl ca-certificates \
  iproute2 util-linux openssl python3 python3-pip python3-venv \
  python3-requests restic tailscale prometheus prometheus-node-exporter \
  prometheus-alertmanager docker-ce docker-ce-cli docker-compose-plugin \
  build-essential python3-dev
```

- Docker and Tailscale apt repos may need to be added on a fresh install; the
  manifest lists them. Get the repo keys from the vendor docs.
- Enable `systemd --user` for the `nish` user:
  `loginctl enable-linger nish`.

### 4. Restore the home tree from restic

The restic credentials live in `/etc/restic/hostinger-r2.env`.

```
sudo mkdir -p /etc/restic
# copy the env file from your password manager or the old box
sudo install -m 0600 -o root -g root /dev/null /etc/restic/hostinger-r2.env
# paste the env contents, then:
sudo chmod 0600 /etc/restic/hostinger-r2.env

# Restore /home/nish, /etc, /root and /usr/local from the latest snapshot.
# Read the manifest `backup.restore_command` for the exact invocation.
```

Restoring `/etc` and `/usr/local` brings back the system restic units, the
prometheus rules, and the `~/.local` tree (which includes most agent harnesses).

### 5. Reinstall any missing manual tools

The manifest lists `manual_tools`. The most common ones to reinstall by hand
after a restore are:

- `claude` at `/usr/bin/claude` (vendor installer, outside the restic backup
  paths).
- `gh` at `~/.local/bin/gh` if the binary was not in the backup.
- `pi` and `command-code` via `npm` under `~/.local/lib/node_modules`.

Verify each with `which` and `--version`.

### 6. Clone fleet-ops and the product repos

```
mkdir -p /home/nish/workspaces/tooling /home/nish/workspaces/products /home/nish/workspaces/.mirrors
git clone https://github.com/Nishfleet/fleet-ops.git \
  /home/nish/workspaces/tooling/fleet-ops-deploy-clone
cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone
git checkout main
```

Then clone or restore the product checkouts listed in
`config/intake-repos.json`. As of this manifest the enrolled repos are `0509`
and `fleet-ops` itself. Each product repo lives at
`/home/nish/workspaces/products/<name>`.

### 7. Install the fleet from the repo

As `nish`, from the canonical checkout:

```
cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone
./install.sh
sudo ./install.sh --system
systemctl --user daemon-reload
```

`install.sh` symlinks the user units and copies the system-scope entries. It
enables non-template timers and services that have `[Install]`.

`fleet-bare-metal-rebuild --apply` also masks every unit listed in the
manifest's `masked_units` (fleet-ops#2122). These are system units that drive
hardware the VPS does not have — `openipmi.service` on a box with no IPMI BMC.
Masking at provision time stops the unit re-entering failed state and paging
`SystemUnitFailed` every alert cycle. `fleet-bare-metal-rebuild --check`
verifies each is still masked, so drift is caught.

#### Do NOT mask `systemd-networkd-wait-online.service` (fleet-ops#3103)

`systemd-networkd-wait-online.service` must **not** be added to
`masked_units`. The 2026-09-03..04 SystemUnitFailed incident (live 2026-09-04,
fleet-ops#3103) is the counter-example:

- Root cause of the flapping failure: the netplan-generated .network left eth0
  Setup stuck at `configuring` (networkd waited on a DHCPv6 lease that never
  arrives on this host), so wait-online could never reach its online condition
  and exited 1 (Result=exit-code), paging `SystemUnitFailed`. The host was
  online the whole time (eth0 routable, default route via 159.195.212.1).
- The repair is the network/setup completing, not a mask: when eth0 reaches
  `routable (configured)` (networkctl status eth0), wait-online succeeds
  immediately. The static netplan config (no DHCPv6) is correct.
- Masking does not hold here: netplan owns this unit and regenerates + re-enables
  it on netplan apply, silently removing an /etc/systemd/system mask within
  minutes. A `masked_units` entry for it makes `--check`/`live_check` report a
  permanent violation (unit not masked) and cannot keep it masked anyway.
  A 2026-09-04 double-merge briefly added it to `masked_units`; it was reverted
  the same day for these reasons.

If it flaps again, verify eth0 setup completes (`networkctl status eth0` shows
`routable (configured)`), reset the failed state or `systemctl restart
systemd-networkd-wait-online`, and confirm the netplan config stays static only.
Do not mask it and do not hand-edit away netplan's regeneration of it.

### No revival quarantine-boot gate

There is no quarantine-boot gate and none is required. A 2026-08-28 ledger
entry once queued a `hostinger-kvm4` revival with a quarantine-boot
requirement (its disk predates the purges); a same-day entry retired and
**voided** that revival — the box is decommissioned, "never revive, never
investigate", and `netcup-rs2000` is the sole fleet host. The
`masked_units` provision-time masking above is the only mask-all-old-units
gate this host needs, because there is no second host rejoining the fleet.
See `config/rule-enforcement.json` rows `led-2026-08-28-hostinger-kvm4-revival`
(voided) and `led-2026-08-28-hostinger-kvm4-retired`, and the decisions
ledger for 2026-08-28. Closes fleet-ops#2136.

### 8. Verify the live state

Run the drills:

```
/home/nish/.local/bin/fleet-restore-drill
/home/nish/.local/bin/fleet-resilience-drill
/home/nish/.local/bin/fleet-bare-metal-rebuild-drill
```

All three should exit 0. If `fleet-bare-metal-rebuild-drill` does not have a
local `ubuntu:24.04` image, it will LOUD-skip the container proof; pull the
image with `docker pull ubuntu:24.04` and rerun.

### 9. Confirm the fleet is running

```
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers
```

`fleet-heartbeat.timer` must be listed and scheduled. The heartbeat will converge
the rest of the state.

## What the rebuild script does

`bin/fleet-bare-metal-rebuild` reads `config/bare-metal-rebuild-manifest.json`
and automates the safe, repeatable parts:

- `fleet-bare-metal-rebuild --manifest` prints a human summary of the manifest.
- `fleet-bare-metal-rebuild --manifest-check` validates the manifest, checks
  that every `MANIFEST` src exists, checks that files referenced by the manifest
  (runbook, `intake-repos.json`, `MANIFEST`) exist, and checks that the new
  `bare-metal-rebuild` artifacts are in `MANIFEST`.
- `fleet-bare-metal-rebuild --check` audits the live box against the manifest:
  packages, tools, users, checkouts, env files, units.
- `fleet-bare-metal-rebuild --apply --dry-run` lists the steps it would run on a
  fresh box.
- `fleet-bare-metal-rebuild --apply` performs the rebuild on a fresh box. It
  refuses to run on the current live VPS unless you pass `--force-live`.

The script never writes secret values. It expects the restic restore to have
already happened before `--apply` starts unit enablement, or you can pass
`--restore` with the restic env file.

## Container proof

`fleet-bare-metal-rebuild-drill` runs the manifest completeness check inside a
Docker `ubuntu:24.04` container with the repo mounted read-only. This proves the
rebuild script and manifest are sufficient to bootstrap from a fresh Ubuntu
without relying on the existing live box. The container does not write to the
host, does not start the live fleet, and does not touch secrets.

## Break-glass

If Tailscale is down, use the netcup VNC console. See `docs/break-glass-access.md`.

If the VPS is dead and you need a critical fix, the CI runs on GitHub-hosted
`ubuntu-latest` runners; a fix can still land via PR, merge and deploy once the
box is back.
