## Managed-settings defaults

`rootfs/etc/claude-code/managed-settings.json` is the box-wide Claude Code
managed settings file itself, not a drop-in. `ansible/host.yml` installs it with
the same `validate:` as the drop-ins, so a file that is not a JSON object never
reaches `/etc` and cannot stop Claude Code from starting. It carries the
subagent model, the advisor model, the per-model settings, the hand-picked
`model-lanes` plugin and the box-wide permission `deny` and `ask` lists.
`/etc/claude-code` is not in `owned_dirs`: every file in it is covered by an
explicit copy task, a single-file one or a directory one, never a sweep.

The permission lists hold three invariants, and
`tests/test_claude_managed_settings.py` checks each one. No rule names a tool
whose rules the file permission check ignores: Claude Code matches a file rule by
tool name and maps Write, NotebookEdit and MultiEdit onto Edit and Glob onto
Read, so a `Write(path)` or `Glob(path)` rule is dead text while an `Edit(path)`
deny already stops the Write tool. A path the list stops the Read tool on also
stops the editing tools, so a directory an agent cannot read is one it cannot
overwrite either. And no `ask` rule's command is already denied, because deny is
checked first and such a rule never prompts. Each of the three was a live hole
before 2026-10-30 (fleet-ops#10567).

The seat and tincan Bash rules are string rules, so their reach is the path as
the command spells it: the Bash rule that covers the seats directory stops a command that
names the directory, and a command that reaches the same file by a relative path
(`cd ~/.config && cat fleet-ops/seats/x`) names no denied substring. A reader that hides
the path altogether gets past every rule that could name it: `cd ~/.config && python3 -c
"open('fleet-ops/seats/x').read()"` reached the filesystem, so no pattern could match (fleet-ops#11114).
The file mode this playbook now holds closes that hole only for the other uids — runner users,
jailed engines outside the hides, other local accounts: ansible/tasks/secrets.yml keeps
`~/.config/fleet-ops/seats` at 0700 and every `.env` under it at 0600 on every apply — 0600, not
the issue's 0400, because a seat file edited by hand is written in place by a shell redirect as
nish, and group and other are what the mode denies — and it runs as nish, so a planted symlink
cannot steer a root chmod. ansible/tasks/final-checks.yml fails the deploy naming any file or the
directory whose mode or owner drifts. A process already reading as nish gets past both: no string
rule can name the built path, and no file mode binds the reader's own uid, so that hole stays open
in Nishfleet/fleet-ops#11320, whose control is the issue's option 2, a sandbox for interactive
sessions, or a per-seat uid. The Bash rules stay: they bind the command text, they deny a command
that only mentions the path, and they hold the rule boundary they have held.

- Verify: `cmp /etc/claude-code/managed-settings.json
  rootfs/etc/claude-code/managed-settings.json` is silent (the box copy is the
  repo copy), and `claude -p hi` starts on the box. The box copy follows the
  merge: `deploy-box.yml` starts `fleet-host-config.service`, which applies
  `ansible/host.yml`, so a merged change reaches `/etc` on that run and not
  before. Prove one permission rule with `claude -p "Run exactly this one Bash
  command and report its output: cat ~/.config/tincan/inbox.secret"
  --allowedTools Bash --output-format stream-json --verbose`: a denied command
  reports `Permission to use Bash with command <cmd> has been denied.`, and a
  rule under test can be added for one run with `--settings
  '{"permissions":{"deny":["Bash(<pattern>)"]}}'`, which merges with the managed
  lists (proved 2026-10-30: the managed `Bash(wrangler:*)` deny still fired with
  an unrelated `--settings` deny in place).
- The seat mode lands with the apply on each deploy: `stat -c '%a' ~/.config/fleet-ops/seats`
  prints `700`, and every `stat -c '%a %n' ~/.config/fleet-ops/seats/*.env` prints `600`.
- Switch it off: a PR that deletes the file from `rootfs/` and adds
  `/etc/claude-code/managed-settings.json` to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  file under `rootfs/etc/claude-code/` is a JSON object, its copy task runs that
  JSON-object `validate:` as root and keeps the file's mode, and the defaults
  file is installed as itself and not as part of a directory copy.

