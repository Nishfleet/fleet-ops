# The runner jail's `.config` is nobody:nogroup, because systemd creates it as namespace root

Paths under the runner user's home are written `<home>/…` below: the repo's
private-detail scan (`docs/private-detail-scan.md`) keeps personal home paths out of
docs, and the verbatim lines live in the linked runs and issues.

**Date:** 2026-10-30
**Issues:** fleet-ops#11120, fleet-ops#11231
**Runs:** 40971357405, 40971509479

## What was asked

Two strong-only worker runs died in about 90 seconds with:

    bwrap: Can't mkdir <home>/.config/gh: Permission denied

The live state the issue recorded: `.config` and `.config/cloudflare` read
`nobody:nogroup`, mtimes 04:40; `.config/fleet-worker` read `nish:nish`, mtime 04:43.

The ask was to make `.config` `nish:nish` again, to name the unit that recreated it at
about 04:40 IST with a journal line as evidence, and to put the fix in config so a
future recreation lands `nish:nish`.

## What the mechanism is

`nobody:nogroup` is not a foreign owner that re-owned the directory. It is systemd's own
mount point, seen from inside a user namespace that maps one uid.

The runner unit masks the whole home with a tmpfs and then creates the mount points the
worker jail masks over it (`rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-.service.d/20-lockdown.conf`).
The unit's own lines are the home tmpfs itself —
`TemporaryFileSystem=<home>:mode=0700,uid=1000,gid=1000,size=512M` — and a read-only
mount point per masked path: `.config/cloudflare`, `.config/gh` and
`.config/fleet-worker`, each `:ro`.

systemd creates `.config` and each mount point under it as root, at unit start (each
point with the tmpfs default mode 0755, per mount(8)'s `mode=`, whatever the parent
tmpfs's `mode=0700`; systemd.exec(5)'s `TemporaryFileSystem=` creates the named path if
it is missing).
The runner's namespace maps one uid, so the namespace's root is unmapped and every file it
creates reads as uid 65534 (user_namespaces(7): a file whose owner is unmapped in the
reader's namespace shows as `nobody`):

    $ cat /proc/self/uid_map
    1000       1000          1

So the owner is `nobody:nogroup` (65534) by construction, and it is not something Ansible,
`tmpfiles.d` or a podman scope can change: those write into the host's home, and the
host's home is not the directory the job sees. The runner's home is a tmpfs the
unit makes for itself.

The `mtime` of the directory is the proof that the unit creates it. The runner pool
restarted at 16:48:14 IST on 2026-10-30 and `.config` and `.config/gh` carry mtimes in
that second (16:48:14.674 and 16:48:14.671, both `nobody:nogroup 755`), while
`.config/fleet-worker` carries a job jail's start instead (22:50:50, `nish:nish 755`).
`ActiveEnterTimestamp` has one-second resolution, so the second is the finest match the
pair supports. In the re-check below the two points share one timestamp to the
nanosecond: the kernel stamps with a coarse per-jiffy clock, and PID 1 created both in
the same tick.

    $ systemctl show actions.runner.Nishfleet.netcup-agent-4.service -p ActiveEnterTimestamp --value
    Fri 2026-10-30 16:48:14 IST

A re-check on 2026-10-31, on netcup-agent-13 after that night's update, repeats the pair
and adds the journal line the ask wanted. The `uid_map` line above was read inside this
session's job jail on that host; the unit's namespace maps the same single uid. The
unit's own journal puts the listener start
of that restart at 03:53:34.917 (its `.path` line at 03:53:34.886 precedes it), just
after the directory's 03:53:34.849 mtime: the mount point is in place before the runner
service starts.

    $ stat -c '%U:%G %a %y' ~/.config ~/.config/gh ~/.config/fleet-worker
    nobody:nogroup 755 2026-10-31 03:53:34.849192127 +0530
    nobody:nogroup 755 2026-10-31 03:53:34.849192127 +0530
    nish:nish 755 2026-10-31 07:45:13.914179292 +0530

    $ systemctl show actions.runner.Nishfleet.netcup-agent-13.service -p ActiveEnterTimestamp --value
    Sat 2026-10-31 03:53:34 IST

    $ journalctl -u actions.runner.Nishfleet.netcup-agent-13.service --output short-precise | grep "Starting Runner listener"
    Oct 31 03:53:34.917406 netcup-rs2000 runsvc.sh[1370763]: Starting Runner listener with startup type: service

The third line is the asymmetry the mechanism predicts: `.config/fleet-worker` reads
`nish:nish` at 07:45 because a job's own bwrap has tmpfs-mounted over the unit's point,
and the fresh tmpfs root is a directory the job's uid created, stamped with the jail's
start, not the unit's.

The 04:40 recreation on 2026-10-30 was the nightly host update, which stops and starts every
runner. The log names each restart (`/var/lib/fleet-ops/fleet-update.log`):

    2026-10-30 04:36:10,349 p=3858338 u=root n=ansible | changed: [localhost] => (item=actions.runner.Nishfleet.netcup-agent-4.service)
    2026-10-30 04:36:22,106 p=3858338 u=root n=ansible | changed: [localhost] => (item=actions.runner.Nishfleet.netcup-agent-5.service)

The unit journal's own lines for that restart have rotated out (the oldest agent-4 entry
left today is 18:04 IST), so these ansible restart lines are the surviving record of it.

The restart picked up the gh bind cut of fleet-ops#10949 (`d2c4980e4`, PR #11000,
2026-10-30 00:44 IST), which removed the read-only bind that used to create
`.config/gh` on the host. (fleet-ops#10826 cut two read-only fleet-config paths
the same night, `c6d0ec2dd` at 02:51 IST; it never touched the gh bind.) With the bind gone,
only the unit's own `TemporaryFileSystem=` mount point is left, and that one is a directory
the job's own uid cannot write into.

The directory was `nish:nish` before that only by accident: the bind mounted the host's real
directory, which the host's own owner had. The ownership was never the thing the jail needed.

## The fix, and where it landed

The jail needs a mount point it can mount over, and the unit has to create that point. That
is the fix in `78c5bdea9` (fleet-ops#11097, PR #11109), which added the missing gh
`TemporaryFileSystem=` line to the lockdown drop-in (the fleet-worker line came later,
`a41aa761d`, PR #11057; the drop-in's own comment names fleet-ops#11097). The fix landed
later the same day, after the 04:36 restart that exposed the gap, so the two runs died
with the gap and the next restart after the fix starts.

With the mount point present, bwrap mounts over it instead of creating it, so the job starts.
`tests/test_runner_jail_start_state.py` holds the gate:

    test_every_home_path_the_agent_jails_mask_can_be_mounted
    test_gate_fails_when_the_jail_masks_a_path_the_runner_does_not_create

The gate fails the PR when a workflow masks a home path the runner's own drop-in does not
create at start. That is the check the ask wanted, expressed against the mechanism that
actually exists.

## What is not the fix

- **Host ownership of `.config`.** Ansible `file:` tasks and a `tmpfiles.d` entry
  change the host's directory. The job never reads the host's directory: the unit replaces
  the home with its own tmpfs before the job starts. PR #11130 proposed exactly this;
  the mount-point fix in PR #11109 superseded the approach, because it cannot change what
  the job sees, and #11130 stayed open, conflicting with main.
- **A `nobody:nogroup` directory is not evidence of a foreign process.** It is the signature
  of a file created by namespace root in a one-uid namespace, which is what the unit's own
  mount points are. A point a job's own bwrap has tmpfs-mounted over reads `nish:nish`
  instead, stamped with the jail's start, not the unit's: the fresh tmpfs root is a
  directory the job's uid created. That is the `fleet-worker` line in the re-check above
  (07:45, a job's jail start, not the 03:53 unit start).

## How to tell the jail starts

The mount points exist when the unit does, so the jail starts when the paths do. A direct
probe with the workflow's own jail arguments (`agent.yml`'s `jail_base`), run on
netcup-agent-13 on 2026-10-31:

    $ bwrap --dev-bind / / --tmpfs $HOME/.config/gh --tmpfs $HOME/.config/cloudflare \
        --tmpfs $HOME/.config/fleet-ops --tmpfs $HOME/.config/fleet-worker \
        --proc /proc --unshare-pid --die-with-parent -- \
        sh -c 'echo "JAIL OK"; stat -c "%U:%G %a" $HOME/.config/gh $HOME/.config/cloudflare $HOME/.config/fleet-ops $HOME/.config/fleet-worker'
    JAIL OK
    nish:nish 755
    nish:nish 755
    nish:nish 755
    nish:nish 755

`.config/fleet-ops` starts although the drop-in's `TemporaryFileSystem=` lines do not name
it: the pool's read-only bind of the fleet config directory creates that directory chain
for every job, so the jail's mount finds a point there too.

And the same probe for a path the unit does not create, which is the failure the two runs hit:

    $ bwrap --dev-bind / / --tmpfs $HOME/.config/nish-not-created --proc /proc --unshare-pid --die-with-parent -- true
    bwrap: Can't mkdir <home>/.config/nish-not-created: Permission denied
