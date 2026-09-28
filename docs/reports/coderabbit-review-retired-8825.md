# coderabbit-review skill retired (fleet-ops#8825)

`~/.pi/agent/skills/coderabbit-review` (also reachable as
`~/.agents/skills/coderabbit-review` — `~/.agents/skills` is a symlink to
`~/.pi/agent/skills`) was a local pre-commit review gate wrapping `crgate`,
itself a wrapper over the `coderabbit` CLI. The standing rule
(`~/.claude/CLAUDE.md:39`, "Repos (every repo, now and future)") is that
reviews and gates are GitHub built-ins — rulesets, merge queue, secret
scanning, CodeQL, installed review apps — with no local review wrappers. It
does not appear in this repo's `AGENTS.md`; the vault keeps the class at
`_system/shared-memory/retired-mechanisms.md:23` (the 2026-09-28 autoreview
row, the pre-existing twin of the row this change adds at line 24) and
`_system/agent-memory/execution-is-the-review.md:37`. Neither the `coderabbit`
nor the `crgate` binary exists on this host, so the skill pointed at a CLI
that cannot run. Retired 2026-09-28.

## Sweep — no unit, timer, crontab entry, PATH binary or symlink invoked it

This is a targeted sweep for the four invoker classes, not an exhaustive grep
of the host. Its scope is `~/.config/systemd/user`, crontab, `~/.local/bin`,
and symlinks under `~/.pi/agent`/`~/.claude`/`~/.cursor` — the places from
which a command could actually be launched. It is not a claim that the string
`coderabbit` appears nowhere: it appears in 2,043 files under `~/workspaces`,
`~/.config/systemd/user`, `~/.hermes`, `~/.pi/agent`, `~/.claude`, `~/.cursor`
and `~/.local/bin` (`rg -il --hidden --no-ignore`, `.git` and `node_modules`
filtered), and those hits are classified at the end of this section.

```
$ command -v coderabbit; command -v cr; command -v crgate
(exit 1 each — absent from PATH)

$ ls ~/.local/bin | grep -i 'coderabbit\|crgate'
(no hits)

$ XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files | grep -i 'coderabbit\|crgate'
(no hits)

$ crontab -l | grep -i 'coderabbit\|crgate'
(no hits)

$ find ~/.pi/agent ~/.claude ~/.cursor ~/.config/systemd/user -lname '*coderabbit*' -o -lname '*crgate*' | head
(no hits)
```

A keyword sweep over the agent roots, to catch a config that names the gate
without a unit or symlink:

```
$ rg -il 'coderabbit|crgate' ~/.config/systemd/user/ ~/.hermes/ ~/.pi/agent/ | grep -v '^/home/nish/.pi/agent/sessions/'
/home/nish/.hermes/state-snapshots/*/cron/jobs.json   — Aug-20 snapshot data
/home/nish/.hermes/logs/errors.log, ~/.hermes/sessions/*.json, ~/.hermes/cache/**  — logs/dumps
/home/nish/.pi/agent/AGENTS.md.folded-20260919      — folded backup of the old AGENTS.md,
                                     one line listing it among review gates
/home/nish/.hermes/hermes-agent/tests/*.py          — CodeRabbit GitHub-app docstrings
site-packages fastapi METADATA             — sponsor-badge URL
```

Live configuration that names the gate, and what happened to each:

- `~/.claude/projects/-home-nish-workspaces-products-0509/memory/four-pass-review-stack.md`
  — a live per-project memory whose body told 0509 sessions to run `crgate`
  pre-commit from `~/.local/bin`. Rewritten 2026-09-28: the file now opens with
  the live loop (run it, fix it, run it again, diff-scoped semgrep + repo
  tests, then the PR; gates are GitHub built-ins), the retired description is
  kept below a "history only, nothing in it is a live instruction" rule, and
  the frontmatter `description` no longer advertises the stack. The 0509
  memory index `MEMORY.md:33`, which advertised the stack in one line, now
  marks it RETIRED. Both are out-of-repo host edits, part of confirming that
  nothing live still instructs the gate. The vault has said this since
  2026-09-19 (`_system/agent-memory/execution-is-the-review.md:37`) and
  `_system/agent-memory/no-glue.md:14` lists `crgate` and `bugbot-gate` under
  "Never recreate"; the host copies had missed both.
- `Nishfleet/inish-site` and `Nishfleet/aiconverter-app` `.coderabbit.yaml`
  (blob `88c65c62`, on both `origin/main`) and `Nishfleet/siterep-public`
  `.github/workflows/review-gate.yml:144` on `origin/main` — three product
  repos still tell a session that `crgate`/`sgscan` run locally. Out of this
  issue's scope, which names one skills dir, and filed as **#8838**. Untouched
  here.
- `config/rule-enforcement.json:548` `led-coderabbit` in `inish-site`,
  `aiconverter-app` and `siterep-public` — records `"mechanism": "none —
  waiting on a Nish-reserved auth action"`, status "fleet is ordered to run
  without the local gate until then". That status is already true; the
  remaining decision is Nish's re-auth, which stays open and untouched. Part
  of #8838.
- `~/workspaces/tooling/nish-vault/_system/shared-memory/skills-library/review-adjudication/SKILL.md:12`
  — house skill giving "CodeRabbit locally AND Greptile on the PR" as an
  example of two engines agreeing; names no command, and the example still
  holds for the installed GitHub app.
- `~/.claude/CLAUDE.md.bak-fold-20260919:116` — pre-2026-09-19 backup; the
  only hit is the "never relay a finding" list naming CodeRabbit among
  reviewers whose findings land in the agent's queue. No rule to correct: the
  live `~/.claude/CLAUDE.md:39` already forbids local review wrappers.
- `.lane/pr-body-5782.md` (this repo, tracked) — merged-PR body record
  mentioning `crgate`; kept as history, invokes nothing. The same tracked file
  appears in the other 11 fleet-ops worktrees on this host (`fable-8653`,
  `fable-fo-rebase`, `fable-restore-proof-stock`, `fix-lane-wall-filter`,
  `fleet-ops-agent-yml-main-ref`, `fleet-ops-grade-bar-only`,
  `fleet-ops-issue-8677`, `fo-closes-own`, `fo-devin-lane`,
  `fo-ram-limits-0925`, `issue-fleet-ops-8826`); all share md5 `8805db23` — the
  same merged-PR snapshot — and none is an invoker.
- `~/workspaces/fleet-knowledge-base/01-inbox/.queue/burndown.jsonl:4729,6898`
  — the kb-burndown append log (last written 2026-08-23), whose two hits are
  `source` paths of August vault notes about the old `crgate` quota guard and a
  CodeRabbit remediation product contract; data records, not configuration.
- The rest of the 2,043 keyword hits: agent transcripts and session dumps under
  `~/.pi/agent/sessions/`, `~/.claude/projects/`, `~/.cursor/projects/`,
  `~/.hermes/{logs,sessions,cache}/`; vendored third-party code
  (`site-packages` metadata, `hermes-agent` test docstrings); and vault or
  `fleet-knowledge-base` prose from August. History, logs and vendored code —
  none of them a launch path.
## Deletion + acceptance proof

Pre-delete state (the file is gone now; this is the record):

```
$ ls -la ~/.pi/agent/skills/coderabbit-review/
total 28
drwxr-xr-x   2 nish nish  4096 Sep 28 15:31 .
drwxr-xr-x 116 nish nish 20480 Sep 28 15:31 ..
-rw-r--r--   1 nish nish  3415 Sep 28 15:31 SKILL.md    (the only file)
```

The deleted `SKILL.md`'s frontmatter, recorded before the delete (the
`description` is elided here with `...`; the full text is not recoverable from
the host after the delete, and the provenance survives in the vault row):

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
(exit 2 — `~/.agents/skills` is a symlink to `~/.pi/agent/skills`)
```

One line added to
`/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/retired-mechanisms.md`
line 24 (the real vault; `~/nish-vault` is a stub without `_system/`), beside
the 2026-09-28 autoreview row at line 23. If CodeRabbit is wanted again it
runs as the installed GitHub review app, not a local CLI wrapper.

The deliverable is a host-directory deletion plus a vault row, not repo
behaviour, so there is no test to add; the acceptance proof is the `ls` exit 2
above and the vault row. The repo diff is this report only.

encoded: structure - the gate could not run (no CLI on the host) and violated the no-local-review-wrappers rule, so deleting the dir is the fix and no file remains to hold the mistake. This is the second same-day local-review-wrapper retirement (autoreview above it in the ledger), but the rule that catches the class already lives at `~/.claude/CLAUDE.md:39` and the vault `_system/agent-memory/no-glue.md:14` "Never recreate" list already names `crgate`; adding a skill-dir scan organ would be new glue, so there is no lower rung to move to.
