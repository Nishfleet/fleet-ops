# Restic backup include list

The netcup VPS backup (`restic-r2-backup.service`, a box-only unit) used to
back up `/home/nish /etc /root /srv /usr/local /var/spool/cron` minus a
hand-written exclude file at `/etc/restic/netcup-r2-excludes`. Every new thing
under `/home/nish` was in scope until someone remembered to exclude it, which
is how the snapshot grew from 9 GiB to 56 GiB.

The path list is now the other way round: `include.txt` is the whole list, and
anything not on it is not backed up. New junk cannot grow the backup, because
nothing under an included directory is picked up unless it is on the list.

`exclude.txt` is deliberately short. It only drops caches *inside* included
directories (`--exclude-caches` already handles the well-known ones) plus the
unreadable-by-restic secrets that would otherwise fail the run.

## Files

- `include.txt` — the backup list, read by `restic backup --files-from`
- `exclude.txt` — short list of patterns dropped inside included directories,
  read by `restic backup --exclude-file`

Both are deployed to `/etc/restic/` by `ansible/host.yml` in
`fleet-host-config.service` (on every push to `main` and daily). No restart or
daemon-reload needed: the backup unit reads them fresh on every run.

`/etc/restic` is *not* in the playbook's `owned_dirs`: the R2 credentials
(`netcup-r2.env`) and the retired `netcup-r2-excludes` are hand-installed there
and the drift check would fail on them every day.

## What is in the list, and why

| Path | Why |
| --- | --- |
| `/home/nish/.config/fleet-ops` | seat keys, LiteLLM config, keystone healthcheck URL |
| `/home/nish/.config/fleet-worker` | worker prompts and config |
| `/home/nish/.config/gh` | GitHub auth state |
| `/home/nish/.config/cloudflare` | Cloudflare tokens (worker/cloudflare API) |
| `/home/nish/.config/rclone` | rclone remote definitions |
| `/home/nish/.config/systemd` | nish's own units (blacksmith-flip, leviathan, fleet timers) |
| `/home/nish/nish-vault` | vault and agent memory |
| `/home/nish/workspaces/agent-state/_system` | shared agent memory |
| `/home/nish/workspaces/agent-state/backups` | `litellm.dump`, the pg_dump the unit takes before every run |
| `/etc` | system configuration, ssh keys, units, polkit, sysctl |
| `/root` | root's scripts and keys |
| `/var/spool/cron` | cron jobs (no other cron spool on Ubuntu) |
| `/usr/local` | hand-installed `gh` and `node` |
| `/home/nish/.local/share/containers/storage/volumes` | podman container data |
| `/srv/aiostreams` | application data |

Dropped from the old coverage, and why:

- `/home/nish/workspaces`, `/home/nish/worktrees`, `node_modules`,
  `go-mod-cache`, `gopath` — code, rebuildable by `git clone` and
  `go mod download`, and the largest reason for the growth
- `/home/nish/.cache`, `.npm`, `.local/share/leviathan`, `.pi/agent/sessions` —
  caches and transcripts, rebuilt constantly
- `/home/nish/backups` (127 MiB) and `Downloads`, `Desktop`, `Music`,
  `Videos`, `Pictures`, `scratch` — personal scratch, not fleet state
- `/var/lib` (postgres data), `/var/log`, `/var/tmp` — rebuildable or duplicated
  by the `litellm.dump` the unit already takes

If a path is missing from this table and it cannot be rebuilt, add it to
`include.txt` (below). If it is fleet state and you are unsure, ask.

## Adding a path

1. Add the absolute path on its own line in `include.txt`.
2. Dry-run against a scratch repository before it goes anywhere near R2:

   ```bash
   export RESTIC_PASSWORD=$(mktemp -u)          # scratch repo, throw away after
   export RESTIC_REPOSITORY=/tmp/restic-check
   restic init
   restic backup --dry-run --json \
     --files-from=config/restic/include.txt \
     --exclude-file=config/restic/exclude.txt \
     --exclude-caches | jq '{data_added, total_bytes_processed, total_files_processed}'
   ```

   Read `total_bytes_processed` as the size of everything, `data_added` as the
   size that would be new. Add exclude patterns to `exclude.txt` if the path
   brings caches with it.
3. Commit and push. The next `fleet-host-config` run puts the file on the box.

## The size guard (hard stop)

`restic-r2-size-guard.service` runs the same backup as a **dry run**
(`restic backup --dry-run --json`, which uploads nothing) and `jq` reads its
summary. The unit fails with exit **78** when either limit is crossed:

| Limit | Default | Summary field |
| --- | --- | --- |
| New data this run | `SIZE_GUARD_MAX_BYTES=2147483648` (2 GiB) | `data_added` |
| Snapshot restored size | `SIZE_GUARD_MAX_RESTORED_BYTES=10737418240` (10 GiB) | `total_bytes_processed` |

How it stops the growth:

- `restic-r2-backup.service.d/10-size-guard.conf` gives the backup unit
  a last `ExecStartPre=systemctl start restic-r2-size-guard.service` (a oneshot
  start waits and returns the guard's exit status). A failed guard fails the
  backup unit before `ExecStart`, so **nothing over the limit is uploaded** and
  the heartbeat ping is not sent. It runs after the pg_dump line, so the fresh
  dump is part of what is measured.
- `restic-r2-locked-copy.service.d/10-needs-backup.conf` gives the locked copy
  `Requires=` the backup unit, so the copy into the `-locked` bucket is
  **skipped** when the backup fails. A locked-copy run now starts a guarded
  backup first.
- The failed unit is the signal: `systemctl list-units --state=failed` shows
  `restic-r2-size-guard.service` and `restic-r2-backup.service`. Find out what
  grew (`journalctl -u restic-r2-size-guard`), fix the include/exclude list,
  then `systemctl reset-failed 'restic-r2-*'` and start the backup again.
- The guard is a pre-flight because restic has no repository size limit and
  its `--json` status lines carry no `data_added`; only the final summary
  does. `data_added` from a dry run is dedup-aware: it counts only blobs the
  repository does not have yet.

### Changing a limit

Never edit the `jq` line. Override the number with a drop-in:

```bash
sudo systemctl edit restic-r2-size-guard.service
#   [Service]
#   Environment=SIZE_GUARD_MAX_BYTES=4294967296
sudo systemctl revert restic-r2-size-guard.service   # back to the defaults
```

The companion alarm is the Cloudflare R2 bucket-size alarm (#9355). The guard is
the cheap stop before the upload; the alarm catches a repository that grew over
many runs, each under the threshold.

## Not deployed from here

These must already exist on the box; they hold credentials and stay
hand-installed:

- `/etc/restic/netcup-r2.env` — `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- `/etc/restic/netcup-r2-excludes` — retired, kept until the next restore test
  proves the new lists
- `/etc/tiny-studio/heartbeats.env` — `HC_BACKUP_URL`, `HC_LOCKED_COPY_URL`,
  `HC_MAINTAINANCE_URL`
- `/etc/rclone/tiny-studio-r2.conf` — the `live:` and `locked:` remotes

If `/etc/restic/netcup-r2.env` goes missing the unit does not run at all
(`ConditionPathExists`), which is the intended failure mode: no credentials, no
backup, no silent empty snapshot.