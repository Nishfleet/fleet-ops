# coderabbit-review skill retired (fleet-ops#8825)

`~/.pi/agent/skills/coderabbit-review` (also reachable as `~/.agents/skills/coderabbit-review` — `~/.agents/skills` is a symlink to `~/.pi/agent/skills`) was a local pre-commit review gate wrapping `crgate`, itself a wrapper over the `coderabbit` CLI. The standing rule (`~/.claude/CLAUDE.md:39`, "Repos (every repo, now and future)") is that reviews and gates are GitHub built-ins — rulesets, merge queue, secret scanning, CodeQL, installed review apps — with no local review wrappers. It does not appear in this repo's `AGENTS.md`; the vault states the same class twice, at `_system/shared-memory/retired-mechanisms.md:23-24` and `_system/agent-memory/execution-is-the-review.md:37`. Neither binary exists on this host, so the skill pointed at a CLI that cannot run. Retired 2026-09-28.

## Sweep — nothing live invoked it

Roots searched: `~/workspaces`, `~/.config/systemd/user`, `~/.hermes`, `~/.pi/agent`, `~/.claude`, `~/.cursor`, `~/.local/bin`, systemd unit files, crontab. Plain `rg` skips hidden dirs; `--hidden --no-ignore` was run on the fleet-ops clone to catch `.lane/`.

```
$ command -v coderabbit cr crgate
(exit 1 for each — absent from PATH and ~/.local/bin)

$ rg --hidden --no-ignore -il 'coderabbit|crgate' .        # issue clone
./.lane/pr-body-5782.md     (tracked PR-body snapshot landed by #6152; a
                             historical record of a merged PR, not an invoker)
./docs/reports/coderabbit-review-retired-8825.md   (this file)

$ rg -il 'coderabbit|crgate' ~/.config/systemd/user/ ~/.hermes/ ~/.pi/agent/ | grep -v 'skills/coderabbit-review'
~/.hermes/state-snapshots/*/cron/jobs.json   — Aug-20 snapshot data
~/.hermes/logs/errors.log, ~/.hermes/sessions/*.json, ~/.hermes/cache/**  — logs/dumps
~/.pi/agent/sessions/*.jsonl               — agent transcripts
~/.pi/agent/AGENTS.md.folded-20260919      — folded backup of the old AGENTS.md,
                                     one line listing it among review gates
~/.hermes/hermes-agent/tests/*.py          — CodeRabbit GitHub-app docstrings
site-packages fastapi METADATA             — sponsor-badge URL

$ XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files | grep -i coderabbit
(no hits)   $ crontab -l | grep -i coderabbit   (no hits)
```

References, not invokers — every live file the sweeps found, classified:

- `.lane/pr-body-5782.md` (this repo, tracked) — merged-PR body record mentioning `crgate`; kept as history, invokes nothing. The same tracked file also appears as a copy in five other fleet-ops worktrees (`fable-fo-rebase`, `fable-restore-proof-stock`, `fable-8653`, `fo-devin-lane`, `fo-ram-limits-0925`); all are the same merged-PR snapshot, none is an invoker.
- `~/workspaces/fleet-knowledge-base/01-inbox/.queue/burndown.jsonl:4729,6898` — the kb-burndown append log (last written 2026-08-23), whose two hits are `source` paths of August vault notes about the old `crgate` quota guard and a CodeRabbit remediation product contract; data records of past work, not configuration.
- `~/.claude/projects/-home-nish-workspaces-products-0509/memory/four-pass-review-stack.md` — a **live per-project memory** instructing 0509 sessions to run `crgate` pre-commit from `~/.local/bin`. Corrected in place 2026-09-28 with a dated line matching the vault's own 2026-09-19 correction (`execution-is-the-review.md:37`), which this copy had missed. The other two entries in that stack (`sgscan`, `bugbot-gate`) are also on the vault `_system/agent-memory/no-glue.md:14` "Never recreate" list, so the correction marks the whole stack dead.
- `~/workspaces/tooling/nish-vault/_system/shared-memory/skills-library/review-adjudication/SKILL.md:12` — house skill giving "CodeRabbit locally AND Greptile on the PR" as an example of two engines agreeing; names no command.
- `~/.claude/CLAUDE.md.bak-fold-20260919:116` — pre-2026-09-19 backup; the only hit is the "never relay a finding" list naming CodeRabbit among reviewers whose findings land in the agent's queue. No rule to correct: the live `~/.claude/CLAUDE.md:39` already forbids local review wrappers.
- `aiconverter-app/config/rule-enforcement.json:548` `led-coderabbit` — records `"mechanism": "none — waiting on a Nish-reserved auth action"`, status "fleet is ordered to run without the local gate until then". Read in another agent's live worktree, `~/workspaces/agent-worktrees/issue-aiconverter-app-8820/`; not edited, and that worktree is a local clone of the `Nishfleet/aiconverter-app` repo, so its `origin/main` is the other place the line could need editing. That auth item stays open and untouched; this retirement removes the dead local gate, it does not resolve whether Nish re-auths CodeRabbit.
- Session transcripts/logs under `~/.pi/agent/sessions/`, `~/.claude/`, `~/.cursor/`, `~/.hermes/`, vault `decisions-ledger.md`/`standing-rules-archive.md`/shadow-promotion drafts, `fleet-knowledge-base/90-sources/records/` seeds, `last30days-research/` notes — history and notes, not configuration.

## Deletion + acceptance proof

Pre-delete state (the file is gone now; this is the record):

```
$ ls -la ~/.pi/agent/skills/coderabbit-review/
total 28
drwxr-xr-x   2 nish nish  4096 Sep 28 15:31 .
drwxr-xr-x 116 nish nish 20480 Sep 28 15:31 ..
-rw-r--r--   1 nish nish  3415 Sep 28 15:31 SKILL.md    (the only file)
```

The deleted SKILL.md's frontmatter, verbatim:

```
name: coderabbit-review
description: "Local pre-commit/pre-push code review using the CodeRabbit CLI. ... This is the LOCAL gate only — it does not replace ce-code-review or the /code-review plugin."
metadata:
  version: "0.1.1-nish"
  upstream: "coderabbitai/skills v1.1.1 (skills/code-review), adapted for CLI 0.7.x"
```

```
$ rm -rf ~/.pi/agent/skills/coderabbit-review

$ ls ~/.pi/agent/skills/coderabbit-review
ls: cannot access '/home/nish/.pi/agent/skills/coderabbit-review': No such file or directory
(exit 2 — the issue's proof line)

$ ls ~/.agents/skills/coderabbit-review
ls: cannot access '/home/nish/.agents/skills/coderabbit-review': No such file or directory
```

Reinstall path if ever wanted: `npx skills add` from upstream `coderabbitai/skills`. One line added to `/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/retired-mechanisms.md` (the real vault; `~/nish-vault` is a stub without `_system/`) beside the 2026-09-28 autoreview entry. If CodeRabbit is wanted again it runs as the installed GitHub review app, not a local CLI wrapper.

encoded: structure - the gate could not run (no CLI on the host) and violated the no-local-review-wrappers rule, so deleting the dir is the fix and no file remains to hold the mistake. This is the second same-day local-review-wrapper retirement (autoreview above it in the ledger), but the rule that catches the class already lives at `~/.claude/CLAUDE.md:39` and the vault `_system/agent-memory/no-glue.md:14` "Never recreate" list already names `crgate`; adding a skill-dir scan organ would be new glue, so there is no lower rung to move to.
