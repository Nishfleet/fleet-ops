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

## The seats sandbox for interactive sessions

The deny rules bind the command text, and a same-uid reader reaches a seat file
with a relative path a string rule cannot spell (`cd ~/.config && cat
fleet-ops/seats/x` above), while a file mode binds only readers of other uids
(fleet-ops#11114). The control for the same-uid boundary is the kernel, not the
command text: start an interactive session inside a bubblewrap sandbox that
mounts an empty tmpfs over the seats directory, the same mount primitive the
worker jail builds in `agent.yml`:

    bwrap --dev-bind / / --tmpfs ~/.config/fleet-ops/seats --proc /proc --unshare-pid --die-with-parent claude

Inside it the seats directory exists but is empty, so the deny-rule bypass shape
cannot matter: every spelling, `cd`-relative, runtime-built, glob or
`readlink`-resolved, opens a namespace with nothing behind it. The sandbox
session sees `~/.config/fleet-ops/seats` as an empty tmpfs and never the live
seat files.

- Verify: `tests/test_interactive_seats_sandbox.py` builds a synthetic home
  with a probe seat file, checks the doc launch line, and (where bubblewrap is
  installed) runs every held-out case in `tests/evals/cases/seat_bypass.json`
  bare (each reaches the probe) and inside the sandbox (each is blocked). On a
  host without bubblewrap the executed halves skip.
- The numbers are in `tests/evals/results/seat_bypass.json`: 6 held-out bypass
  shapes, written and labelled by a non-Claude family seat before the sandbox
  was built, 1 run each, before reached / after blocked on every case.
- It binds only the sessions started inside it; the sandbox launch is the
  documented way an interactive session starts, not a trap on the `claude`
  binary. A per-seat uid would bind every reader, but the fleet's own
  consumers (`agent.yml`, the runner drop-ins, the provider watch) read the
  seats as the same user, so the packet's ranking puts the sandbox first
  (fleet-ops#11114, fleet-ops#11320).

