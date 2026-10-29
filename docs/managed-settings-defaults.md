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
`tests/test_claude_managed_settings.py` checks each one. Every `Edit(path)` deny
has its `Write(path)` mirror, because Claude Code matches a rule by tool name and
lists Read, Write and Edit as separate file-pattern tools, so an `Edit` deny
never stops the Write tool. No `ask` rule's command is already denied, because
deny is checked first and such a rule never prompts. And no Bash command reads a
seat or tincan file by hiding its path inside a quoted string, which the Read
path denies alone do not stop. Each of the three was a live hole before
2026-10-30 (fleet-ops#10567).

- Verify: `cmp /etc/claude-code/managed-settings.json
  rootfs/etc/claude-code/managed-settings.json` is silent (the box copy is the
  repo copy), and `claude -p hi` starts on the box. The box copy follows the
  merge: `deploy-box.yml` starts `fleet-host-config.service`, which applies
  `ansible/host.yml`, so a merged change reaches `/etc` on that run and not
  before. Prove one permission rule with `claude -p "Run exactly this one Bash
  command and report its output: <cmd>" --allowedTools Bash --output-format
  stream-json --verbose`: a denied command reports a `permission_denied` event,
  and a rule under test can be added for one run with `--settings
  '{"permissions":{"deny":["Bash(<pattern>)"]}}'`.
- Switch it off: a PR that deletes the file from `rootfs/` and adds
  `/etc/claude-code/managed-settings.json` to `retired` in `ansible/host.yml`.
- The check is the `unit` job's `tests/test_claude_managed_settings.py`: every
  file under `rootfs/etc/claude-code/` is a JSON object, its copy task runs that
  JSON-object `validate:` as root and keeps the file's mode, and the defaults
  file is installed as itself and not as part of a directory copy.

