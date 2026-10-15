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

The first table below, "Inventory of snapshot c3bca658", is measured from the
reference snapshot itself (`restic ls --json --recursive c3bca658`, run as root
on the box on 2026-10-07, summing file sizes per path). The "kept" and
"dropped" tables after it carry live `du -sh` sizes, which is what the next
snapshot is taken from.

## Inventory of snapshot c3bca658

Snapshot `c3bca658` (2026-10-07 12:38:43 IST, after the hand-fix to the old
exclude file): 123,634 files, 6.425 GiB restore size
(`restic stats c3bca658 --mode restore-size`). Every top-level path in it, with
its size in that snapshot, and what this list does with it. A path that is not
in `include.txt` is dropped.

| Top-level path in `c3bca658` | Files | Size | Verdict | Reason |
| --- | --- | --- | --- | --- |
| `/home/nish/workspaces/agent-state` | 15,338 | 1,763.5 MiB | keep `backups` (1,362.5 MiB) and `_system` (3 files); drop the rest | `litellm.dump` and the rollback dumps are not rebuildable; the rest is per-run work dirs |
| `/home/nish/workspaces/products` | 19,139 | 535.0 MiB | drop | `git clone` from a remote |
| `/home/nish/workspaces/tooling` | 14,493 | 391.1 MiB | keep `nish-vault` (30.4 MiB); drop the rest | the vault is the durable memory; the rest is checkouts |
| `/home/nish/workspaces/fleet-knowledge-base` | 9,997 | 32.8 MiB | drop | `git clone` from a remote |
| `/home/nish/workspaces/{shared-workflows,agent-runner,node-repo-template}` | 246 | 0.2 MiB | drop | `git clone` from a remote |
| `/home/nish/workspaces/agent-memory` | 3 | ~0 | keep | one-fact-per-file agent memory |
| `/home/nish/.local` (`share` 532.7 MiB, `bin` 356.3 MiB, `lib` 23.2 MiB, `state` 9.9 MiB, `go-dl` 67.3 MiB) | 11,191 | 989.4 MiB | keep `share/fleet-grafana` (395.0 MiB, of which `grafana.db` is the part that matters), `share/drive` (52.3 MiB), `share/fleet-litellm-*`; drop the rest | `bin`, `lib`, `go-dl`, `state`, `share/gh`, `share/tirith` and friends are installed binaries and caches |
| `/home/nish/.claude` | 8,471 | 598.4 MiB | drop | session transcripts, plugins and skills; the vault is the memory |
| `/home/nish/.dotnet` | 4,756 | 582.6 MiB | drop | SDK, reinstalled |
| `/home/nish/.promptfoo` | 46 | 336.4 MiB | drop | eval results, reproducible from `share/drive` |
| `/home/nish/.hermes` | 2,938 | 239.5 MiB | keep (trimmed by `exclude.txt`) | `state.db`, `skills/`, `kanban.db`; `bin/`, `installs/` and logs are dropped |
| `/home/nish/.config` | 2,164 | 229.4 MiB | keep (trimmed by `exclude.txt`) | seat keys, gh, Cloudflare, rclone; `google-chrome-headless` (170.0 MiB) and `syncthing` (53.5 MiB) caches are dropped |
| `/home/nish/.nvm` | 3,195 | 211.9 MiB | drop | node versions, reinstalled |
| `/srv/aiostreams` | 24 | 184.1 MiB | keep | application data |
| `/usr/local` | 3 | 157.1 MiB | keep | hand-installed `gh` and `node` |
| `/home/nish/.cua` | 24 | 107.4 MiB | drop | host tool binaries |
| `/home/nish/.pi` | 2,305 | 69.7 MiB | keep `agent` (trimmed by `exclude.txt`) | local skills, prompts, extensions |
| `/home/nish/.codex` | 1,050 | 59.6 MiB | drop | session state and caches |
| `/home/nish/gopath`, `worktrees`, `.zcode`, `.cursor`, `.npm`, `.wix` | 10,157 | ~66 MiB | drop | module caches, checkouts, tool caches |
| `/home/nish/backups` | 13 | 6.6 MiB | drop | old dump, superseded by `agent-state/backups` |
| `/etc` | 1,408 | 4.0 MiB | keep (minus the secrets in `exclude.txt`) | system config |
| `/root` | 21 | ~0 | keep | root's keys and scripts |
| `/home/nish/.ssh`, `.gnupg`, `.git-credentials`, `.netrc` | 14 | ~0 | keep | credentials, not regenerable |
| `/home/nish/nish-vault` | 6 | ~0 | keep | agent drop inbox |
| `/home/nish` dotfiles and scratch (`.bashrc`, `.zshrc`, `.viminfo`, `dba-groups.html` 1.4 MiB, `Documents`, `Downloads`, `.claude.json*`, ...) | few | about 2 MiB | drop | part of the OS image or scratch |
| `/var/spool/cron` | 0 | 0 | keep | cron spool (empty `crontabs/` dir) |
| `/home/nish/.local/share/containers/storage/volumes` | 0 | 0 | keep | holds no files in `c3bca658`; the path stays on the list for the container data that lands there |

The live proof run on this list is in the PR comments, not here: a number in
this file goes stale at the next backup.

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
| `/home/nish/.local/state/fleet-ops/cloudflare-tokens` | 344 KiB | OpenTofu state for the per-repo Cloudflare tokens (`infra/cloudflare-tokens/`). The only record of the live tokens; without it the `gha-*` tokens are deleted by hand and minted again. |
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

## The size guard (hard stop)

`restic-r2-size-guard.service` runs the same backup as a **dry run**
(`restic backup --dry-run --json`, which uploads nothing) and `jq` reads its
summary. The unit fails with exit **78** when either limit is crossed:

| Limit | Default | Summary field |
| --- | --- | --- |
| New data this run | `SIZE_GUARD_MAX_BYTES=2147483648` (2 GiB) | `data_added` |
| Snapshot restored size | `SIZE_GUARD_MAX_RESTORED_BYTES=10737418240` (10 GiB) | `total_bytes_processed` |

- `restic-r2-backup.service.d/10-size-guard.conf` gives the backup unit
  a last `ExecStartPre=/usr/bin/systemctl start restic-r2-size-guard.service`
  (a oneshot start waits and returns the guard's exit status). A failed guard
  fails the backup unit **before** its `ExecStart`, so nothing over the limit
  is uploaded and the heartbeat ping is not sent. It runs after the pg_dump
  line, so the fresh dump is part of what is measured.
- `restic-r2-locked-copy.service.d/10-needs-backup.conf` gives the locked copy
  `Requires=restic-r2-backup.service`, so the copy into the `-locked` bucket is
  **skipped** when the backup fails. `Requires=` on a oneshot service *starts*
  it first, so the 06:15 locked copy also runs a guarded backup before it
  copies. That is the cost: the backup runs twice a day instead of once. It is
  paid on purpose, because a copy that follows a failed backup would push an
  unwanted snapshot into the locked bucket, which nothing can reclaim from. The
  backup unit takes the same `flock` the locked copy already takes, so the two
  cannot run concurrently; the second waits rather than duplicating work.
- The failed unit is the signal: `systemctl list-units --state=failed` shows
  `restic-r2-size-guard.service` and `restic-r2-backup.service`. Find out what
  grew (`journalctl -u restic-r2-size-guard`), fix the include or exclude list,
  then `systemctl reset-failed 'restic-r2-*'` and start the backup again. These
  are system units, so `systemctl --user list-units --state=failed` shows
  nothing even when both of them failed.
- The guard is a pre-flight because restic has no repository size limit and
  its `--json` status lines carry no `data_added`; only the final summary
  does. `data_added` from a dry run is dedup-aware: it counts only the blobs
  the repository does not have yet, so a run whose data is already in the
  bucket reports 0 and passes both limits.
- The guard is fail-closed. If the dry run itself fails, the guard unit stops
  before its `ExecStartPost`, no verdict is written and the unit fails, so the
  backup unit's `ExecStartPre` fails and nothing is uploaded. That is the safe
  direction: a snapshot that silently skipped a kept path is not a backup. A
  jailed worker cannot read `/root`, `/var/spool/cron` and about 37 root-only
  files under `/etc`, so its dry run fails even when the size is fine, which is
  why a local dry run adds those paths to an extra local exclude file instead
  of weakening the shipped list.
- The `ExecStart` override makes the backup unit read the tracked lists
  instead of the retired `/etc/restic/netcup-r2-excludes`. Change the paths in
  `include.txt`, not in the unit.

### Changing a limit, and switching the guard off

Never edit the `jq` line. Override the number with a drop-in:

```bash
systemctl edit restic-r2-size-guard.service
#   [Service]
#   Environment=SIZE_GUARD_MAX_BYTES=4294967296   # 4 GiB
#   Environment=SIZE_GUARD_MAX_RESTORED_BYTES=0   # 0 = this limit off
systemctl revert restic-r2-size-guard.service   # back to the shipped numbers
```

`0` switches **that limit** off and nothing else, so `SIZE_GUARD_MAX_BYTES=0`
runs the backup with no new-data limit while the 10 GiB restored-size limit
still applies. Both limits off at once means the guard always passes, which is
the same as not running it. A dropped `Environment=` line falls back to the
shipped value, so a wrong edit fails safe rather than open.

Switch it off for one run only when the growth is known and wanted (a first
backup of a new repository, or a deliberate one-off archive). Revert the
drop-in afterwards: a guard left off is how the next unexcluded cache grows the
snapshot again.

A first-ever backup trips the guard: an empty repository holds no blobs, so
`data_added` is the whole 3.8 GiB and that is over the 2 GiB limit. Run the
first backup of a new repository with a raised limit, or let the box's existing
repository carry the history, where `data_added` is only what changed since the
last snapshot. The local proof on the PR ran its first backup with the limit
raised to 4 GiB and every later run at the shipped 2 GiB.

The companion alarm is the Cloudflare R2 bucket-size alarm (#9355). The guard
is the cheap stop before the upload; the alarm catches a repository that grew
over many runs, each of them under the threshold.

## Not deployed from here

The restic units themselves are box-only, installed by root under
`/etc/systemd/system/restic-r2-*` and deliberately not tracked here: the
tracked copies had silently diverged from what runs on the box, and a
`fleet-host-config` run would then "fix" live behaviour. The unit files this
repo ships are additive, and each one keeps what the box-only units already do
and changes one thing:

- `restic-r2-backup.service.d/10-size-guard.conf` adds the guard
  `ExecStartPre` and makes the backup unit read the tracked lists instead of
  the retired exclude file. The box-only unit's pg_dump, unlock, flock,
  hardening and heartbeat stay.
- `restic-r2-size-guard.service` is the dry run and the two limits. It is
  started by the drop-in, never by a timer.
- `restic-r2-locked-copy.service.d/10-needs-backup.conf` makes the locked copy
  `Requires=` the backup unit. The box-only unit's own `After=` still sets the
  order.

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

All three are shipped by this PR under `rootfs/`, so the deploy replaces the
hand-installed copies with the tracked ones on the next
`fleet-host-config.service` run. Nothing needs to be added to
`/etc/fleet-ops/box-only`.

Until that run happens the daily drift check fails again on every merge. That
is the intended signal that a root-owned file changed by hand, and the merge
is what stops it: `fleet-host-config.service` runs on every push to `main`.
