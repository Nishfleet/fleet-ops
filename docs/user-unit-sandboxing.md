# User-unit mount sandboxing is inert on this host

A unit the user manager starts (`systemd --user`) gets none of systemd's mount
sandbox keys on this box: `ProtectSystem=`, `ProtectHome=`, `PrivateTmp=`,
`ProtectProc=`, `ProtectKernelTunables=`, `ProtectControlGroups=`,
`ReadOnlyPaths=`, `ReadWritePaths=`, `InaccessiblePaths=`. The unit starts, the
keys stay in the file, and the process keeps a writable `/`, the shared `/tmp`
and the user manager's own mount namespace (fleet-ops#10880).

## Measured 2026-10-29

`beacon-hermes-poll.service` set `ProtectSystem=strict`, `ReadWritePaths=%h/.beacon`
and `PrivateTmp=yes`. `beacon-otelcol.service` sets none. Both run in the mount
namespace of the user manager:

```
$ systemd --version | head -1
systemd 255 (255.4-1ubuntu8.18)
$ readlink /proc/1805642/ns/mnt   # beacon-hermes-poll
mnt:[4026531841]
$ readlink /proc/1810413/ns/mnt   # beacon-otelcol
mnt:[4026531841]
$ readlink /proc/1664/ns/mnt      # systemd --user
mnt:[4026531841]
$ awk '$5=="/"{print $6}' /proc/1805642/mountinfo
rw,relatime
$ stat -c %i /proc/1805642/root/tmp /tmp
393221
393221
$ journalctl --user -u beacon-hermes-poll.service --no-pager | grep -ci 'mount namespac'
0
```

## Cause

Three pieces, each measured here.

1. systemd v255 creates an unprivileged user namespace for a user unit that names
   any namespacing option (`exec_context_need_unprivileged_private_users()` in
   `src/core/exec-invoke.c`), and then unshares the mount namespace
   (`unshare(CLONE_NEWNS)`, `src/core/namespace.c`). Beacon carries the mark of
   that first step, its own user namespace with the identity map:

   ```
   $ readlink /proc/1805642/ns/user
   user:[4026532797]
   $ cat /proc/1805642/uid_map
        1000       1000          1
   ```

2. Ubuntu 24.04 gates unprivileged user namespaces with AppArmor, and this box has
   the gate on. Every process that creates one is moved to the
   `unprivileged_userns` profile, which denies capability checks and has no
   `mount` rules. Inside that namespace, systemd's next step —
   `unshare(CLONE_NEWNS)` — is refused, and so is every other namespace:

   ```
   $ cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns
   1
   $ unshare -U sh -c 'cat /proc/self/attr/current'
   unprivileged_userns (enforce)
   $ unshare -U sh -c 'unshare -m --propagation unchanged sh -c "readlink /proc/self/ns/mnt"'
   unshare: unshare failed: Operation not permitted
   $ unshare -U sh -c 'unshare -n sh -c "readlink /proc/self/ns/net"'
   unshare: unshare failed: Operation not permitted
   $ unshare -U sh -c 'unshare -u sh -c "readlink /proc/self/ns/uts"'
   unshare: unshare failed: Operation not permitted
   $ unshare -U sh -c 'unshare -i sh -c "readlink /proc/self/ns/ipc"'
   unshare: unshare failed: Operation not permitted
   ```

   The first `unshare -U -m` form can look like it works, because util-linux asks
   for the user and the mount namespace in one syscall:

   ```
   $ unshare -U -m --propagation unchanged sh -c 'readlink /proc/self/ns/mnt'
   mnt:[4026532980]
   ```

   systemd does not: `setup_private_users()` puts the process in the user
   namespace first and `apply_mount_namespace()` unshares the mount namespace
   afterwards, which is the order that fails.

   The profile is the gate, not the kernel and not the worker jail. A binary with
   its own profile that carries `userns,` keeps the capability, and the same
   unprivileged process then gets a mount namespace, a private `/tmp` and a
   read-only bind mount that holds:

   ```
   $ bwrap --dev-bind / / --tmpfs /tmp sh -c 'cat /proc/self/attr/current; readlink /proc/self/ns/mnt'
   bwrap (unconfined)
   mnt:[4026532978]
   $ bwrap --dev-bind / / --ro-bind /etc /etc sh -c 'touch /etc/nope'
   touch: cannot touch '/etc/nope': Read-only file system
   ```

3. systemd reads that refusal as "we are in a container" and continues without the
   sandbox, at debug level only (`src/core/namespace.c`, `src/core/exec-invoke.c`):

   ```
   if (unshare(CLONE_NEWNS) < 0) {
           r = log_debug_errno(errno, "Failed to unshare the mount namespace: %m");
           if (ERRNO_IS_PRIVILEGE(r) || ERRNO_IS_NOT_SUPPORTED(r))
                   return -ENOANO;
   ...
   if (r == -ENOANO) {
           ...
           log_exec_debug(context, params, "Failed to set up namespace, assuming containerized execution and ignoring.");
           return 0;
   ```

   Nothing reaches the journal at a level a human reads, which is why the keys sat
   in the files for eight days without a signal.

A path list is only ignored when it maps a path onto itself. A self bind mount
(`ReadOnlyPaths=`, `ReadWritePaths=`, `InaccessiblePaths=`) is dropped silently,
while `TemporaryFileSystem=`, `RootDirectory=`, `DynamicUser=`, `ExtensionImages=`
and a `BindPaths=` that moves a path are "non-trivial" rearrangements, so those
fail the unit at start instead (`insist_on_sandboxing()`).

The seccomp keys still apply, because systemd loads them after it gives up on the
namespace: `apply_protect_clock()` and `apply_syscall_filter()` run after
`apply_mount_namespace()` in `exec_child()`. So do `NoNewPrivileges=`,
`CapabilityBoundingSet=` drops that need no `CAP_SETPCAP`, `SystemCallFilter=`,
`SystemCallArchitectures=`, `SystemCallLog=`, `RestrictNamespaces=`,
`RestrictAddressFamilies=`, `RestrictRealtime=`, `RestrictSUIDSGID=`,
`MemoryDenyWriteExecute=`, `LockPersonality=`, `KeyringMode=` and `MemoryMax=`.
`PrivateUsers=` applies too: it is the user namespace systemd builds, the one step
that AppArmor allows. `ProtectHostname=`'s UTS namespace does not apply (same
`unshare` refusal as above); its seccomp half does.

## The four checks fleet-ops#10880 asked for on the host

1. `systemctl --user show beacon-hermes-poll.service -p ProtectSystem -p PrivateTmp -p PrivateMounts`
   — not run: the worker jail hides the user bus
   (`Failed to connect to bus: Permission denied`). The unit file and `/proc`
   above carry the answer.
2. `journalctl --user -u beacon-hermes-poll.service --no-pager | grep -i 'mount namespac'` —
   ran, no match, because the message is debug level.
3. `systemctl --version` — `systemd 255 (255.4-1ubuntu8.18)`.
   `systemd-analyze security --offline=true` on the unit file — `8.9 EXPOSED`
   before this change, `9.2 UNSAFE` after the three inert keys were deleted. The
   score got **worse**, because a higher number is worse here: the tool counts a
   key whether or not it applies, so deleting a key that never worked raises the
   score while the process gains nothing. It measures the file, not the sandbox,
   and it is not evidence that one exists.
4. The user manager (pid 1664) runs in the initial user namespace and in the mount
   namespace of the host: `user:[4026531837]`, `mnt:[4026531841]`. Not re-read
   from the worker jail, which cannot open another process's namespace links.

## What a unit must do instead

- **A system unit with `User=`**: the system manager is root, so it builds the
  mount namespace before it drops privileges. The `actions.runner.*` units hold
  their `20-lockdown.conf` jail this way: this session runs in
  `mnt:[4026532714]`, not the host's `mnt:[4026531841]`.
- **A `bwrap` jail**: stock, and it holds today (measured above). `agent.yml` uses
  it for the CI job jail.
- **Neither**: delete the keys. A key that does not apply reads as a protection
  that does not exist.

The host change that would make the keys work again is
`kernel.apparmor_restrict_unprivileged_userns=0`. It is not done here: that gate
covers every unprivileged user namespace on the box, containers and browsers
included, so removing it is a security decision, not a bug fix.

## Guard

`tests/test_user_unit_sandboxing.py` fails when a unit this repo installs into a
user manager names one of these keys. It scans `systemd/`, which `fleet-sync.service`
links into `~/.config/systemd/user`, and `rootfs/etc/systemd/user/`, which Ansible
installs to `/etc/systemd/user`. It also fails when a system unit lands in
`systemd/`: system units belong in `rootfs/etc/systemd/system/`, where these keys do
apply, so the guard tells the two apart instead of judging a system unit by a user
unit's rule.

Two keys are deliberately out. `PrivateUsers=` is the user namespace systemd
builds, the one step AppArmor allows. `ProtectHostname=` loses its UTS namespace
half but keeps its seccomp half, so it is not fully inert and a unit may set it for
that half.

When the host allows an unprivileged mount namespace again, delete the test and put
the keys back.
