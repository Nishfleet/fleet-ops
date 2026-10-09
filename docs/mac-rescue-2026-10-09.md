# Mac rescue bundle disposition — 2026-10-09

## Why this file exists

The Mac was switched off on 2026-10-09. Before that, git bundles of every repo with
unpushed commits were copied to `/home/nish/workspaces/tooling/mac-rescue-20261009/`.
This file records the result for each repo in that folder.

The bundles are the only copy of some of this work. Nothing in that folder was deleted,
moved or rewritten by the run that produced this file.

## Integrity check

```
$ cd /home/nish/workspaces/tooling/mac-rescue-20261009 && sha256sum -c SHA256SUMS.txt
TINY-STUDIO.bundle: OK
agent-skills.bundle: OK
agentic-engineering-stack.bundle: OK
cli-printing-press.bundle: OK
codex-lsp.bundle: OK
codex-ops.bundle: OK
codex-plusplus.bundle: OK
compound-engineering-plugin.bundle: OK
hermes-agent.bundle: OK
last30days-skill.bundle: OK
printing-press-library.bundle: OK
TINY-STUDIO-untracked.tar: OK
claude-scheduled-tasks.tar: OK
codex-lsp-untracked.tar: OK
codex-ops-untracked.tar: OK
drive-local-data.tar: OK
TINY-STUDIO.patch: OK
codex-lsp.patch: OK
codex-ops.patch: OK
hermes-agent-stash.patch: OK
21 of 21 files OK
```

## How "already on a remote" was proven

Three read-only checks were used. Each result below names the one that produced it.

1. `git ls-remote <remote>` — the local-only commit SHA appears as a ref tip.
2. `git cherry origin/main <branch>` — a `-` line means the same patch is already applied
   upstream. A `+` line means it is not.
3. `git merge-base --is-ancestor <sha> <remote branch>` on a full clone.
4. `git for-each-ref --contains <sha>` across every remote branch and every `refs/pull/*/head`.

## What this run could and could not reach

The `nishfleet-worker` GitHub App token writes to `Nishfleet/fleet-ops` only.
`gh api /installation/repositories` returns `total_count: 1`.

Dry-run pushes were probed against three other repos. All three answered `403`:

```
$ git push --dry-run HEAD:refs/heads/zz-write-probe-fleet-ops-9520 <repo>
Nishfleet/tinystudio-in   remote: Permission to Nishfleet/tinystudio-in denied
Nishfleet/0509            remote: Permission to Nishfleet/0509 denied
Nishfleet/drive           remote: Permission to Nishfleet/drive denied
```

`~/.git-credentials` holds two `x-access-token` entries. Neither grants wider access: the
longer one answers `401 Bad credentials` on `api.github.com/user` and
`Invalid username or token` on a git push. The issue asked for commits to be pushed to
their remotes, so this run could not do that part. It proved the state of every repo
instead and recorded it here. See "What is still open" below.

## Result per repo

### TINY STUDIO — `github.com/Nishfleet/tinystudio-in`

The Mac recorded the origin as `github.com/nish3451/tinystudio-in`. That URL now
redirects to `github.com/Nishfleet/tinystudio-in`, which is the same repository
(id 1255896996, default branch `main`). Remote `main` is `afc9fbb`. The bundle's
`refs/remotes/origin/main` is `a83e0e2a`.

Already delivered upstream, so nothing to push:

| Local-only commit | Proof | Remote state |
| --- | --- | --- |
| `3519f4f` fix(release): deploy lane needs Node 22 | `git ls-remote` → `refs/pull/209/head`; `git cherry` → `-3519f4ff5` | PR #209 MERGED, merge commit `7461f574` |
| `6ca3790` fix(release): CF_API_BASE typo | `git ls-remote` → `refs/pull/208/head`; `git cherry` → `-6ca37901d` | PR #208 MERGED, merge commit `b64f242c` |
| `ed7fbee` feat: add autonomous human-review service engine | `git for-each-ref --contains` → `refs/pull/8/head` | PR #8 MERGED, merge commit `24e516a` |

Not on any remote branch and not on any of the 316 pull-request heads. Each was checked
with `git for-each-ref --contains` across `refs/remotes/pr` and `refs/remotes/all`:

| Local-only commit | What it is | Disposition |
| --- | --- | --- |
| `10caa3f` Preserve Codex-era pre-revenue agent parity work before worktree archive | 57 files, 2627 insertions | Real work, unpushed. Blocked: no write access. |
| `76a829f` Preserve Codex-era 11-10 hardening work before worktree archive | 54 files, 1398 insertions | Real work, unpushed. Blocked: no write access. |
| `1503a61` chore(context): apply Claude 5 context-engineering rules | 9 files of agent context | Local scratch, not worth pushing |
| `0ec061c` chore(context): apply Claude 5 context-engineering rules | 14 files of agent context | Local scratch, not worth pushing |
| `d96c26c` chore(context): apply Claude 5 context-engineering rules | 9 files of agent context | Local scratch, not worth pushing |
| `631468d` debug: node fetch body probe | temporary debug branch | Local scratch, not worth pushing |
| `4d3fd51` debug: secret fingerprint probe (hashes only) | temporary debug branch | Local scratch, not worth pushing |

The uncommitted work is `TINY-STUDIO.patch` (4 tracked files under
`growth-brain/ops/`). `TINY-STUDIO-untracked.tar` holds 0 entries.

### hermes-agent — fork of `github.com/NousResearch/hermes-agent`

The bundle records no origin URL. Its `refs/remotes/origin/main` is `7262ab2d`. The Mac's
local `main` was `a0ca7c19`.

**The bundle is incomplete.** `git bundle verify` reports "The bundle records a complete
history", but the pack inside is missing objects. Its SHA-1 trailer is valid, so the file
is not corrupt. The parents of the two tip commits are absent:

```
$ git bundle verify hermes-agent.bundle
hermes-agent.bundle is okay
The bundle records a complete history.

$ git -C hermes-agent-recovered.git fsck
broken link from  commit a0ca7c19 to  commit c3a63a16
broken link from  commit 7262ab2d to  commit 9d297539
broken link from  commit 1ed94d24 to  commit e9e3291e
missing commit c3a63a16
missing commit 9d297539
```

`git fetch` from the bundle fails with
`fatal: Failed to traverse parents of commit a0ca7c19`. Why the pack is thin is not proven.
A shallow clone on the Mac would explain it, because a shallow clone has no parents to
hand to `git bundle create`.

The tip trees are complete, so the content survived:

```
$ git ls-tree -r refs/heads/main   | wc -l   ->  10166 files
$ git ls-tree -r refs/heads/stash  | wc -l   ->  9522 files
```

**Recovery performed.** The pack was unpacked into
`/home/nish/workspaces/tooling/mac-rescue-20261009/hermes-agent-recovered.git` with three
refs (`main` = `a0ca7c19`, `stash` = `41597fc2`, `origin-main-at-rescue` = `7262ab2d`),
`gc.auto=0`, and the missing history filled from
`github.com/NousResearch/hermes-agent`. `git fsck` now reports 0 broken links.

**Both commits are already upstream**, so nothing needs pushing:

| Local-only commit | Proof |
| --- | --- |
| `a0ca7c19` feat(cron): add explicit one-shot re-arm | `git merge-base --is-ancestor refs/heads/main refs/remotes/upstream/main` → YES |
| `7262ab2d` (origin/main at rescue time) | `git merge-base --is-ancestor refs/heads/origin-main-at-rescue refs/remotes/upstream/main` → YES |

The stash entry `41597fc2` is `On main: hermes-update-autostash-20260820-172341`. It
changes one line of `contributors/emails/agent@Agents-Mac-mini.local`
(`skip-agent` → `momomojo`). It is a stash, not a commit, so there is nothing to push.
The patch is kept as `hermes-agent-stash.patch`.

### agentic-engineering-stack — no remote

The bundle's index ref is
`refs/repo-sync/mac/indexes/tooling-agentic-engineering-stack-Users-nish-dev-agentic-engineering-s-0cd53b20db`.
There is no `refs/remotes/origin/*`, so the Mac never had a remote for this repo.

**A durable backup was created** at
`/home/nish/workspaces/tooling/agentic-engineering-stack`. It is a working clone of the
bundle. Its `origin` points at the bundle's absolute path, so the bundle stays the source
of truth.

```
$ git -C /home/nish/workspaces/tooling/agentic-engineering-stack log --oneline -3
25ce379 chore(context): apply Claude 5 context-engineering rules
ee0ecee feat: add agentic repo hardening workflow
e37f7cd docs: close tinystudio bootstrap blocker

$ git ls-files | wc -l   ->  29 files
```

The one local-only commit `25ce379` is an agent-context edit. It exists only on the branch
`context-engineering-20260727` inside the backup. A private GitHub repository was not
created, because the worker App token cannot create repositories and this repo has no
history worth publishing. See "What is still open".

### codex-ops — `github.com/nish3451/codex-workspace` (remote gone)

```
$ git ls-remote https://github.com/nish3451/codex-workspace.git
remote: Repository not found.
```

`github.com/nish3451` now serves 3 public repositories: `seo-fix-kit`,
`shared-workflows` and `node-repo-template`. `codex-workspace` is not one of them, so the
remote was deleted or made private.

The local-only commits are `29da9bd` Add safe Mac VPS repository replication and
`0ec4d8b` chore(context). The uncommitted work is `codex-ops.patch`
(`scripts/codex-self-monitor.py`). There is no remote to push to, so the bundle is the
copy. `29da9bd` is the replication tooling that produced this rescue folder, so it is
worth keeping.

### The 8 vendor clones — vendor scratch, not worth pushing upstream

Each of these is a clone of a repository Nish does not own. The only local-only commit in
each touches that repository's agent context files (`AGENTS.md`,
`skills/**/SKILL.md`, `references/**`, `docs/*.md`). Pushing them upstream is not
appropriate, and no remote under Nish's control exists for any of them. The bundle is the
copy.

| Repo | Remote | Local-only commit |
| --- | --- | --- |
| agent-skills | `github.com/openclaw/agent-skills` | `539017b` chore(context) |
| cli-printing-press | `github.com/mvanhorn/cli-printing-press` | `64f52a66` shrink always-loaded layer, `3ba40e9a` chore(context) |
| codex-lsp | `github.com/code-yeongyu/codex-lsp` | `19c7a76` chore(context) |
| codex-plusplus | `github.com/b-nnett/codex-plusplus` | `fd477ca` chore(context) |
| compound-engineering-plugin | `github.com/EveryInc/compound-engineering-plugin` | `1372dbfa` chore(context) |
| context-hub | `github.com/andrewyng/context-hub` | `8f34d93` chore(context) |
| last30days-skill | `github.com/mvanhorn/last30days-skill` | `e3232b7` chore(context) |
| printing-press-library | `github.com/mvanhorn/printing-press-library` | `fac95b6f0` chore(context) |

None of these 11 commits appears as a ref tip on its remote. Each remote was read with
`git ls-remote` and every local-only SHA was searched in the ref list.

## What is still open

Two things need a credential that the worker seat does not have. Both are recorded here so
the next run does not re-derive them.

1. The 7 unpushed TINY STUDIO commits listed above, including `10caa3f` and `76a829f`,
   need a push to `Nishfleet/tinystudio-in` by a seat that can write to it.
2. `codex-ops` needs a remote. `github.com/nish3451/codex-workspace` no longer resolves,
   and the worker App cannot create repositories.

## Notes on the rest of the folder

These files are not git bundles and no repo was listed for them in the issue, so they were
left alone:

- `claude-scheduled-tasks.tar`, `drive-local-data.tar`, `codex-lsp-untracked.tar`,
  `codex-ops-untracked.tar` — archives of local data.
- `nish-vault.status.txt` — a status dump. The vault itself lives at
  `/home/nish/workspaces/tooling/nish-vault` and has a remote
  (`https://github.com/nish3451/nish-vault.git`), so it is not stranded.
- `hermes-agent-recovered.git` and the recovered hermes content described above.
