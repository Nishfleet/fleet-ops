## systemd by default

A backgrounded `pi` dies when the launching shell ends, and the four
`EXTLOAD-OK` lines it leaves behind look like a dead seat. Detached runs are a
systemd transient unit. There is no wrapper script: `bin/pi-systemd-run` (523
lines) and `bin/pi-detached-deadman` (410 lines) were deleted on 2026-09-18 and
replaced by two stock `systemd-run` properties.

```
systemd-run --user --collect --unit <name> \
  -p RuntimeMaxSec=<seconds> \
  -p Requires=fleet-worker-github-token@<repo>.service \
  -p After=fleet-worker-github-token@<repo>.service \
  -p "EnvironmentFile=$XDG_RUNTIME_DIR/fleet-worker-github-token/<repo>.env" \
  -p "TemporaryFileSystem=$HOME/.config/gh" \
  -p 'ExecStartPre=/bin/sh -c '"'"'test -n "$GH_TOKEN"'"'"'' \
  -E DELIVERABLE=<absolute artifact path> \
  -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' \
  -- sh -c 'cat /path/to/packet.md | pi --print --provider <provider> --model <model>'
```

`<repo>` is the Nishfleet repo the worker targets. `Requires=` pulls in
`fleet-worker-github-token@<repo>.service`, which mints a one-hour nishfleet-worker
App token limited to that repo into `$XDG_RUNTIME_DIR/fleet-worker-github-token/<repo>.env`;
the `EnvironmentFile=` is required (no `-`), so a failed mint means the worker never
starts, and `ExecStartPre=` fails an empty `GH_TOKEN` before any work. `TemporaryFileSystem=`
blanks the human gh login for the run, as agent.yml's jail does, so a worker cannot fall
back to it (fleet-ops#9738). The launch line exits non-zero when it refuses.

`RuntimeMaxSec=` is the deadline: systemd kills an over-running unit into
`Result=timeout`. The `ExecStopPost=` line is the deliverable check: a stop at
exit 0 that left no artifact becomes `Result=exit-code`, i.e. `failed`, which is
what `OnFailure=` and the failed-units pass key off. Both halves were proven on
this host on 2026-09-18 (RED: no artifact -> `Result=exit-code`; GREEN: artifact
written -> `Result=success`; `RuntimeMaxSec=5` against `sleep 60` ->
`Result=timeout`).

Drop `--collect` when you want the dead unit to stay listed in
`systemctl --user list-units --state=failed`. With `--collect` systemd unloads
the unit as soon as it dies, so the failure survives only in the journal
(`journalctl --user -u <name>`).

Watch a live run with `systemctl --user status <name>.service`.

Not a dispatcher: no retry ladder, no seat rotation, no queue. `RuntimeMaxSec=`
and the deliverable check together are the whole of what the retired wrapper's
`--deadline` and `--deliverable` flags did (fleet-ops#4266); the healthchecks
dead-man ping and the `fleet_detached_job_died` gauge went with the script, and
the `DetachedJobDied` alert that read that gauge was deleted with them — systemd
already records the death.

If the packet clones a repo, use a reference clone against the local
bare mirror (fleet-ops#1213), not a full GitHub copy:

```
git clone --reference-if-able /home/nish/workspaces/.mirrors/<repo>.git \
  https://github.com/Nishfleet/<repo>.git <dest>
```

Never `--dissociate` on throwaway worktrees. Never push to a mirror
(read-only fetch target). A missing, stale or corrupt mirror degrades to a
plain clone — which is exactly why the `git-mirror-update` refresher was
deleted in the 2026-09-18 glue sweep: `--reference-if-able` borrows whatever
objects the mirror already has and fetches the rest from GitHub, so a mirror
that stops being refreshed costs a little bandwidth, never correctness. The
mirrors under `/home/nish/workspaces/.mirrors` are left in place (14G) and
are still worth borrowing from; refresh one by hand with
`git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all` if it ever
drifts far enough to matter.

One trap lives inside the mirror itself (fleet-ops#5737): a mirror whose
fetch refspec covers `refs/heads/*` and `refs/tags/*` only never updates any
leftover `refs/remotes/origin/*` refs — `git show origin/main:<file>` against
the mirror then silently serves hours-old content while `main` is current.
Map the heads namespace into the remote-tracking one so the two spellings
cannot disagree, then refresh:

```
git -C /home/nish/workspaces/.mirrors/<repo>.git config --add \
  remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all
```

Every fetch then force-moves `refs/remotes/origin/*` to the same SHAs as
`refs/heads/*`, so a stale spelling heals on the next fetch instead of
lying. A mirror cloned fresh from GitHub carries no `refs/remotes/` at all
— its `origin/main` spelling fails loudly instead of lying until the first
fetch seeds it (correctly, under the refspec above). A mirror cloned from
another mirror inherits whatever remote-tracking refs the source carries —
the refspec above is what keeps them honest either way. Never
hand-`update-ref` `refs/remotes/origin/*` in a mirror.

A short log with no verdict after a backgrounded launch is a **launcher fault**
(the session reaped the process). A log containing `rate_limit` /
`ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do not mix
them up.

The Claude PostToolUse hook `~/.claude/hooks/guard_pi_packet.py` classifies
these from the redirected packet log. Launcher faults advise the transient-unit
one-liner above; lane faults advise seat rotation.

