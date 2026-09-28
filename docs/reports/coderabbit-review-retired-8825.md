# coderabbit-review skill retired (fleet-ops#8825)

`~/.pi/agent/skills/coderabbit-review` (also reachable as `~/.agents/skills/coderabbit-review` — `~/.agents/skills` is a symlink to `~/.pi/agent/skills`) described itself as the LOCAL review gate: a `crgate` wrapper over the `coderabbit` CLI, adapted from upstream `coderabbitai/skills v1.1.1`. The standing rule is that reviews and gates are GitHub built-ins (rulesets, merge queue, secret scanning, CodeQL, installed review apps) with no local review wrappers, and neither binary exists on this host, so the skill pointed at a CLI that cannot run. Retired 2026-09-28.

## Sweep — nothing live invoked it

Roots searched: `~/workspaces`, `~/.config/systemd/user`, `~/.hermes`, `~/.pi/agent`, `~/.claude`, `~/.cursor`, `~/.local/bin`, systemd unit files, crontab.

```
$ command -v coderabbit cr crgate
(exit 1 for each — absent from PATH and ~/.local/bin)

$ rg -il 'coderabbit|crgate' ~/workspaces/tooling/fleet-ops-deploy-clone/
(no hits, exit 1 — the fleet-ops repo neither installs nor references it)

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

References, not invokers — named so the sweep above is auditable:

- `nish-vault/_system/shared-memory/skills-library/review-adjudication/SKILL.md:12` — a house skill giving "CodeRabbit locally AND Greptile on the PR" as an example of two review engines agreeing; it names no command and nothing runs it.
- `~/.claude/CLAUDE.md.bak-fold-20260919` — folded backup twin of the AGENTS.md line above.
- `aiconverter-app/config/rule-enforcement.json` `led-coderabbit` — records `"mechanism": "none — waiting on a Nish-reserved auth action"`. That auth item stays open and untouched; this retirement removes the dead local gate, it does not resolve whether Nish re-auths CodeRabbit.
- Session transcripts/logs under `~/.pi/agent/sessions/`, `~/.claude/`, `~/.cursor/`, `~/.hermes/` — history, not configuration.

## Deletion + acceptance proof

```
$ ls -la ~/.pi/agent/skills/coderabbit-review/        (before delete)
-rw-r--r-- 1 nish nish 3415 Sep 28 15:31 SKILL.md     (the only file)

$ rm -rf ~/.pi/agent/skills/coderabbit-review

$ ls ~/.pi/agent/skills/coderabbit-review
ls: cannot access '/home/nish/.pi/agent/skills/coderabbit-review': No such file or directory
(exit 2 — the issue's proof line)

$ ls ~/.agents/skills/coderabbit-review
ls: cannot access '/home/nish/.agents/skills/coderabbit-review': No such file or directory
```

The deleted file was an unmodified-context adaptation of upstream `coderabbitai/skills v1.1.1`; reinstall path is `npx skills add` from that upstream if it is ever wanted. One line added to vault `_system/shared-memory/retired-mechanisms.md` beside the 2026-09-28 autoreview entry. If CodeRabbit is wanted again it runs as the installed GitHub review app, not a local CLI wrapper.

encoded: structure - the gate could not run (no CLI on the host) and violated the GitHub-builtins-only review rule; deleting the skill dir is the fix, so there is no file left to put the mistake in
