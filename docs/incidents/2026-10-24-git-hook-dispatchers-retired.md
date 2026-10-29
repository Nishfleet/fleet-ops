# Git hook dispatchers retired from the product and tool checkouts

**Date:** 2026-10-24
**Issue:** fleet-ops#10141

## What they were

The 2026-10-23 glue audit (fleet-ops#10125) found three Git hook dispatchers
copied into the local `.git/hooks` directory of seven product and tool
checkouts: `pre-commit`, `pre-push` and `post-commit`. They were untracked
local Git metadata, not part of any repo, and the same three files (the same
checksum in every checkout) were in all seven.

Each dispatcher resolved its own checkout's Git directory, and then did
nothing here: it dispatched only under two old macOS checkout roots, and on
any other machine it exited 0 without running a script. The scripts it named
live in a macOS-only project folder that this host never had, so on this box
all three hooks were inert no-ops. No checkout sets `core.hooksPath`, so
Git found them in `.git/hooks` and ran them on every commit and push.

## What they did

| Hook | Dispatched to | Effect on this host |
|---|---|---|
| `pre-commit` | a macOS-only commit-safety script | none, exited 0 |
| `pre-push` | a macOS-only push-safety script | none, exited 0 |
| `post-commit` | a macOS-only auto-push script | none, exited 0 |

A hook that cannot run is deleted, not rewritten. If a hook is wanted later,
it is written where its script lives.

## What was removed

The three dispatchers, 21 files in all, were deleted from the `.git/hooks`
directory of each of the seven checkouts, relative to the workspace root:

- `products/aiconverter-app`
- `products/inish-site`
- `products/proof-seo`
- `products/SeniorAgentSafetyLoop`
- `tooling/agent-skills`
- `tooling/compound-engineering-plugin`
- `tooling/last30days-skill`

No tracked file was edited, and no other hook in those directories was
touched. The linked worktrees of those repositories resolve the same (now
empty) hook directory, so they run no dispatcher either.

## Proof

Before the delete, in every one of the seven checkouts, `git hook run
pre-commit`, `git hook run pre-push` and `git hook run post-commit` each
returned 0 with the dispatcher present.

After the delete, all three hooks are absent from all seven checkouts and
each `git hook run` now fails with the missing-hook error:

```
$ cd <checkout> && git hook run pre-commit
error: cannot find a hook named pre-commit
$ echo $?
1
```

The same holds for `pre-push` and `post-commit`, so none of the three can
run. Global and system `core.hooksPath` are unset, so no other hook path
takes over.

## Retired

The three dispatchers are retired from all seven checkouts. Do not restore
them. A commit or push check that is wanted again is written as a repo
feature where its script lives, not as a copied dispatcher in a local
`.git/hooks` directory.
