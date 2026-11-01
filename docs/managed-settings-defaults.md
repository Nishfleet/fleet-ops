## Managed-settings defaults

`rootfs/etc/claude-code/managed-settings.json` is the box-wide Claude Code
managed settings file itself, not a drop-in. `ansible/host.yml` installs it with
the same `validate:` as the drop-ins, so a file that is not a JSON object never
reaches `/etc` and cannot stop Claude Code from starting. It carries only
the box-wide permission `deny` and `ask` lists: Read and Edit denies on the seat
and tincan secrets (fleet-ops#10567, fleet-ops#11114), an Edit deny on the deploy
clone (fleet-ops#9437), the Wrangler deny (customer-data deletion and
out-of-pipeline deploys stay process-gated), and asks on force pushes and other
commands that destroy data or reboot the box. The model, plugin and style rules
left on 2026-11-01 (fleet-ops#10935): stock features only.
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
(`cd ~/.config && cat fleet-ops/seats/x`) names no denied substring. The `*`
prefix also matches a command that only mentions the path, so `rg -n
'/.config/tincan/' docs` is denied too. Closing the relative-path hole needs a
file mode or a sandbox, not another pattern (fleet-ops#11114).

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
- Switch it off: a PR that deletes the file from `rootfs/` and adds
  `/etc/claude-code/managed-settings.json` to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  file under `rootfs/etc/claude-code/` is a JSON object, its copy task runs that
  JSON-object `validate:` as root and keeps the file's mode, and the defaults
  file is installed as itself and not as part of a directory copy.

