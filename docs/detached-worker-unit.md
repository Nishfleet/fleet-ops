# The detached worker unit

`AGENTS.md` → "Session-outliving work is a systemd transient unit" carries the
rule and points here. This file holds the one-line command. Issue: nish-vault#46
item 4.

Session-outliving work is a systemd transient unit, never `nohup pi ... &` or a
trailing `&`: those die with the shell (fleet-ops#350) and launch with no dead-man
(fleet-ops#4266).

One line, stock systemd, no wrapper script:

    XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start fleet-worker-github-token@<repo>.service && sudo systemd-run --uid=nish --gid=nish -p RuntimeMaxSec=<seconds> -p "EnvironmentFile=/run/user/1000/fleet-tokens/worker/<repo>.env" -p "TemporaryFileSystem=$HOME/.config/gh" -p 'ExecStartPre=/bin/sh -c '"'"'test -n "$GH_TOKEN"'"'"'' -E DELIVERABLE=<abs path> -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' --unit <name> -- sh -c 'cat <packet.md> | $HOME/.local/bin/pi --print --provider <provider> --model <model>'

`<repo>` is the Nishfleet repo the worker targets.

- The `systemctl --user start` mints that run's `GH_TOKEN`
  (`systemd/fleet-worker-github-token@.service`, a one-hour nishfleet-worker App
  token limited to `<repo>`), and the `&&` stops the launch when the mint fails
  (fleet-ops#9738).
- `ExecStartPre=` makes an empty token exit non-zero before any work.
- `TemporaryFileSystem=` blanks the human gh login the way `agent.yml`'s jail does,
  so a worker cannot fall back to it.
- `RuntimeMaxSec=` is the deadline (systemd kills into `Result=timeout`).
- The `ExecStopPost=` line is the deliverable check: a stop at exit 0 with no
  artifact becomes `Result=exit-code`, i.e. `failed`.

## Why system scope, never `--user` and never `--collect`

Two reasons, both proven 2026-10-25 with `sudo systemd-run --uid=nish` probes:

1. node_exporter reads only the system bus, so only a system unit's failure fires
   `SystemUnitFailed` and becomes a fix job. On 2026-10-24, ten `--user` Pi units
   hit their deadline and nothing noticed.
2. Sandbox properties such as `TemporaryFileSystem=` are silently ignored in user
   units on this host. A timed-out unit showed
   `node_systemd_unit_state{state="failed"}=1` within 75 s, and inside the unit
   `~/.config/gh` was empty, with 3 entries on the host, while `GH_TOKEN` was set.
