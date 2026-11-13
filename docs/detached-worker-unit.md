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

A transient unit carries its command's exit status, and the command's last
statement owns it. A probe that ends on a diagnostic ends the way the
diagnostic ends, not the way the check ends: `which node npm` exits 1 when
any named command is missing, so a jail that carries pi but not npm fails a
probe on that line alone, whatever its check printed, and the unit stays
loaded in `failed` state — firing `SystemUnitFailed` and leaving a leftover
that only a privileged hand can clear (RUNBOOK, "The failed-unit check and
leftover ad-hoc units"). Seen 2026-11-13 as the run-u344764.service alert:
a lane-health probe in a jail that bound only `~/.local/bin/pi` ended on
`which node npm`. End a probe with its own check's status, and bind every
tool its command names into the jail.

## Why system scope, never `--user` and never `--collect`

Two reasons, both proven 2026-10-25 with `sudo systemd-run --uid=nish` probes:

1. node_exporter reads only the system bus, so only a system unit's failure fires
   `SystemUnitFailed` and becomes a fix job. On 2026-10-24, ten `--user` Pi units
   hit their deadline and nothing noticed.
2. Sandbox properties such as `TemporaryFileSystem=` are silently ignored in user
   units on this host. A timed-out unit showed
   `node_systemd_unit_state{state="failed"}=1` within 75 s, and inside the unit
   `~/.config/gh` was empty, with 3 entries on the host, while `GH_TOKEN` was set.

Watch a live run with `systemctl status <name>.service`; after it ends, the
journal keeps the record (`journalctl -u <name>`). Not a dispatcher: no retry
ladder, no seat rotation, no queue.

A short log with no verdict after a backgrounded launch is a **launcher fault**
(the session reaped the process; use the one line above). A log containing
`rate_limit` / `ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do
not mix them up.

## Cloning inside a run: borrow from the local mirror

If the packet clones a repo, use a reference clone against the local bare
mirror (fleet-ops#1213), not a full GitHub copy:

```
git clone --reference-if-able <home>/workspaces/.mirrors/<repo>.git \
  https://github.com/Nishfleet/<repo>.git <dest>
```

Never `--dissociate` on throwaway worktrees. Never push to a mirror (read-only
fetch target). A missing, stale or corrupt mirror degrades to a plain clone:
`--reference-if-able` borrows whatever objects the mirror already has and
fetches the rest from GitHub, so a mirror that stops being refreshed costs a
little bandwidth, never correctness. Refresh one by hand with
`git -C <home>/workspaces/.mirrors/<repo>.git fetch --all` if it ever drifts far
enough to matter. fleet-ops is the exception: agents read the checkout the host
play itself keeps on main (moved by `ansible/tasks/user-files.yml` on every
deploy), never a mirror of it.

One trap lives inside the mirror itself (fleet-ops#5737): a mirror whose fetch
refspec covers `refs/heads/*` and `refs/tags/*` only never updates any leftover
`refs/remotes/origin/*` refs, so `git show origin/main:<file>` against the
mirror silently serves hours-old content while `main` is current. Map the heads
namespace into the remote-tracking one so the two spellings cannot disagree,
then refresh:

```
git -C <home>/workspaces/.mirrors/<repo>.git config --add \
  remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C <home>/workspaces/.mirrors/<repo>.git fetch --all
```

Every fetch then force-moves `refs/remotes/origin/*` to the same SHAs as
`refs/heads/*`, so a stale spelling heals on the next fetch instead of lying. A
mirror cloned fresh from GitHub carries no `refs/remotes/` at all: its
`origin/main` spelling fails loudly until the first fetch seeds it. A mirror
cloned from another mirror inherits whatever remote-tracking refs the source
carries; the refspec above keeps them honest either way. Never hand-`update-ref`
`refs/remotes/origin/*` in a mirror. fleet-ops leans on none of this: the
checkout agents read is moved to main by the host play itself.
