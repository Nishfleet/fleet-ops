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

## The seats sandbox for interactive sessions

The deny rules bind the command text, and a same-uid reader reaches a seat file
with a relative path a string rule cannot spell (`cd ~/.config && cat
fleet-ops/seats/x` above), while a file mode binds only readers of other uids
(fleet-ops#11114). The control for the same-uid boundary is the kernel, not the
command text: start an interactive session inside a bubblewrap sandbox that
mounts an empty tmpfs over the seats directory, the same mount primitive the
worker jail builds in `agent.yml`:

    bwrap --dev-bind / / --tmpfs ~/.config/fleet-ops/seats --ro-bind-try ~/.zshenv ~/.zshenv --ro-bind-try ~/.zprofile ~/.zprofile --ro-bind-try ~/.zshrc ~/.zshrc --ro-bind-try ~/.zlogin ~/.zlogin --proc /proc --unshare-pid --die-with-parent claude

`--new-session` is left out: bwrap(1) calls setsid there, which takes the
interactive TUI's controlling terminal away (no SIGWINCH redraw, no job
control). The injection direction it guarded is closed by the kernel instead:
`rootfs/etc/sysctl.d/62-fleet-tty-tiocsti.conf` sets `dev.tty.legacy_tiocsti
= 0`, so a process inside the sandbox cannot inject keystrokes (TIOCSTI) into
the shell that launched it, on this kernel (which builds
`CONFIG_LEGACY_TIOCSTI` out) and on any later one that builds it back in.

Inside it the seats directory exists but is empty, so the deny-rule bypass shape
cannot matter: a path spelling the mount table has already hollowed out, be it
`cd`-relative, runtime-built, glob, `readlink`-resolved or reached back through
`/proc/self/root`, opens a namespace with nothing behind it. The sandbox session
sees `~/.config/fleet-ops/seats` as an empty tmpfs and never the live seat
files.

- Verify: `tests/test_host_config_umask_dropins.py` reads the login profile
  back and holds it to the umask line plus the `claude` wrapper, so a later edit
  that drops the wrapper fails the suite.
- The box enforces it: a login shell, which is how sshd and tmux start one on
  this box, defines `claude` as a function that runs this sandbox line
  (`rootfs/etc/zsh/zprofile`), so the default `claude` start is inside the
  boundary and the launch line above is what the function runs, not a line to
  remember. The file is installed by the gated copy task in
  `ansible/host.yml`, the same root-owned path that carries its umask line, so
  a merged change reaches `/etc` with the next host config run.
- It fails closed: with the seats directory present and bubblewrap missing,
  the wrapper prints why and does not start claude, because a silent
  unsandboxed start after a package removal is the exposure this closes. A
  shell already inside the sandbox sees the seats tmpfs in its own
  `/proc/self/mounts` and starts claude directly, so no environment variable
  can skip the wrap.
- Residual, on purpose: the wrapper binds sessions that a login shell starts.
  A start that dodges it (`command claude`, a full path, a non-login shell) is
  the owner's own act, and the unattended lanes keep their own jails, so the
  wrapper never touches them.
- Out of scope, named so nobody reads more into the boundary: the sandbox
  hides the seats files from the session's own process tree only. A session
  can still ask a process outside it to read them (ssh to localhost, the user
  systemd bus, a tmux server started before it, the Docker socket). It can also
  write a zsh startup file
  in the home for the owner's next login, which the wrapper binds read-only
  when it exists (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin`) but
  cannot stop it from creating. The mount check also trusts any tmpfs on the
  seats path, including one from a separate unprivileged mount namespace,
  which already hides the files.
- Out of scope: the sandbox hides only the seats directory. The other secrets
  the worker jail hides (the Tincan secret directory, the worker App key, the
  gh login, the Cloudflare tokens) stay readable in an interactive session,
  because fleet-ops#11320 is the seats boundary only.
- Not taken, the vendor Bash sandbox (`sandbox.enabled` with
  `filesystem.denyRead`, deliverable box-wide through this managed-settings
  file): its own docs put the built-in file tools outside it — "A `denyRead`
  entry doesn't stop the Read tool" (code.claude.com/docs/en/sandboxing,
  "What runs outside the sandbox") — so it does not draw the same-uid boundary
  for the Read/Edit shape of fleet-ops#11114. The same docs name the boundary
  that covers the file tools too: run the Claude Code process itself inside
  one, which is what this sandbox is. The proxy cost stands: the vendor
  sandbox routes shell network traffic through a local proxy with an empty
  allowed-domain list, so turning it on box-wide would charge every
  unattended lane one allowlist entry per endpoint — a policy change of its
  own, not a by-product of this fix.
- A per-seat uid would bind every reader, but the fleet's own
  consumers (`agent.yml`, the runner drop-ins, the provider watch) read the
  seats as the same user, so the packet's ranking puts the sandbox first
  (fleet-ops#11114, fleet-ops#11320).

