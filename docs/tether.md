## Tether: our own always-on agent (fleet-ops#9980)

Phase 1 of our own agent: iMessage chat, its own memory, and crash-proofing,
with no live-site, database, GitHub or Cloudflare access. The app lives in the
private repo `Nishfleet/tether`; this repo owns the unit that runs it, because
a per-user unit's unprivileged manager cannot apply namespaced sandbox options
(proven on this box, vault note `claude-vps-listener-locked`), so it must be a
system unit with its own service user.

| Piece | Where |
| --- | --- |
| Unit | `rootfs/etc/systemd/system/tether-agent.service` (`User=tether`, `ProtectSystem=strict`, `ProtectHome=true`, `CapabilityBoundingSet=` empty, `SystemCallFilter=@system-service`, `IPAddressDeny=localhost`) |
| Service user and config directory | `ansible/host.yml` creates the `tether` system user and `/etc/tether` (root:tether 0750) |
| Thread, memory and crash state | `/var/lib/tether` (`StateDirectory=tether`, created by systemd, mode 0700, the unit's working directory) |
| Credentials | `/etc/tether/tether.env`, root:tether 0640, live-only and never in git |
| App | `/opt/tether/<version>-<sha12>` unpacked from the pinned release, `/opt/tether/current` pointing at it; all root:root, read-only to the `tether` user |
| Egress rule | `ansible/templates/tether.nft.j2`, installed as `/etc/nftables.d/tether.nft`, table `inet tether` |

The unit is staged and stays disabled. `host.yml` never enables or starts
`tether-agent.service`. It does install the app: a pinned, checksummed,
CI-built release of `Nishfleet/tether` (see "Tether release installs" below).
If someone starts the unit before `/opt/tether/current` exists,
`ConditionPathExists=/opt/tether/current/dist/index.js` turns that start into
a skip. The app is at a root-owned path on purpose: the service user can
write only `/var/lib/tether`, so it cannot rewrite its own code. `host.yml` also installs Node 22 LTS for the unit: the official linux-x64
tarball for one exact version (`tether_node_version`), checked against a sha256
pinned in `host.yml`, unpacked into the root-owned `/opt/node-v<version>`. The
unit's `ExecStart` names that `node` by absolute path. A new Node version is a
PR that changes the version, the hash and that path together. `host.yml` also
sets `/etc/tether/photon.env` (placed by hand, never created here) to
`root:tether 0640`, and the unit loads it after `tether.env`. A second
credentials file, `/etc/tether/calendar.env` (calendar and contacts), is handled
the same way: placed by hand, never created here, `root:tether 0640`, loaded
after `photon.env`. Internet egress for the service user is already open, so it
needed no firewall change.

tether has no route to the server's Cua daemon. A fixed loopback port with a
token was tried (#10102) and never worked: the daemon writes a new token to its
own `daemon.json` at every start and ignores `CUA_DAEMON_TOKEN` and
`--daemon-token`. It is retired: `host.yml` lists the drop-in directory
`/etc/systemd/user/cua-desk-daemon.service.d` in `retired` (so it is deleted and
nish's user manager reloaded), removes `/etc/fleet-ops/cua-daemon-token` and
nish's `fleet-ops/cua/daemon.env` by name, and then removes that last directory
only when it is empty. The daemon is restarted only by a newer Cua Spaces
release (the idle-desk check, restart and desk recreate above), never for a
config change. What tether can reach instead is its own Space, below.

`Restart=on-failure` brings a killed process back with the durable runtime's
last checkpoint, which is what the mid-reply proof in #9980 needs. The restart
is capped: `StartLimitBurst=5` in `StartLimitIntervalSec=3600`, so a fast crash
loop reaches it in about 25 seconds, and any loop that crashes at least every
12 minutes reaches it within the hour. A slower loop is bounded only by the
router key's budget (below). The unit is
then `failed`, and `OnFailure=fleet-unit-failed@%N.service` sends the
healthchecks.io fail ping, the same page the other units use. After fixing the
cause, run `systemctl reset-failed tether-agent.service` and start it.

Models go through the LiteLLM router at `127.0.0.1:4000`, never a direct
provider key. The unit allows `127.0.0.1/32` and `127.0.0.53/32` and denies
the rest of loopback. `IPAddressAllow=` takes no port, so the `inet tether`
nftables table matches the `tether` uid (numeric, so `deluser` cannot break the
file's load) and, for host-local destinations, allows only tcp `127.0.0.1:4000`
and tcp/udp `127.0.0.53:53`. It drops loopback, the server's own IPv4 and IPv6
addresses (from ansible facts, plus `fib daddr type local`), `172.16.0.0/12`,
`10.0.0.0/8`, `192.168.0.0/16`, IPv4 link-local, every docker or podman bridge
subnet present, the tailnet's CGNAT block and the tailnet, ULA and link-local
IPv6 ranges. Internet egress stays open. The table is its own
table, loaded by the host's `nftables.service` through
`include "/etc/nftables.d/*.nft"` in `rootfs/etc/nftables.conf`, so it never
touches the `filter` table or docker's rules and a boot re-applies it.

Web lookup (fleet-ops#9980, `Nishfleet/tether#7`): the app's nearby-places tool
calls exactly one public host, `photon.komoot.io` over https, read-only, with no
key. Because internet egress stays open for the `tether` uid, this needs no rule
or unit change: the table above only drops host-local destinations, and the
service user's own `IPAddressDeny=localhost` does not touch a public host. The
host is a constant in the app, the model never supplies a URL, and redirects are
refused, so a poisoned name cannot point the tool at the router port or the
tailnet. If egress is ever narrowed to named hosts, this host is the one to add
for the lookup.

LiteLLM virtual keys are minted by hand with the admin API (the RUNBOOK says
the proxy has no declarative key list), so no key is created here. After merge
the orchestrator mints one: `POST /key/generate` with `key_alias` `tether`,
`models` `["assistant"]`, `max_budget` 2, `budget_duration` `1d` and
`rpm_limit` 20. Port 4000 also serves `/jev` and `/metrics`, so after minting
check that this key is refused there. Its value goes only into `/etc/tether/tether.env`
(root:tether 0640), never into a repo.

Warning: `deluser` frees the service uid and `rm -rf` removes its memory and
credentials, and neither can be undone. Switch off, about two minutes, as root:

```
touch /etc/fleet-ops/tether-off    # lasting: the host-config run creates nothing for tether and keeps the unit disabled and stopped
systemctl disable --now tether-agent.service
deluser tether                     # optional: also drop the service user
rm -rf /var/lib/tether /etc/tether # removes its memory and its credentials, and cannot be undone
```

The marker `/etc/fleet-ops/tether-off` is what makes the off last. Without it
the on-merge and after-boot `fleet-host-config.service` run recreates the `tether`
user and `/etc/tether`. While the marker exists that run creates nothing for
tether, removes its firewall rule, and keeps the unit disabled and stopped.
Remove the marker to allow it again. To delete tether for good, open a PR that
removes `rootfs/etc/systemd/system/tether-agent.service` and the tether tasks
in `ansible/host.yml`, and adds the unit path to `retired`.

In-band, without root, Nish's own off-switch is the `STOP` text. The app that
handles `STOP` and `RESUME` lives in `Nishfleet/tether`, so that behaviour is
proved there, not by this repo.

### Tether's own Cua Space

tether can reach one Cua Space, `local:tether`, and nothing else on Cua. Its key
is that Space's own `cua-spacesd` token: it opens that Space's `spacesd` only
(checked: the same token against the desk Space's port answers
`unauthenticated`). It is not the server's Cua login. What the Space itself can
see, the Cua Volume included, follows Cua's own grants (`cua volume`), not this
repo.

`host.yml` does this as nish, like the other Cua tasks, unless the off marker
exists:

- creates the Space with `cua spaces create linux --name tether --on local`
  only when `cua sandbox ls --local` does not list it. An existing Space is
  never recreated, so its files and token stay;
- runs `cua spaces start local:tether` when it is stopped or suspended;
- reads the token from `/run/cua/env-token` in the Space (the documented
  `spacesd` location) and the address from `cua --embedded sandbox info`;
- renders `/etc/tether/cua.env` (`TETHER_SPACE_URL`, `TETHER_SPACE_TOKEN`,
  `root:tether 0640`, `no_log`, no diff), which the tether unit loads, and
  restarts tether when it changed;
- adds `ip daddr 127.0.0.1 tcp dport <port> accept` for that one port to
  `tether.nft.j2`, before the loopback drop. No other loopback port opens;
- reads the Space container's network, restart policy and privileged flag from
  Docker (`docker inspect` on the container id `cua sandbox info` reports). It
  must have restart policy `no`, not be privileged, and have one network, one
  IPv4 address and no IPv6 address, or the step fails and pages. It also reads
  the container's veth: the peer index of `eth0` in the container's network
  namespace (`nsenter`), and the host interface with that index. It then renders
  and loads `tether-space.nft` (the fence below) from the address and veth,
  before it reads the token and renders the env file. If the step fails before
  the fence is loaded, the rescue stops the Space (`cua spaces stop`, or `docker
  stop` when the Cua daemon is the failure), so it never runs unfenced; a failure
  after the fence is loaded leaves it running and fenced.

The Space is a Docker container on the default bridge, next to the desk Space
and the host. Cua has no network option for a local container (`--network none`
is for a QEMU VM only), so `tether-space.nft.j2` fences it, in its own file and
tables (`bridge tether_space`, `inet tether_space`), by its host-side veth and
also by its address. The veth is what a forged source address cannot change: the
bridge prerouting hook marks every frame that enters on it, and the IP hooks
drop on that mark as well as on the address. From the Space, nothing reaches the
host's own addresses (inet input), nothing is routed to 10/8, 127/8, 169.254/16,
172.16/12, 192.168/16 or 100.64/10 (inet forward; a host-local destination goes
to input, not forward), and every frame to another bridge port is dropped
(bridge forward, no connection tracking: the host loads no `br_netfilter`, so
bridged traffic skips both IP hooks). Replies to connections others open (the
published port, `sandbox exec`) pass; the internet stays open. The Space's DNS
servers are the host's public upstream resolvers, so no DNS exception is needed
(if they ever move into a private range, name lookups in the Space fail until an
exception is added). Checked on the box with a throwaway Space: before the fence
the desk Space's `:3211` answered from inside it, after it only the internet did.
Cua gives the Space `CapAdd SYS_ADMIN` and cannot drop `NET_RAW`; in a runsc
Space root still has neither `NET_RAW` nor `NET_ADMIN` (`ip addr add` and raw and
packet sockets fail with `Operation not permitted`), and the interface match
holds even if that changed.

The fence file is not part of tether's off marker: the marker removes
`tether.nft`, not `tether-space.nft`. A failed Space step leaves the last
rendered fence as it is (only tether's port allow goes). Docker's restart policy
for the Space is `no`, so after a reboot it stays stopped until the boot run
starts it, and the fence file loaded at boot holds its last address. If Docker
gives that address to another container first, that container's private
destinations are blocked, which is the safe direction; the boot run then
renders the Space's real address. A manual `docker restart` of the Space can
give it a new address and the fence follows on the next run.

The port is read live on each run because Docker publishes `spacesd` on a random
loopback port that changes whenever the container starts. A pause and resume
(`cua spaces stop` and `start`) keeps it. A container stop, which is what a
reboot does (Docker restart policy `no`), does not: after `docker stop` and
`cua spaces start` the port was new, the token was the same, and the Cua daemon
kept answering with the old port, so `cua sandbox info` and `cua sandbox exec`
without `--embedded` fail. `--embedded` reads Docker's live port. Because of
that, `fleet-host-config-boot.timer` runs `fleet-host-config.service` three
minutes after every boot (the daily timer's random delay of up to an hour is too
late): the run starts the Space, then renders the env file and the nft rule from
its new port and restarts tether. Until it does, tether's unit may start with the
last port, and its calls to the Space fail, because the old port is not allowed
any more. If the Space step fails (the Cua daemon is down after about 90 seconds
of waiting), the run completes everything else, keeps the old env file and the
last fence file, renders tether's nft rule without the Space port (it fails
closed: tether reaches no Space port until a run succeeds), and fails at its last
tether task, which pages.

Switch off: `touch /etc/fleet-ops/tether-off`. The next run skips the Space
tasks, removes `/etc/tether/cua.env` and tether's firewall rule (`tether.nft`),
stops the Space (`cua spaces stop local:tether`) and keeps tether stopped. The
fence file `tether-space.nft` stays, so a Space started by hand is still fenced.
The Space and its files are not deleted. To pause just the Space,
`cua spaces stop local:tether`; the next run starts it again unless the marker
exists.

Delete it: switch it off, then `cua spaces delete local:tether --force` as nish,
and `rm -f /etc/tether/cua.env` as root. Without the marker the next run creates
a new empty Space. To remove the feature for good, open a PR that deletes the
Space tasks, the env task, the nft line, `tether-space.nft.j2` and its file (add it
to `retired`), the `EnvironmentFile=` line and
`rootfs/etc/systemd/system/fleet-host-config-boot.timer` (add the timer to
`retired`).

### Tether release installs

`ansible/host.yml` holds the release in two vars, the only place they are
written: `tether_version` and `tether_sha256`. Unless
`/etc/fleet-ops/tether-off` exists, one `block:` does the following. The
directory and the cached file are named `<version>-<first 12 hex of the hash>`,
so a new hash at the same version is a new name and never reuses old content.

1. If `/opt/tether/<key>` is already whole (a real directory, a regular
   `dist/index.js`, nothing group- or other-writable or not owned by root,
   checked with the `find` module) the block only checks the link. A directory
   that fails that check is replaced, but only once its replacement is staged
   and checked, so a failed download never removes what `current` points at.
2. Otherwise it checks that nish's `gh` login works (`gh auth token` is not
   empty; the login is in `~/.config/gh/hosts.yml`, a file, so it also works
   under `become_user: nish`) and fails with "gh not authenticated for nish"
   when it is not.
3. `gh release download` of `tether-v<version>.tar.gz` from `Nishfleet/tether`
   as nish into `/var/cache/tether-releases/nish` (nish-writable, because `gh`
   cannot write into a root-owned directory; root reads only a plain file
   there, and a link is refused). The repo is private; the credential stays in
   `gh`'s own config and is never in a URL or in this repo.
4. `get_url` copies it to the root-owned
   `/var/cache/tether-releases/tether-v<key>.tar.gz` and checks it against
   `tether_sha256`. The unverified download is then removed.
5. `unarchive` unpacks into the root-owned staging directory
   `/opt/tether/.tmp-<key>` (tarball root: `dist/`, `package.json`,
   `package-lock.json`, `node_modules/`; no group or other write on any file).
   A task requires `dist/index.js` and no group- or other-writable or non-root
   file, then `mv -T` renames staging to `/opt/tether/<key>` (atomic, so a
   killed run leaves only a staging directory that the next run clears).
6. `/opt/tether/current` is pointed at `/opt/tether/<key>`.
7. When `current` moved, the release directories and cached tarballs other than
   the new one and the one `current` pointed at before are removed: one
   rollback step stays.

The unit runs `/opt/tether/current/dist/index.js`. It is still never enabled or
started by this run.

- **A failure does not stop the host config.** Any failure in the block (no
  GitHub login, no release asset, a checksum mismatch, a bad layout) goes to
  its `rescue:`: `current` is left where it was and the failure is recorded.
  Every other task runs and pending handlers are flushed. The last task of the
  play then fails the run with that message, so the deploy is red and pages.
- **Upgrade:** build and publish the new release in `Nishfleet/tether`, then open
  one PR that changes `tether_version` and `tether_sha256` in `ansible/host.yml`.
  After the merge the next host-config run installs it beside the old one and
  moves `current`. Restart the unit by hand to run it.
- **Rollback:** revert that PR. The previous release directory is still in
  `/opt/tether`, so the next run points `current` back at it.
- **Hash mismatch:** the verify task fails, nothing is unpacked and `current`
  stays. Check the pinned hash against the release's `.sha256` asset. The next
  run downloads `tether-v<version>.tar.gz` again; nothing needs deleting by hand.
- **No GitHub login:** run `gh auth login` as nish. A version that is already
  installed needs no download and no login.

