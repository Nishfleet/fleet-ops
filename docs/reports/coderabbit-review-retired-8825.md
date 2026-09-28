# coderabbit-review skill retired (fleet-ops#8825)

`~/.pi/agent/skills/coderabbit-review` (also reachable as `~/.agents/skills/coderabbit-review` — `~/.agents/skills` is a symlink to `~/.pi/agent/skills`) described itself as the LOCAL review gate: a `crgate` wrapper over the `coderabbit` CLI, adapted from upstream `coderabbitai/skills v1.1.1`. The standing rule is that reviews and gates are GitHub built-ins (rulesets, merge queue, secret scanning, CodeQL, installed review apps) with no local review wrappers, and neither binary exists on this host, so the skill pointed at a CLI that cannot run. Retired 2026-09-28.

## Sweep — nothing live invoked it

```
$ command -v coderabbit cr crgate
(exit 1 for each — absent from PATH and ~/.local/bin)

$ rg -il 'coderabbit|crgate' ~/workspaces/tooling/fleet-ops-deploy-clone/
(no hits — the repo neither installs nor references it)

$ rg -il 'coderabbit|crgate' ~/.config/systemd/user/ ~/.hermes/ ~/.pi/agent/
(excluding the skill dir itself)
~/.hermes/state-snapshots/*/cron/jobs.json   — Aug-20 snapshot data
~/.hermes/logs/errors.log, ~/.hermes/sessions/*.json, ~/.hermes/cache/**  — logs/dumps
~/.pi/agent/sessions/*.jsonl               — agent transcripts
~/.pi/agent/AGENTS.md.folded-20260919      — folded backup of the old AGENTS.md
                                     line listing it among review gates
~/.hermes/hermes-agent/tests/*.py          — CodeRabbit GitHub-app docstrings
site-packages fastapi METADATA             — sponsor-badge URL
(no unit, timer, crontab, process, PATH binary or live config invokes it)

$ XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-unit-files | grep -i coderabbit
(no hits)   $ crontab -l | grep -i coderabbit   (no hits)
```

Adjacent records: `aiconverter-app/config/rule-enforcement.json` `led-coderabbit` already records `"mechanism": "none"` with the fleet "ordered to run without the local gate"; vault `_system/shared-memory/retired-mechanisms.md` gained the retirement line beside the 2026-09-28 autoreview entry.

## Deletion + acceptance proof

```
$ rm -rf ~/.pi/agent/skills/coderabbit-review   (contained SKILL.md only)

$ ls ~/.pi/agent/skills/coderabbit-review
ls: cannot access '/home/nish/.pi/agent/skills/coderabbit-review': No such file or directory
(exit 2 — the issue's proof line)

$ ls ~/.agents/skills/coderabbit-review
ls: cannot access '/home/nish/.agents/skills/coderabbit-review': No such file or directory
```

If CodeRabbit is wanted again it runs as the installed GitHub review app, not a local CLI wrapper.

encoded: rule - a skill dir is a live invoker surface; retirement = invoker sweep + delete + ledger line
