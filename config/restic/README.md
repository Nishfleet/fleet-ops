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
| `~/workspaces/products` | 19,139 | 535.0 MiB | keep, minus dependency trees and build outputs (2026-10-15) | not all of it is on a remote: uncommitted edits, local-only branches and repos with no remote |
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
| `~/workspaces/agent-state/backups` | 1.4 GiB, about 0.3 GiB kept | the LiteLLM `pg_dump` (`litellm.dump`, custom format) the unit takes before every run, which is the LiteLLM database backup, plus rollback snapshots. `docs/RUNBOOK.md` relies on it being in the restic path. `exclude.txt` drops the 1.2 GiB stale Postgres datadir copy, the `skills-prune-*.tgz` rollback tarballs and the one-off `litellm-<label>.dump` pre-migration copies (six, about 140 MiB each, 22-23 Oct 2026, fleet-ops#10240); `litellm.dump` stays. |
| `/home/nish/.hermes` | 5.1 GiB, ~100 MiB kept | hermes facts: `state.db` and its WAL, `state-snapshots/`, `skills/`, `kanban.db`, `shared-state.db`, `backups/`. `exclude.txt` drops the agent checkout, the tool trees, caches, installs and logs. |
| `/home/nish/.pi/agent` | 1.4 GiB, ~100 MiB kept | locally maintained skills, prompts, agents and extensions. `sessions/` and `npm/` are dropped. |
| `/home/nish/.local/share/fleet-litellm-redis` | 8 KiB | Redis data for the same service. |
| `/home/nish/.local/share/fleet-grafana` | 486 MiB, 4.5 MiB kept | `grafana.db`: users, annotations, dashboard state, unified-search. `plugins/` is reinstalled from the catalog. |
| `/home/nish/.local/share/drive` | 53 MiB | labelled eval train and held-out cases. A different model family wrote them; re-running the harness is not the same data. |
| `/home/nish/.local/state/fleet-ops/cloudflare-tokens` | 344 KiB | OpenTofu state for the per-repo Cloudflare tokens (`infra/cloudflare-tokens/`). The only record of the live tokens; without it the `gha-*` tokens are deleted by hand and minted again. |
| `/home/nish/.local/share/containers/storage/volumes` | 3.3 GiB on disk, 83 MiB kept | podman container volumes. `exclude.txt` drops the orphaned pre-migration LiteLLM Postgres volume (3.2 GiB, last written 13:20 on 23 Oct 2026; no container mounts it and the nightly `pg_dump` is that database's backup, so it is superseded) and the litellm pycache volume (bytecode the proxy writes again). The orphaned volume was nearly all of the 3.6 GB of new data that tripped the size guard on 24 and 25 Oct (fleet-ops#10258). |
| `~/workspaces/products` | 74 MiB source + `.git` | product working trees. Uncommitted edits, unpushed branches and repos with no remote yet exist only here; `exclude.txt` drops `node_modules`, `dist`, `build` and other rebuildable outputs at the top of each repo (about 1.3 GiB). Local `.env` files are kept too: the snapshot is encrypted and already holds `~/.config`, and a key that exists only on the box is exactly what a restore would otherwise lose. Local database files, dumps, data exports, archives and `.bak` copies (`.sqlite`, `.db`, `.sql`, `.csv`, `.ndjson`, `.gz`, `.tgz`, `.xz`, `.bz2`, `.zst`, `.zip`, `.7z`, `.tar`, `.bak`, `.old`, `.orig`, `.backup`) are dropped, because the locked copy could never forget a customer's rows; committed ones are still in git. |
| `/etc` | 10 MiB | units, ssh, polkit, sysctl, cron, rclone and prometheus config. |
| `/root` | ~4 KiB | root's scripts and keys. |
| `/srv/aiostreams` | 153 MiB | application data. |
| `/usr/local` | 158 MiB | hand-installed `gh` and `node`, which no package owns. |
| `/var/spool/cron` | 8 KiB | cron jobs (the only cron spool on Ubuntu). |

Sum of the kept set: about 3.9 GiB before compression on 2026-10-07, about 1.5 GiB once the raw LiteLLM datadir (2.1 GiB), the stale copies and the Hermes rollback trees left on 2026-10-21, which restic reports as
the snapshot's restore size (see `Verification` on the PR). That is inside the
7 GiB target the issue sets and far inside the 10 GiB hard stop.

On 24 and 25 Oct the size guard tripped both nightly runs: the dry run counted
3.6 GB of new data against the 1 GiB limit, nearly all of it the orphaned
pre-migration Postgres volume dropped above. Measured on 2026-10-25 with that
exclusion: the guard's dry run reports 430 MB of new data and a 1.7 GiB restore
size, and the run's snapshot (`c2f3fab3`) processed 22,104 files / 1.687 GiB.

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
| `~/workspaces` and `~/workspaces/tooling` (except the vault, agent-memory, the two agent-state dirs and `products/` above) | 35 GiB + 463 MiB | code and work dirs. `agent-worktrees/`, `_archive-bundles/` and every `wt-*`/`fleet-ops-*` checkout are `git clone` from a remote; except `nish-vault` (above) they are rebuildable. `agent-state/tools`, `retired-checkouts*`, `branch-prune`, `glue-sweep`, `alert-repair` and the other per-run work dirs are regenerated by the next run. |
| `/home/nish/.local/share/agent-runner`, `devin`, `actions-runner`, `fleet-ci-runner` | 48 + 5.7 + 4.4 + 3.9 GiB | runner work dirs and their caches. The issue names these as the main cause of the growth. |
| `/home/nish/.local/share/{git,gh,uv,semgrep-venv,go,gotool,go-toolchain,opencode,cursor-agent,blender-4.2.1,tirith,last30days,fleet-ops-rule-gap,drive-issue-582}` | ~3.5 GiB | versioned binaries, installed plugins and tool caches. |
| `/home/nish/.ollama` | 4.2 GiB | model weights, re-downloaded from their source. |
| `/home/nish/go`, `gopath`, `go-mod-cache`, `go-workspace`, `gopath-go`, `go1.24.0.linux-amd64.tar.gz` | ~3.5 GiB | toolchains and module caches, reinstalled by `go build`. |
| `/home/nish/.cache`, `.npm`, `.cargo/registry`, `__pycache__`, `/var/tmp`, `/tmp` | ~16 GiB | caches. |
| `~/.claude`, `.codex`, `.cursor`, `.juicefs`, `.bun`, `.nvm`, `.cua`, `.dotnet`, `.zcode`, `.devin-server`, `.wrangler`, `.promptfoo` | ~7.5 GiB | session transcripts and logs (the vault is the memory), installed binaries and tool caches. `.promptfoo/promptfoo.db` is eval *results*, reproducible from the drive cases above. |
| `/home/nish/tool`, `.wix`, `Documents`, `backups`, `Downloads`, `Desktop`, `Music`, `Videos`, `Pictures`, `scratch` | ~360 MiB | personal scratch and retired files, not fleet state. The 6.7 MiB in `~/backups` is an old dump superseded by `agent-state/backups`. |
| dotfiles at the top of `/home/nish` (`.bashrc`, `.viminfo`, `.zcompdump`, `.Xauthority`, …) | < 1 MiB | part of the OS image, not of the fleet state. |
| `~/.local/share/fleet-litellm-postgres` | 2.1 GiB, about 700 MiB of churn a day | the raw datadir of the running LiteLLM Postgres. A file copy of a live Postgres is not crash-consistent, so it is not a backup, and its churn grew the repository by about 0.7 GB for every day a snapshot was kept. The `pg_dump` in `agent-state/backups` is the backup: restored from snapshot `66052ca5` and again from the newest kept snapshot after the first prune, and listed with `pg_restore --list` (146 tables) on 2026-10-21. The box-only backup unit writes `pg_dump -Fc` to a `.new` file and moves it over `litellm.dump` only after pg_dump exited 0, and neither of those two `ExecStartPre=` lines has a `-` prefix, so a failed dump fails the unit before restic runs and never replaces the previous dump with a partial one. |
| the orphaned pre-migration LiteLLM Postgres podman volume (`df817408…`) | 3.2 GiB | the old cluster the 23 Oct 2026 migration left behind. No container mounts it; the live cluster's data dir is deliberately not backed up raw (row above), so this volume's state is superseded by the kept pre-migration dumps and the nightly `pg_dump`. Excluded on 2026-10-25 after it tripped the size guard on two consecutive nights (fleet-ops#10258); the files stay on disk. |
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
   # ansible renders the lists as templates; do the same for the dry run.
   for f in include exclude; do
     sed "s|{{ nish_home }}|$HOME|g" config/restic/$f.txt > /tmp/restic-$f.txt
   done
   restic backup --dry-run --json \
     --files-from=/tmp/restic-include.txt \
     --exclude-file=/tmp/restic-exclude.txt \
     --exclude-caches | jq '{data_added, total_bytes_processed, total_files_processed}'
   ```

   Read `total_bytes_processed` as the size of everything, `data_added` as the
   size that would be new. If the path brings caches with it, add patterns to
   `exclude.txt`.
3. Commit and push. The next `fleet-host-config` run puts the file on the box.

## Units

The play installs these from `rootfs/etc/systemd/system/` (restic docs:
"Backing up", "Removing backup snapshots", "Checking integrity", "Restoring
from backup"):

- `restic-r2-backup.service` and `.timer`, nightly: `pg_dump` of LiteLLM,
  `restic backup`, `restic forget --prune`, heartbeat ping, then
  `OnSuccess=restic-r2-locked-copy.service`.
- `restic-r2-locked-copy.service`: `rclone copy` into the object-locked bucket,
  `rclone check`, then reclaim of objects past the lock. No timer: only a good
  backup starts it.
- `restic-r2-verify.service` and `.timer`, weekly:
  `restic check --read-data-subset=5%`.
- `restic-r2-restore-drill.service` and `.timer`, monthly:
  `restic restore latest --verify` into a tmpfs, `pg_restore --list` of the
  LiteLLM dump (fails on zero `TABLE DATA` entries), heartbeat ping.

Every restic and rclone job takes one `flock`, and waits up to 15 minutes.
A failed unit is reported by the `SystemUnitFailed` alert.

## Retention

```
restic forget --group-by host,tags --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
```

Without `--group-by host,tags` restic groups snapshots by host *and path set*,
and the policy is applied inside each group. Every change to `include.txt`
starts a new group that the policy never ages out. The forget line has no `-`
prefix: a failed prune fails the backup, so no heartbeat is sent and the locked
copy does not start.

The locked bucket is a copy, not a second repository: `restic-r2-locked-copy`
runs `rclone copy` and then `rclone sync --min-age 31d`, so only the last 31
days of removed history stay recoverable. Never run `restic forget` or
`restic prune` against the locked bucket, and use `--no-lock` for any read
there: a lock object cannot be deleted for 30 days.

## Box-only files

These hold credentials and stay hand-installed:

- `/etc/restic/netcup-r2.env` — the restic repository and its keys
  (deliberately excluded from the backup, see above)
- `/etc/tiny-studio/heartbeats.env` — `HC_BACKUP_URL`, `HC_LOCKED_COPY_URL`
- `/home/nish/.config/fleet-ops/keystone-hc.env` — `HC_URL_RESTORE`, pinged by
  the drill
- `/etc/rclone/tiny-studio-r2.conf` — the `live:` and `locked:` remotes

If `/etc/restic/netcup-r2.env` goes missing the units do not run at all
(`ConditionPathExists`): no credentials, no backup, no silent empty snapshot.
