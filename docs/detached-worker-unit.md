# The detached worker unit

This file carries the rule — "Session-outliving work is a systemd transient
unit" — and holds the one-line command. The full rules live in the vault
`_system/shared-memory/global-standing-rules.md`, which `AGENTS.md` names for
them. Issue: nish-vault#46 item 4.

Session-outliving work is a systemd transient unit, never `nohup pi ... &` or a
trailing `&`: those die with the shell (fleet-ops#350) and launch with no dead-man
(fleet-ops#4266).

One line, stock systemd, no wrapper script:

    sudo systemd-run --uid=nish --gid=nish -p RuntimeMaxSec=<seconds> -p "TemporaryFileSystem=$HOME/.config/gh" -E DELIVERABLE=<abs path> -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' --unit <name> -- sh -c 'cat <packet.md> | $HOME/.local/bin/pi --print --provider <provider> --model <model>'

- `TemporaryFileSystem=` blanks the human gh login the way `agent.yml`'s jail does,
  so a worker cannot fall back to it.
- `RuntimeMaxSec=` is the deadline and the Pi run's only bound: pi exposes no
  per-request timeout, so one model call that never returns holds the whole
  process until the deadline — that burned `fix-pr-10422.service`'s full hour at
  14 s of CPU with no deliverable and fired `SystemUnitFailed` (fleet-ops#10448).
  At the deadline systemd terminates the unit into `Result=timeout`: SIGTERM
  first, SIGKILL after `TimeoutStopSec` (systemd.service(5)), and the journal
  names the death: `Service reached runtime time limit. Stopping.` then
  `Failed with result 'timeout'`. A second timer on the exec line is dead
  weight: it never fires when the deadline fires first, and its journal line
  never appears. To end a hung run sooner, set `RuntimeMaxSec=` to the wall the
  run deserves.
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
