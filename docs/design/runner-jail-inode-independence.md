# Design: runner jail inode independence

Status: shipped in this PR for the agent pool and the vault runner. The fleet-ci
deploy runners keep the leaf masks; the residual and what closes it are below.
Issue: #11232. Parent issue: #10886.

## The two findings a design has to survive

1. **A mount does not survive a recreate.** An `InaccessiblePaths=`/tmpfs mount
   sits on the directory inode it was made on. A host `rm -rf` plus `mkdir` of
   the same path exposes the new contents to the job until the runner restarts
   (the experiment PR #11093 ran, result in its body).
2. **`TemporaryFileSystem=` and bind mounts reach `+` privileged commands.**
   systemd's `execute.c` `apply_mount_namespace` passes those to every command
   and skips only `InaccessiblePaths=`, `ReadOnlyPaths=` and the `Protect*`
   options. Proven in CI run 41065773985 at PR #11093's head 150e730: the
   `ExecStartPre=+/usr/bin/install -d -o nish` mount-point maker failed with
   "Read-only file system", so any pool restart after such a change leaves the
   runner dead at start.

## The design: hide `/run/user` whole

```
InaccessiblePaths=-/run/user
```

The mount's anchor moves from a directory an actor can delete and recreate
(the token dirs) to the directory nothing normal can: `/run/user` is a root
owned 0755 directory on the `/run` tmpfs that systemd's shipped tmpfiles file
makes at boot (`/usr/lib/tmpfiles.d/systemd.conf`, line
`d /run/user 0755 root root -`). An unprivileged process, a user service or any
test teardown cannot delete it, so the mask survives every recreate the
findings name. From the runner's mount namespace, `/run/user` resolves into the
empty 0700 mount and nothing underneath is reached, however many times the
mints, gnupg or a teardown delete and recreate what is under it at the host.
Finding 1 is answered by the anchor, not by a mount that chases an inode.

Finding 2 is answered by choosing the one hide family systemd skips for a
`+` command: `InaccessiblePaths=`. The change adds no `TemporaryFileSystem=`
or `BindPaths=` mount over the mounted path, and it removes the
`ExecStartPre=mkdir` lines from 10-agent.conf and the vault drop-in.
Those lines made the token dirs exist at start so the leaf masks could go on
(fleet-ops#10081); under the parent mask they would fail with
"Permission denied" and the runner would never start — the same case
fleet-ci-3's `30-eval.conf` documents for its `/run/user/1000` hide
(fleet-ops#10120), which is the fleet's precedent that a parent hide lands and
runs. The late token dirs need no pre-start maker any more: they are covered
the moment they appear, before or after a runner restart.

`RuntimeDirectory=` on the mints is untouched, so the token dirs keep their
nish owner and the `RuntimeDirectoryPreserve=yes` fill (#10753). No unit reads
the mount list by path: `runner-probe` reads the `InaccessiblePaths` property
and checks every named path (the `/run/user` entry included) with `test -r`/`-w`
from the job, which still fails loud under the mask and now also fails loud
when the mask is missing, because the bare `/run/user` directory is 0755 root
and readable to the job. It cannot be a silent mask failure.

## What it does not cover

**fleet-ci-1 and fleet-ci-2 keep the leaf masks for the token dirs.** The only
job there, deploy-box, starts `fleet-sync.service` with `systemctl --user`,
which needs the user bus at `/run/user/1000/bus` visible in the runner's
namespace; a `/run/user` (or `/run/user/1000`) hide would kill the deploy.
On those two runners the recreate window the findings name stays open for the
token dirs. The marginal risk is small: deploy-box's steps are also the steps
that would run a compromised job's code (a stale-token reader would write a
deploy target), the tokens are repo-scoped and hour-valid, and the
mint-side fill (the `RuntimeDirectoryPreserve=yes` pair) already removed the
common recreator. Closing it needs the deploy trigger to reach fleet-sync
without the job's user bus (for example a `PathChanged=` user path unit the job
feeds by writing a file), which is a deploy-flow change, not a jail drop-in
edit; it should be its own issue against the parent, not part of this PR.

The other constraint in #11232 (a runner re-reads its drop-in only at
restart, and the fleet's own deploy restarts no runner) is unchanged: the
agent-pool and vault masks land from this merge and take effect when each
runner restarts, on the same person-chosen restart the finding-2 design would
have needed anyway. Hiding the parent asks for none of that a second time:
no mount-point maker, no unit restart ordering and no file move.
