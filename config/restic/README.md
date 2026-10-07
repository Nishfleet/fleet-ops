# Restic backup include list

`restic-r2-backup.service` used to back up
`/home/nish /etc /root /srv /usr/local /var/spool/cron`, minus a hand-written
exclude file that lived only at `/etc/restic/netcup-r2-excludes`, root-owned
and tracked in no repo. Everything new under `/home/nish` therefore landed in
the snapshot until somebody remembered to exclude it, and that is how the
source grew from 9 GiB in September to 56 GiB on 2026-10-07 without anyone
noticing (fleet-ops#9360). Hand-fixing the exclude list took 24 GiB down to
7.6 GiB per copy, but the next unexcluded cache would undo it.

The list is now the other way round. `include.txt` *is* the backup, and
anything not on it is not backed up. A new 50 GiB runner work dir, an ollama
model or a Go toolchain cannot grow the snapshot any more, because it is not
in the list.

`exclude.txt` is deliberately short. It drops only caches *inside* included
directories, the root-only `/etc` secrets that no run should store in an
off-site backup, and the restic repository password itself.

Sizes below are `du -sh` on the netcup box, 2026-10-07. The reference snapshot
(`c3bca658`) cannot be read from a worker: `/etc/restic` is mode 0700
root-owned and holds `RESTIC_PASSWORD`, so the numbers are the live
filesystem, which is what the next snapshot is taken from.

## Files

- `include.txt` — the backup list, read by `restic backup --files-from`
- `exclude.txt` — short list of patterns dropped inside included directories
  and in `/etc`, read by `restic backup --exclude-file`

Both are deployed to `/etc/restic/` by `ansible/host.yml` in
`fleet-host-config.service` (on every push to `main` and daily). No restart or
daemon-reload needed: the unit reads them fresh on every run.

`/etc/restic` is *not* in the playbook's `owned_dirs`: it also holds the
hand-installed R2 credentials (`netcup-r2.env`) and the retired
`netcup-r2-excludes`, and the daily drift check would fail on them.

## What is kept, and why

| Path | Size | Keep reason |
| --- | --- | --- |
| `/home/nish/.config` | 287 MiB | credential stores and per-tool state (seat keys, gh auth, Cloudflare tokens, rclone remotes, systemd units). 280 MiB of it is browser profiles and the opencode cache, which `exclude.txt` drops. |
| `/home/nish/.ssh`, `.gnupg`, `.git-credentials`, `.netrc` | 64 KiB | private keys and credentials. No way to regenerate them; losing them locks Nish out of GitHub and Cloudflare. |
| `/home/nish/workspaces/tooling/nish-vault` | 35 MiB | the vault, and `_system/shared-memory` + `_system/agent-memory` inside it. The standing rules name the vault as the durable memory. |
| `/home/nish/workspaces/agent-memory` | 24 KiB | the one-fact-per-file agent memory dir. |
| `/home/nish/nish-vault` | 40 KiB | the agent drop inbox on the home directory. Small, but it is named `nish-vault`, so assume it is meant to be kept. |
| `/home/nish/workspaces/agent-state/_system` | 20 KiB | shared agent memory. |
| `/home/nish/workspaces/agent-state/backups` | 1.4 GiB | the LiteLLM `pg_dump` the unit takes before every run, plus rollback snapshots. `docs/RUNBOOK.md` relies on it being in the restic path. |
| `/home/nish/.hermes` | 5.1 GiB, ~100 MiB kept | hermes facts: `state.db` and its WAL, `state-snapshots/`, `skills/`, `kanban.db`, `shared-state.db`, `backups/`. `exclude.txt` drops the agent checkout, the tool trees, caches, installs and logs. |
| `/home/nish/.pi/agent` | 1.4 GiB, ~100 MiB kept | locally maintained skills, prompts, agents and extensions. `sessions/` and `npm/` are dropped. |
| `/home/nish/.local/share/fleet-litellm-postgres` | 1.9 GiB | the LiteLLM database itself. The unit's `pg_dump` is the consistent copy; this is the second, raw copy that survives a corrupt dump. |
| `/home/nish/.local/share/fleet-litellm-redis` | 8 KiB | Redis data for the same service. |
| `/home/nish/.local/share/fleet-grafana` | 486 MiB, 4.5 MiB kept | `grafana.db`: users, annotations, dashboard state, unified-search. `plugins/` is reinstalled from the catalog. |
| `/home/nish/.local/share/drive` | 53 MiB | labelled eval train and held-out cases. A different model family wrote them; re-running the harness is not the same data. |
| `/home/nish/.local/share/containers/storage/volumes` | 83 MiB | podman container volumes. |
| `/etc` | 10 MiB | units, ssh, polkit, sysctl, cron, rclone and prometheus config. |
| `/root` | ~4 KiB | root's scripts and keys. |
| `/srv/aiostreams` | 153 MiB | application data. |
| `/usr/local` | 158 MiB | hand-installed `gh` and `node`, which no package owns. |
| `/var/spool/cron` | 8 KiB | cron jobs (the only cron spool on Ubuntu). |

Sum of the kept set: about 3.9 GiB before compression, which restic reports as
the snapshot's restore size (see `Verification` on the PR). That is inside the
7 GiB target the issue sets and far inside the 10 GiB hard stop.

Measured on 2026-10-07 with these two lists against a scratch repository
(`Verification` on the PR carries the numbers). The first backup added 3.30 GB
and reported a restore size of 3.813 GiB over 15,180 files. Adding the vault and
the agent-memory dir to the list added 82.5 MB more, for a restore size of
3.852 GiB over 16,861 files. `restic check --read-data` found no errors. One
file per included top-level path compared byte-for-byte after `restic dump`
and after `restic restore`.

`/root`, `/var/spool/cron` and the root-owned podman volume dirs are on the
list and are measured from the box (`du`), because a worker cannot read them.
They are readable by the live unit, which runs as root.

## What is dropped, and why

| Path | Size | Drop reason |
| --- | --- | --- |
| `/home/nish/workspaces` and `/home/nish/workspaces/tooling` (except the vault, agent-memory and the two agent-state dirs above) | 35 GiB + 463 MiB | code and work dirs. `products/`, `agent-worktrees/`, `_archive-bundles/` and every `wt-*`/`fleet-ops-*` checkout are `git clone` from a remote; except `nish-vault` (above) they are rebuildable. `agent-state/tools`, `retired-checkouts*`, `branch-prune`, `glue-sweep`, `alert-repair` and the other per-run work dirs are regenerated by the next run. |
| `/home/nish/.local/share/agent-runner`, `devin`, `actions-runner`, `fleet-ci-runner` | 48 + 5.7 + 4.4 + 3.9 GiB | runner work dirs and their caches. The issue names these as the main cause of the growth. |
| `/home/nish/.local/share/leviathan` | 2.3 GiB | the session-log search index. Rebuilt from the sessions it indexes. |
| `/home/nish/.local/share/{git,gh,uv,semgrep-venv,go,gotool,go-toolchain,opencode,cursor-agent,blender-4.2.1,tirith,last30days,fleet-ops-rule-gap,drive-issue-582}` | ~3.5 GiB | versioned binaries, installed plugins and tool caches. |
| `/home/nish/.ollama` | 4.2 GiB | model weights, re-downloaded from their source. |
| `/home/nish/go`, `gopath`, `go-mod-cache`, `go-workspace`, `gopath-go`, `go1.24.0.linux-amd64.tar.gz` | ~3.5 GiB | toolchains and module caches, reinstalled by `go build`. |
| `/home/nish/.cache`, `.npm`, `.cargo/registry`, `__pycache__`, `/var/tmp`, `/tmp` | ~16 GiB | caches. |
| `/home/nish/.claude`, `.codex`, `.cursor`, `.juicefs`, `.bun`, `.nvm`, `.cua`, `.dotnet`, `.zcode`, `.devin-server`, `.wrangler`, `.promptfoo` | ~7.5 GiB | session transcripts and logs (the vault is the memory, leviathan is the index), installed binaries and tool caches. `.promptfoo/promptfoo.db` is eval *results*, reproducible from the drive cases above. |
| `/home/nish/tool`, `.wix`, `Documents`, `backups`, `Downloads`, `Desktop`, `Music`, `Videos`, `Pictures`, `scratch` | ~360 MiB | personal scratch and retired files, not fleet state. The 6.7 MiB in `~/backups` is an old dump superseded by `agent-state/backups`. |
| dotfiles at the top of `/home/nish` (`.bashrc`, `.viminfo`, `.zcompdump`, `.Xauthority`, …) | < 1 MiB | part of the OS image, not of the fleet state. |
| `/var/lib`, `/var/log` | — | duplicated by the `litellm.dump` and the host config kept above. Nothing in them is unreproducible. |

Two deliberate exclusions inside a kept path, neither of which the old
snapshot should have carried:

- `/etc/restic/` — `RESTIC_PASSWORD` and the R2 keys. They unlock the very
  repository they would be stored in. A restore asks the operator for them.
- `/etc/shadow`, `/etc/ssh/ssh_host_*_key`, `/etc/sudoers.d/`,
  `/etc/ssl/private/` — hashes and private keys are the classic "not in an
  off-site backup" set: a leaked copy is impersonation and offline cracking,
  and regeneration is cheap and documented.

If a path is missing from the kept table and it cannot be rebuilt, add it to
`include.txt` (below). If it is fleet state and you are unsure, ask.

## Adding a path

1. Add the absolute path on its own line in `include.txt`, and add its size and
   keep reason to the table above. The table is the record of why the list is
   what it is; an unexplained path is how the old exclude list drifted.
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
   size that would be new. If the path brings caches with it, add patterns to
   `exclude.txt`.
3. Commit and push. The next `fleet-host-config` run puts the file on the box.

## The size guard

`rootfs/etc/systemd/system/restic-r2-backup.service.d/10-size-guard.conf` adds
an `ExecStartPre` that runs the same backup as a **dry run** and reads
`data_added` from its JSON summary:

```
ExecStartPre=… restic backup --dry-run --json --files-from=… | jq -s '… halt_error(78) …'
```

- Over `SIZE_GUARD_MAX_BYTES` (default `2147483648` = 2 GiB) the unit exits
  **78** before `ExecStart` runs, so nothing is uploaded and the weekly
  `restic-r2-locked-copy.service` has nothing new to copy.
- A dry run uploads no data and computes `data_added` against the repository's
  existing blobs, so the number it prints is the dedup-aware amount of *new*
  data. A run whose data is already in the bucket reports 0 and passes.
- The guard is a pre-flight, not a post-hoc check. restic has no
  `--max-repo-size`, `--exclude-larger-than` is per-file, and `restic --json`'s
  status lines carry no `data_added` (only the final summary does), so a dry
  run is the only stock way to know the size *before* uploading. That is why
  the unit checks first and uploads second.
- The guard is fail-closed on read errors. If restic cannot read a path on the
  include list its exit status is 3, and because the pipeline keeps stderr out
  of jq the pipeline returns 3, so the unit fails and no backup is taken. That
  is the safe direction: a snapshot that silently skipped a kept path is not a
  backup. A jailed worker cannot read `/root`, `/var/spool/cron` and about 37
  root-only files under `/etc`, so its dry run fails with exit 3 even when the
  size is fine. A local dry run therefore adds those paths to an extra local
  exclude file, never to the shipped list.
- The `ExecStart` is overridden so the unit reads the tracked lists instead of
  the retired `/etc/restic/netcup-r2-excludes`. Change the paths in
  `include.txt`, not in the unit.

A guard trip is a **failed unit**. That is the point: it is the urgent signal.
Check it with `systemctl --failed` (these are system units, not user units, so
`--user` shows nothing) or `systemctl status restic-r2-backup.service`, then
`journalctl -u restic-r2-backup.service -b`. A failed backup unit must be
repaired in the same turn by fleet rule, exactly like any other failed unit.

### Switching it off

For one run, on the box:

```bash
systemctl edit restic-r2-backup.service      # add
#   [Service]
#   Environment=SIZE_GUARD_MAX_BYTES=0
systemctl start restic-r2-backup.service
```

`SIZE_GUARD_MAX_BYTES=0` disables the check, so the unit backs up
unconditionally. `systemctl revert restic-r2-backup.service` removes the
override again. This edits the unit's own environment, so there is no way to
turn the guard off by pointing the unit at a different list or a different
repository: a temporary 1 MiB limit for a drill is `systemctl edit` plus a
`systemctl revert`, and nothing else.

The companion alarm is the Cloudflare R2 bucket-size alarm (#9355). The guard
is the cheap stop before the upload; the alarm catches a repository that grew
over many runs, each of them under the threshold.

## Not deployed from here

The restic units themselves are box-only, installed by root under
`/etc/systemd/system/restic-r2-*` and deliberately not tracked here: the
tracked copies had silently diverged from what runs on the box, and a
`fleet-host-config` run would then "fix" live behaviour. The only unit file
this repo ships is the additive `10-size-guard.conf` drop-in, which keeps the
box-only unit's pg_dump, unlock, flock, hardening and heartbeat and adds the
guard.

These must already exist on the box; they hold credentials and stay
hand-installed:

- `/etc/restic/netcup-r2.env` — `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (deliberately excluded from the
  backup, see above)
- `/etc/restic/netcup-r2-excludes` — the retired exclude list, kept until the
  next restore test proves the new ones
- `/etc/tiny-studio/heartbeats.env` — `HC_BACKUP_URL`, `HC_LOCKED_COPY_URL`,
  `HC_MAINTAINANCE_URL`
- `/etc/rclone/tiny-studio-r2.conf` — the `live:` and `locked:` remotes

If `/etc/restic/netcup-r2.env` goes missing the unit does not run at all
(`ConditionPathExists`), which is the intended failure mode: no credentials, no
backup, no silent empty snapshot.

## After the merge: one operator step on the box

`fleet-host-config.service` copies `include.txt` and `exclude.txt` into
`/etc/restic/` and then fails on any file under a directory it owns that the
repo does not ship and `/etc/fleet-ops/box-only` does not list. At 15:07 IST on
2026-10-07 that check failed on three restic files installed by hand on the
box, so the deploy left `fleet-host-config.service` in a `failed` state:

```
/etc/systemd/system/restic-r2-backup.service.d/10-size-guard.conf,
/etc/systemd/system/restic-r2-locked-copy.service.d/10-needs-backup.conf,
/etc/systemd/system/restic-r2-size-guard.service
```

This PR ships the first one under `rootfs/`, so the deploy puts the tracked
copy back over the hand-installed one. The other two are box-only restic
plumbing and stay box-only: add both paths to `/etc/fleet-ops/box-only`, one
per line, or delete `restic-r2-size-guard.service` if the separate guard unit
is not wanted (the tracked drop-in runs the same dry run inline and never
starts it).

Until that step is done, the daily drift run fails again on every merge. That
is the intended signal that a root-owned file changed by hand.
