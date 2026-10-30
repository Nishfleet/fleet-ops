# The runner jail's `.config` is nobody:nogroup, because systemd creates it as namespace root

**Date:** 2026-10-30
**Issues:** fleet-ops#11120, fleet-ops#11231
**Runs:** 40971357405, 40971509479

## What was asked

Two strong-only worker runs died in about 90 seconds with:

    bwrap: Can't mkdir /home/nish/.config/gh: Permission denied

The live state was:

    drwxr-xr-x 10 nobody nogroup  200 Oct 30 04:40 /home/nish/.config
    drwxr-xr-x  2 nobody nogroup   40 Oct 30 04:40 /home/nish/.config/cloudflare
    drwxr-xr-x  2 nish   nish      40 Oct 30 04:43 /home/nish/.config/fleet-worker

The ask was to make `/home/nish/.config` `nish:nish` again, to name the unit that recreated it
at about 04:40 IST with a journal line as evidence, and to put the fix in config so a future
recreation lands `nish:nish`.

## What the mechanism is

`nobody:nogroup` is not a foreign owner that re-owned the directory. It is systemd's own
mount point, seen from inside a user namespace that maps one uid.

The runner unit masks the whole home with a tmpfs and then creates the mount points the
worker jail masks over it (`rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-.service.d/20-lockdown.conf`):

    TemporaryFileSystem=/home/nish:mode=0700,uid=1000,gid=1000,size=512M
    TemporaryFileSystem=/home/nish/.config/cloudflare:ro
    TemporaryFileSystem=/home/nish/.config/gh:ro
    TemporaryFileSystem=/home/nish/.config/fleet-worker:ro

systemd creates `/home/nish/.config` and each mount point under it as root, at unit start.
The runner's namespace maps one uid, so the namespace's root is unmapped and every file it
creates reads as uid 65534:

    $ cat /proc/self/uid_map
    1000       1000          1

So the owner is `nobody:nogroup` (65534) by construction, and it is not something Ansible,
`tmpfiles.d` or a podman scope can change: those write into the host's `/home/nish`, and the
host's `/home/nish` is not the directory the job sees. The runner's home is a tmpfs the
unit makes for itself.

The `mtime` of the directory is the proof that the unit creates it. The runner pool restarted
at 16:48:14 IST and the directory carries the same timestamp to the microsecond:

    $ stat -c '%n %U:%G %a %y' /home/nish/.config /home/nish/.config/gh /home/nish/.config/fleet-worker
    /home/nish/.config nobody:nogroup 755 2026-10-30 16:48:14.674181386 +0530
    /home/nish/.config/gh nobody:nogroup 755 2026-10-30 16:48:14.671181186 +0530
    /home/nish/.config/fleet-worker nish:nish 755 2026-10-30 22:50:50.050236899 +0530

    $ systemctl show actions.runner.Nishfleet.netcup-agent-4.service -p ActiveEnterTimestamp --value
    Fri 2026-10-30 16:48:14 IST

The 04:40 recreation on 2026-10-30 was the nightly host update, which stops and starts every
runner. The log names each restart (`/var/lib/fleet-ops/fleet-update.log`):

    2026-10-30 04:36:10,349 p=3858338 u=root n=ansible | changed: [localhost] => (item=actions.runner.Nishfleet.netcup-agent-4.service)
    2026-10-30 04:36:22,106 p=3858338 u=root n=ansible | changed: [localhost] => (item=actions.runner.Nishfleet.netcup-agent-5.service)

The restart picked up the bind cuts of fleet-ops#10826 (`c6d0ec2dd`, 2026-10-30 02:51 IST),
which removed the binds that used to create `/home/nish/.config/gh` on the host. With the bind
gone, only the unit's own `TemporaryFileSystem=` mount point is left, and that one is a
directory the job's own uid cannot write into.

The directory was `nish:nish` before that only by accident: the bind mounted the host's real
directory, which the host's own owner had. The ownership was never the thing the jail needed.

## The fix, and where it landed

The jail needs a mount point it can mount over, and the unit has to create that point. That
is the fix in `78c5bdea9` (fleet-ops#11097, PR #11109), which added the two missing
`TemporaryFileSystem=` lines:

    # The same for the gh login dir the worker jail masks: fleet-ops#10949 cut the bind that used to create it here, so every worker jail died at start with "Can't mkdir /home/nish/.config/gh: Permission denied" (fleet-ops#11097).
    TemporaryFileSystem=/home/nish/.config/gh:ro

With the mount point present, bwrap mounts over it instead of creating it, so the job starts.
`tests/test_runner_jail_start_state.py` holds the gate:

    test_every_home_path_the_agent_jails_mask_can_be_mounted
    test_gate_fails_when_the_jail_masks_a_path_the_runner_does_not_create

The gate fails the PR when a workflow masks a home path the runner's own drop-in does not
create at start. That is the check the ask wanted, expressed against the mechanism that
actually exists.

## What is not the fix

- **Host ownership of `/home/nish/.config`.** Ansible `file:` tasks and a `tmpfiles.d` entry
  change the host's directory. The job never reads the host's directory: the unit replaces
  `/home/nish` with its own tmpfs before the job starts. PR #11130 proposed exactly this and
  it was superseded, because it cannot change what the job sees.
- **A `nobody:nogroup` directory is not evidence of a foreign process.** It is the signature
  of a file created by namespace root in a one-uid namespace, which is what every one of these
  mount points is.

## How to tell the jail starts

The mount points exist when the unit does, so the jail starts when the paths do. A direct
probe with the workflow's own jail arguments:

    $ bwrap --dev-bind / / --tmpfs $HOME/.config/gh --tmpfs $HOME/.config/cloudflare \
        --tmpfs $HOME/.config/fleet-ops --tmpfs $HOME/.config/fleet-worker \
        --proc /proc --unshare-pid --die-with-parent -- \
        sh -c 'echo "JAIL OK"; stat -c "%n %U:%G %a" $HOME/.config/gh $HOME/.config/cloudflare $HOME/.config/fleet-ops $HOME/.config/fleet-worker'
    JAIL OK
    /home/nish/.config/gh nish:nish 755
    /home/nish/.config/cloudflare nish:nish 755
    /home/nish/.config/fleet-ops nish:nish 755
    /home/nish/.config/fleet-worker nish:nish 755

And the same probe for a path the unit does not create, which is the failure the two runs hit:

    $ bwrap --dev-bind / / --tmpfs $HOME/.config/nish-not-created --proc /proc --unshare-pid --die-with-parent -- true
    bwrap: Can't mkdir /home/nish/.config/nish-not-created: Permission denied
