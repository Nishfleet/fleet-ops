# Restic Backup Configuration

This directory contains the restic backup include and exclude lists for the netcup VPS backup to Cloudflare R2.

## Files

- `include.txt` — Paths to back up (used with `restic backup --files-from`)
- `exclude.txt` — Exclude patterns for caches and rebuildable artifacts (used with `restic backup --exclude-file`)

## How to add a path to the backup

1. Edit `include.txt` and add the absolute path on a new line
2. If the path contains caches or rebuildable files, add exclude patterns to `exclude.txt`
3. Test with a dry run:
   ```bash
   restic backup --files-from /etc/restic/include.txt --exclude-file /etc/restic/exclude.txt --dry-run
   ```
4. Commit and push. The fleet-host-config ansible playbook will deploy the changes to `/etc/restic/`

## How to switch off the size guard

The backup unit has a size guard that fails when `data_added` exceeds 2 GiB. To disable it:

1. Edit `/etc/systemd/system/restic-r2-backup.service.d/10-size-guard.conf` (created by ansible)
2. Change `SizeGuard=yes` to `SizeGuard=no`
3. Run `systemctl daemon-reload`

Or temporarily for one run:
```bash
systemd-run --property=Environment=SIZE_GUARD=no --user /usr/bin/restic backup ...
```

## Size guard details

The guard runs after `restic backup --json` and checks the `data_added` field. If it exceeds 2 GiB, the unit exits with code 78 (configuration error), which appears in `systemctl --user --failed`.

This prevents unnoticed growth like the 9 GiB → 56 GiB incident in September 2026.

## Deploying changes

Changes to this directory are deployed by the `fleet-host-config` ansible playbook (runs on every push to main and daily). The playbook copies `config/restic/` to `/etc/restic/` on the host.

To force a deploy:
```bash
systemctl start fleet-host-config.service
```

## Restoring files

To restore a file from the latest snapshot:
```bash
restic -r r2:netcup-backups restore latest --target /tmp/restore --include /path/to/file
```

## Checking repository integrity

```bash
restic -r r2:netcup-backups check
```

## Current backup targets (from include.txt)

- `/home/nish/.config/fleet-ops` — Credentials, keys, LiteLLM config
- `/home/nish/.config/fleet-worker` — Worker configuration
- `/home/nish/.config/gh` — GitHub CLI config
- `/home/nish/.config/cloudflare` — Cloudflare credentials
- `/home/nish/.config/rclone` — Rclone config
- `/home/nish/.config/systemd` — User systemd units
- `/home/nish/nish-vault` — Vault and agent memory
- `/home/nish/workspaces/agent-state/_system` — Agent memory
- `/etc` — System configuration
- `/root` — Root home directory
- `/var/spool/cron` — Cron jobs
- `/home/nish/.local/share/containers/storage/volumes` — Podman volumes
- `/srv/aiostreams` — Application data