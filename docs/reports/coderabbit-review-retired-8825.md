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

This is a targeted sweep for the five invoker classes the issue asks about, not
an exhaustive grep of the host. Its scope is `~/.config/systemd/user`, crontab,
`~/.local/bin`, and symlinks under `~/.pi/agent`/`~/.claude`/`~/.cursor` — the
places from which a command could actually be launched. It is not a claim that
the string `coderabbit` appears nowhere: a keyword sweep over `~/workspaces`,
`~/.config/systemd/user`, `~/.hermes`, `~/.pi/agent`, `~/.claude`, `~/.cursor`
and `~/.local/bin`
(`rg -il --hidden --no-ignore … | grep -v '/.git/' | wc -l`) returns just
over two thousand files, and those hits are classified at the end of this
section. The count drifts as agent sessions append, which is why it is carried
as a magnitude and not a figure.

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

(That block is annotated — `(no hits)` and `(exit 1 each)` are the reader's
notes on empty output; the command lines are exact.)

Keyword sweep over the agent roots, to catch a config that names the gate
without a unit or symlink:

```
$ rg -il 'coderabbit|crgate' ~/.config/systemd/user/ ~/.hermes/ ~/.pi/agent/ | grep -v '^/home/nish/.pi/agent/sessions/'
/home/nish/.hermes/cache/scratch/merged12h.out
/home/nish/.hermes/cache/web/github.com-7e18454411.md
/home/nish/.hermes/cache/uv/archive-v0/TCV7BDWwmR7kh0HX/fastapi-0.133.1.dist-info/METADATA
/home/nish/.hermes/hermes-agent/tests/agent/test_bot_profile_prompt_isolation.py
/home/nish/.hermes/hermes-agent/tests/gateway/test_resume_command.py
/home/nish/.hermes/installs/e8462ad3c57e40e8/environments/8122eea1978b4e33bb7e51d74618b175/venv/lib/python3.14/site-packages/fastapi-0.133.1.dist-info/METADATA
/home/nish/.hermes/logs/errors.log
/home/nish/.hermes/sessions/request_dump_20260908_002705_2eb4953a_20260908_002716_866745.json
/home/nish/.hermes/state-snapshots/20260820-143106-pre-update/cron/jobs.json
/home/nish/.hermes/state-snapshots/20260820-172625-pre-update/cron/jobs.json
/home/nish/.pi/agent/AGENTS.md.folded-20260919
```

What those are: Aug-20 cron state snapshots, session/log/cache dumps, two
vendored `site-packages` metadata files and hermes-agent's own checkout (its
test docstrings describe the CodeRabbit GitHub app, not a local gate), and the
folded backup of the old `~/.pi/agent/AGENTS.md`, whose line 197 listed the
skill among the review gates. No systemd unit, no crontab line, nothing under
`~/.local/bin`.

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
- `config/rule-enforcement.json:548` on each product repo's `origin/main`
  (`inish-site`, `aiconverter-app`, `siterep-public`; `inish-site`'s working
  tree sits at 547 on its `ci/deploy-noop` branch, so read `origin/main`) —
  `led-coderabbit` records `"mechanism": "none — waiting on a Nish-reserved
  auth action"`, status "fleet is ordered to run without the local gate until
  then". That status is already true; the remaining decision is Nish's
  re-auth, which stays open and untouched. Part of #8838.
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
  is present in every fleet-ops worktree on this host — 12 at the time of the
  sweep, all sharing md5 `8805db23`, i.e. the same merged-PR snapshot — and
  none of them is an invoker.
- `~/workspaces/fleet-knowledge-base/01-inbox/.queue/burndown.jsonl:4729,6898`
  — the kb-burndown append log (last written 2026-08-23), whose two hits are
  `source` paths of August vault notes about the old `crgate` quota guard and a
  CodeRabbit remediation product contract; data records, not configuration.
- The rest of the keyword hits: agent transcripts and session dumps under
  `~/.pi/agent/sessions/`, `~/.claude/projects/`, `~/.cursor/projects/`,
  `~/.hermes/{logs,sessions,cache}/`; vendored third-party code
  (`site-packages` metadata, `hermes-agent` test docstrings); the Claude
  resume notes and history (`~/.claude/resume-notes/`, `~/.claude/history.jsonl`)
  which record past runs rather than schedule any; and vault or
  `fleet-knowledge-base` prose from August. History, logs and vendored code —
  none of them a launch path.

## Deletion + acceptance proof

Pre-delete state — the dir held exactly one file, `SKILL.md` (the trailing
comment is the reader's note, not command output):

```
$ ls -la ~/.pi/agent/skills/coderabbit-review/
total 28
drwxr-xr-x   2 nish nish  4096 Sep 28 15:31 .
drwxr-xr-x 116 nish nish 20480 Sep 28 15:31 ..
-rw-r--r--   1 nish nish  3415 Sep 28 15:31 SKILL.md
```

The deleted `SKILL.md`'s frontmatter, in full, recovered verbatim from a
pre-delete skill-index dump still on the host
(`~/.cursor/projects/home-nish/agent-tools/*.txt`, which carries the whole
`<available_skills>` block including `<location>…/skills/coderabbit-review/SKILL.md</location>`):

```
name: coderabbit-review
description: "Local pre-commit/pre-push code review using the CodeRabbit CLI. Use before committing or pushing a non-trivial change, and when the user asks for a CodeRabbit review. This is the LOCAL gate only — it does not replace autoreview, ce-code-review, or the /code-review plugin."
metadata:
  version: "0.1.1-nish"
  upstream: "coderabbitai/skills v1.1.1 (skills/code-review), adapted for CLI 0.7.x"
```

The stale pointer the autoreview retirement left in this description — the
`autoreview` sibling, retired hours earlier the same day and recorded at
`retired-mechanisms.md:23` — died with the file.

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
