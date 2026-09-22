# CONTAINER-WORKER — one container per fleet worker, stock podman only

Nish, 2026-09-22 10:45 IST: a container per fleet worker, *"if it's not glue or
handrolled bs, I'm cool"*. Umbrella: [#7828](https://github.com/Nishfleet/fleet-ops/issues/7828).

Same test as [GLUE-ZERO.md](GLUE-ZERO.md): **is this what ships in the box?**
Every piece below is an image, a unit key, an nftables statement or a prompt
line. Nothing in this design is a script, a wrapper, a hook or an extension.
Every claim is probed on netcup-rs2000 and the command and output are pasted.

## Gate: does rootless podman get a user namespace on this host?

This was the stop condition. `kernel.apparmor_restrict_unprivileged_userns=1`
blocks unprivileged `unshare(CLONE_NEWUSER)`, and Ubuntu 24.04 exempts podman
through `/etc/apparmor.d/podman`. Probed 2026-09-22, as user `nish`:

```
$ sudo -n apt-get install -y podman     # podman 4.9.3, buildah 1.33.7

$ sysctl kernel.apparmor_restrict_unprivileged_userns
kernel.apparmor_restrict_unprivileged_userns = 1

$ grep nish /etc/subuid /etc/subgid
/etc/subuid:nish:100000:65536
/etc/subgid:nish:100000:65536

$ podman unshare cat /proc/self/uid_map
         0       1000          1
         1     100000      65536

$ podman run --rm docker.io/library/alpine:3.20 id
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),...

$ podman info --format '{{.Store.GraphDriverName}} {{.Host.Security.Rootless}}'
overlay true
```

**Verdict: PASS.** Container root is host uid 1000 (`nish`), and the container
owns 65,536 subordinate ids it did not have before. The apparmor restriction
does not apply to podman on this host. Rootful docker is not used and is not a
fallback: it has a root daemon and no user namespace.

## Design-it-twice

### Candidate A — one Quadlet `.container` template per worker

`~/.config/containers/systemd/pi-issue@.container`. Podman ships Quadlet as a
systemd **generator** (`/usr/lib/systemd/user-generators/podman-user-generator
-> /usr/libexec/podman/quadlet`, installed by the `podman` package). A
`systemctl --user daemon-reload` turns the `.container` file into a `.service`
unit. Nothing of ours generates anything.

Template units are undocumented in podman 4.9's man page, so they were probed
rather than assumed:

```
$ cat ~/.config/containers/systemd/qtest@.container
[Container]
Image=docker.io/library/alpine:3.20
Exec=echo hello-%i

$ systemctl --user daemon-reload && ls /run/user/1000/systemd/generator/qtest@.service
/run/user/1000/systemd/generator/qtest@.service
```

They work. One trap: the default container name is `systemd-%N`, which contains
`@` and podman rejects it — `names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*`. One
`ContainerName=` line fixes it; it is in the unit below.

### Candidate B — Pi's documented Docker Sandboxes (`sbx`) pattern

`docs/containerization.md` in the installed Pi package lists four patterns and
the strongest is Docker Sandboxes: `sbx run --kit "docker.io/sbx/pi-kit:latest"
pi`. Its one real advantage over A is credential handling — the sandbox gets a
**sentinel** value and the `sbx` proxy substitutes the real credential on egress
to the provider host, so the model key never enters the container.

**Rejected, for four reasons, in order of weight:**

1. **It needs Docker.** `sbx` is a Docker Desktop / Docker Engine feature. This
   host has rootful docker 29.1.3 and that is precisely the thing being replaced
   — a root daemon with no user namespace. Adopting B means keeping rootful
   docker forever.
2. **It is not a systemd unit.** Every worker on this host is a `systemd --user`
   unit, and the fleet's singleflight, memory caps, `Restart=`, `RuntimeMaxSec=`
   and failure visibility (`list-units --state=failed`) are all unit properties.
   B would put the worker's lifetime inside a `sbx` process, so all of that
   would have to be rebuilt — the definition of glue.
3. **Its credential advantage does not apply here.** The proxy substitutes on
   egress *to a named provider host*. Fleet workers reach the model through
   LiteLLM on **host loopback**, so there is no egress to intercept; and the
   fleet's threat model (CLAUDE.md, "full credential parity") is not "keep the
   key from the agent", it is "keep the agent off the host filesystem".
4. `sbx` is a third runtime to install, learn and pin, next to podman, which is
   already in Ubuntu's archive and already integrates with systemd.

**Grafted from B:** its insight that the *workspace* should be the container's
own clone rather than a host worktree. B mounts the cwd and nothing else; A
copies that exactly — see "the worktree is the only writable bind" below. This
is what removes the deploy clone from the container entirely.

**Winner: A.**

## The design

### 1. The image — one Containerfile, three vendor installers

A Containerfile is config: declarative, no control flow, no functions.
`localhost/fleet-worker:0.85.1` — the tag is the pinned Pi version.

```dockerfile
# containers/Containerfile
FROM docker.io/library/node:22-bookworm

ARG PI_VERSION=0.85.1
ARG GH_VERSION=2.93.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ripgrep jq less ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/gh.tgz \
 && tar -xzf /tmp/gh.tgz -C /usr/local --strip-components=1 \
      "gh_${GH_VERSION}_linux_amd64/bin/gh" \
 && rm -f /tmp/gh.tgz

RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

ENV HOME=/home/nish
WORKDIR /home/nish
```

Built and proven in the run below:

```
$ podman build -t localhost/fleet-worker:0.85.1 -f Containerfile .
$ # from inside the container:
0.85.1
gh version 2.93.0 (2026-05-27)
git version 2.39.5
```

**Rejected: binding `~/.local/lib/node_modules/@earendil-works` read-only
instead of installing Pi in the image.** It works for Pi, but `gh`, `git`,
`node` and `rg` would each need their own bind, the host's `node` ABI would have
to match the image's, and a host `npm i -g` would silently change what every
running worker executes. A pinned tag is one value to read and one value to
bump.

### 2. The unit — `systemd/pi-issue@.container`

The Quadlet file **keeps the name `pi-issue@`**, so the generated unit is
`pi-issue@%i.service` — the same name intake, the alert rules, the prompts and
`ExecStopPost` refills already use. Nothing downstream is renamed and no thin
shim unit is needed; the cutover is "delete `systemd/pi-issue@.service`, add
`systemd/pi-issue@.container`". `~/.config/systemd/user/` beats the generator
directory, so the old unit file must be removed, not just superseded.

```ini
# systemd/pi-issue@.container  ->  ~/.config/containers/systemd/pi-issue@.container
[Unit]
Description=Containerized fleet worker %i
StartLimitIntervalSec=1h
StartLimitBurst=3
Requires=fleet-gh-token.service
After=fleet-gh-token.service

[Container]
ContainerName=fleet-worker-%i
Image=localhost/fleet-worker:0.85.1
Pull=never

# privilege
NoNewPrivileges=yes
DropCapability=ALL
PidsLimit=512

# filesystem — the issue worktree is the ONLY writable host bind
ReadOnly=yes
ReadOnlyTmpfs=yes
Volume=%h/workspaces/agent-worktrees/issue-%i:/home/nish/workspaces/agent-worktrees/issue-%i:rw
Volume=%h/workspaces/.mirrors:/home/nish/workspaces/.mirrors:ro
Volume=%h/.pi/agent:/home/nish/.pi/agent:O
Volume=%h/.pi/agent/sessions/pi-issue-%i:/home/nish/.pi/agent/sessions/pi-issue-%i:rw
Volume=%h/workspaces/tooling/fleet-ops-deploy-clone/AGENTS.md:/home/nish/workspaces/tooling/fleet-ops-deploy-clone/AGENTS.md:ro
Volume=%h/workspaces/tooling/fleet-ops-deploy-clone/prompts/worker.md:/home/nish/prompt.md:ro
Tmpfs=/home/nish/.cache
WorkingDir=/home/nish/workspaces/agent-worktrees/issue-%i

# network — host loopback only; the ACL is the nftables stanza below
Network=slirp4netns:allow_host_loopback=true,enable_ipv6=false
DNS=10.0.2.3
PodmanArgs=--add-host=litellm.fleet.local:10.0.2.2

# credentials — env files, never mounts
EnvironmentFile=/run/user/%U/fleet-gh-token.env
EnvironmentFile=%h/.config/fleet-ops/litellm-master-key.env
Environment=HOME=/home/nish
Environment=GH_CONFIG_DIR=/tmp/gh
Environment=XDG_CACHE_HOME=/home/nish/.cache
Environment=FLEET_INSTANCE=%i
Environment=PI_SEAT_PROVIDER=litellm
Environment=PI_SEAT_MODEL=worker-capable
# git over https authenticates with GH_TOKEN through gh, with no writable
# ~/.gitconfig. See "what the proof run found", item 1.
Environment=GIT_CONFIG_COUNT=1
Environment=GIT_CONFIG_KEY_0=credential.https://github.com.helper
Environment=GIT_CONFIG_VALUE_0=!gh auth git-credential
Environment=GIT_AUTHOR_NAME=nishfleet-worker[bot]
Environment=GIT_AUTHOR_EMAIL=321485391+nishfleet-worker[bot]@users.noreply.github.com
Environment=GIT_COMMITTER_NAME=nishfleet-worker[bot]
Environment=GIT_COMMITTER_EMAIL=321485391+nishfleet-worker[bot]@users.noreply.github.com

Exec=/bin/sh -c 'echo "/worker $${FLEET_INSTANCE##*-}" | exec pi --print --append-system-prompt /home/nish/workspaces/tooling/fleet-ops-deploy-clone/AGENTS.md --session-dir /home/nish/.pi/agent/sessions/pi-issue-$$FLEET_INSTANCE --exclude-tools subagent --provider $$PI_SEAT_PROVIDER --model $$PI_SEAT_MODEL'

[Service]
Slice=fleet-container.slice
MemoryAccounting=yes
MemoryHigh=3G
MemoryMax=6G
MemorySwapMax=0
CPUAccounting=yes
CPUQuota=25%
TimeoutStartSec=45min
RuntimeMaxSec=50min
Restart=on-failure
RestartSec=240
```

Notes that are load-bearing, not tidying:

- **Quadlet copies `[Unit]`, `[Service]` and `[Install]` through verbatim.** So
  the whole existing `pi-issue@.service` body — the claim gate `ExecStartPre=`,
  the two `ExecStopPost=` lines, the artifact check, `Restart=`,
  `StartLimitBurst=` — moves into `[Service]` unchanged. The container does not
  cost the fleet a single existing control.
- **`$$` is mandatory in `Exec=`.** systemd expands `$VAR` and `${VAR}` in an
  `Exec` line *before* `sh` sees it, and `FLEET_INSTANCE` is passed to the
  container with `--env`, not into the unit's own environment — so a single `$`
  expands to empty. This is the #8204 class and `ci.yml`'s `no-glue` job
  already greps for it.
- **`MemoryMax=` on the unit really caps the container.** Quadlet emits
  `--cgroups=split` and `Delegate=yes`, so the container's processes live in the
  unit's cgroup. Measured on the proof run: `MemoryPeak=193511424` (185 MiB).
- **`Volume=...:O` on `~/.pi/agent` is not a typo.** `:O` is podman's *overlay*
  mount: the host directory is a read-only lower layer and container writes go
  to an upper layer discarded at exit. It is required — Pi 0.85.1 takes lock
  directories beside its own config files, and a plain `:ro` bind fails the run
  outright (this was found, not assumed):
  ```
  Warning: Invalid settings file /home/nish/.pi/agent/settings.json: EROFS: read-only file system, mkdir '.../settings.json.lock'
  Credential store read failed for litellm: EROFS: read-only file system, mkdir '.../auth.json.lock'
  ```
  The session directory is bound `rw` *after* the overlay (longer path wins), so
  the session record still lands on the host for forensics.
- **`ContainerName=` is required** for template units; see Candidate A.

### 3. The slice — `systemd/fleet-container.slice`

```ini
[Unit]
Description=All containerized fleet workers
[Slice]
MemoryAccounting=yes
MemoryMax=24G
```

Its only other job is to be a stable cgroup path for the firewall rule. systemd
derives the parent from the name, so the live path is
`user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice`
with no `fleet.slice` file needed.

### 4. The network boundary — two layers, and what each one really buys

**Layer 1 — `Network=slirp4netns:allow_host_loopback=true,enable_ipv6=false`.**
Rootless podman has no route to the host's network namespace at all unless this
is set; with it, the host is reachable at exactly one address, `10.0.2.2`, which
slirp maps to host `127.0.0.1`. So the container's entire view of this VPS is
its loopback. `10.0.2.3` is slirp's own resolver and is what `DNS=` points at —
with the default resolv.conf the container also inherits netcup's external
nameservers, which layer 2 then blocks, breaking DNS; one `DNS=` line avoids
that.

`--add-host=litellm.fleet.local:10.0.2.2` exists because `~/.pi/agent/models.json`
holds a literal `http://127.0.0.1:4000`, which means the container itself inside
a netns. **One value changes**: that `baseUrl` becomes
`http://litellm.fleet.local:4000`, and the host gets one `/etc/hosts` line
(`127.0.0.1 litellm.fleet.local`) so the same file keeps working for host-side
Pi. One file, one name, both sides.

**Layer 2 — the egress ACL, in nftables, matched on the slice's cgroup.**
Podman has no destination ACL: `podman run --help` offers `--network`, `--dns`,
`--add-host` and nothing that filters by destination, and neither slirp4netns
nor pasta has an ACL option (`man podman-run`, the `slirp4netns[:OPTIONS]`
list — `allow_host_loopback`, `mtu`, `cidr`, `enable_ipv6`, `outbound_addr`,
`port_handler`, and that is all). So the filter is the host's own firewall.

The fact that makes this work: a rootless container's outbound packets are
emitted by its `slirp4netns` process, **in the worker unit's cgroup**, which
nftables can match directly:

```
$ cat /proc/$(pgrep -u nish slirp4netns)/cgroup
0::/user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice/cgprobe.service
```

```nft
# /etc/nftables.conf  — independent of the `ip filter` table ufw manages
table inet fleetworker {
  set gh_v4 {
    type ipv4_addr
    flags interval
    # github.com/meta -> .web + .api + .git, IPv4 only (78 CIDRs, 2026-09-22)
    elements = { 192.30.252.0/22, 185.199.108.0/22, 140.82.112.0/20,
                 143.55.64.0/20, 20.201.28.151/32, ... }
  }
  chain output {
    type filter hook output priority filter; policy accept;
    socket cgroupv2 level 5 "user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice" ip daddr 127.0.0.0/8 accept
    socket cgroupv2 level 5 "user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice" ip daddr @gh_v4 accept
    socket cgroupv2 level 5 "user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice" ip daddr 10.0.2.0/24 accept
    socket cgroupv2 level 5 "user.slice/user-1000.slice/user@1000.service/fleet.slice/fleet-container.slice" counter reject
  }
}
```

The rule matches **only** the worker slice, so nothing else on this host —
including `nish`'s own shell — changes behaviour. Proven from inside a container
in that slice, with the counter afterwards:

```
$ # inside the container, same flags as the unit
https://example.com        curl: (28) Connection timed out after 6001 milliseconds http=000
https://api.github.com     http=200
https://github.com         http=200
http://litellm.fleet.local:4000 {"status":"healthy","db":"connected"}

$ sudo nft list table inet fleetworker | grep counter
... socket cgroupv2 level 5 "user.slice/.../fleet-container.slice" counter packets 8 bytes 468 reject
```

**Named losses, so nobody discovers them later:**

- **The CIDR set is hand-maintained config.** GitHub publishes the ranges at
  `api.github.com/meta`; a fetch-and-write organ would be glue, so the set is
  reviewed like any other config value. A stale range fails loud (the worker
  cannot reach GitHub and the unit fails), never silently.
- **IPv6 is not filtered; it is turned off** (`enable_ipv6=false`), which is
  stronger and simpler than a parallel v6 set.
- **This ACL is only cheap because the model comes through LiteLLM.** A
  direct-provider seat (`xai-oauth` on `cli-chat-proxy.grok.com`, cursor on
  `api2.cursor.sh`, devin on `api.devin.ai`) sits behind a CDN whose ranges are
  most of Cloudflare — allowing them would gut the ACL. **Containerized workers
  route models through LiteLLM only.** That is a real constraint on the seat
  roster, not a detail; today's `pi-issue@` seat is `xai-oauth grok-4.7:xhigh`
  and containerizing it means either moving that seat behind LiteLLM or
  accepting a much wider allowlist.
- The rule lives in `/etc/nftables.conf` and needs `nftables.service` enabled
  (`systemctl is-enabled nftables.service` -> `disabled` today) to survive a
  reboot. That is one `systemctl enable`, and it is a packet step, not done here.

### 5. The prompt change — the worktree becomes a clone

Today `prompts/worker.md:16` tells the worker to run
`git -C /home/nish/workspaces/tooling/fleet-ops-deploy-clone worktree add ...`.
That cannot work in a container and **should not**: a git worktree writes into
the parent repo's `.git/worktrees/`, so honouring it would mean mounting the
deploy clone writable — exactly the blast radius the container exists to remove.

The replacement is one prompt line:

```
Clone into the current directory:
  git clone --reference-if-able /home/nish/workspaces/.mirrors/<repo>.git \
    https://github.com/Nishfleet/<repo>.git .
```

The mirror is bound read-only for speed and is optional. This also deletes the
`git worktree remove` loop from `ExecStopPost=` — there is no worktree to
remove, only a directory.

### 6. What changes in `devin-issue@` and `cursor-issue@` — not yet, and why

Both are the same shape (`Type=oneshot`, App token, worktree, a vendor CLI
instead of `pi`), so mechanically they become `devin-issue@.container` and
`cursor-issue@.container` with `cursor-agent` / `devin` added to the image by
their vendor installers. Two things block it, and neither is cosmetic:

1. **The egress ACL would have to open `api2.cursor.sh` and `api.devin.ai`**,
   both CDN-fronted. See the named loss above. Containerizing these lanes with
   the ACL wide open buys the filesystem boundary and throws the network one
   away; that trade needs to be made deliberately, not by copy-paste.
2. **Neither vendor CLI is version-pinnable the way `pi` is.** `npm i -g
   @earendil-works/pi-coding-agent@0.85.1` is reproducible; `cursor-agent` and
   `devin` install from vendor endpoints that serve "latest", so the image tag
   would lie about what is inside it.

So: the Pi lane containerizes now; the vendor lanes get their own issue, after
the Pi lane has run a full day. Stated plainly rather than left implied.

## What the proof run found (three real defects, all fixed in the unit above)

1. **`GH_TOKEN` in the environment does not authenticate `git push`.** `gh`
   reads it; `git` does not. On the host this is invisible because
   `~/.gitconfig` already carries the helper. In the container the worker hit
   `fatal: could not read Username for 'https://github.com'`, then
   `gh auth setup-git` failed with `could not lock config file
   /home/nish/.gitconfig: Read-only file system`, and it recovered with a
   repo-local helper. The unit fix is three `Environment=` lines
   (`GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0`) — stock git, no file, no script.
2. **`~/.pi/agent` cannot be a `:ro` bind.** See `:O` above.
3. **A `Tmpfs=/home/nish/.config` silently defeats the boundary.** With it,
   `touch /home/nish/.config/x` *succeeds* (in a container-local tmpfs). It was
   removed; `GH_CONFIG_DIR=/tmp/gh` covers the only thing that wanted to write
   there.

## Proof: one real worker run, end to end, inside the container

Issue [#8245](https://github.com/Nishfleet/fleet-ops/issues/8245) on
Nishfleet/fleet-ops, claim branch `claim/issue-8245` created from `main`. The
live `pi-issue@`, `devin-issue@` and `cursor-issue@` units were **not touched**;
the run used a separate Quadlet file, `fleet-worker-proof@.container`, identical
to the unit above except for its name and the two scratch binds.

### Boundary checks, from inside the container, same flags

```
id: uid=0(root) gid=0(root) groups=0(root)
--- (1) writes
touch: cannot touch '/home/nish/workspaces/tooling/fleet-ops-deploy-clone/x': Read-only file system
touch: cannot touch '/home/nish/.config/x': No such file or directory
touch: cannot touch '/home/nish/.pi/agent/x': Read-only file system
  worktree touch: OK
--- (2) egress
  https://example.com      curl: (28) Connection timed out after 6001 milliseconds http=000
  https://api.github.com   http=200
  https://github.com       http=200
  http://litellm.fleet.local:4000 {"status":"healthy","db":"connected"}
--- (3) tools
0.85.1
gh version 2.93.0 (2026-05-27)
git version 2.39.5
```

### The worker run

```
$ systemctl --user start --no-block fleet-worker-proof@fleet-ops-8245.service

$ podman ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
fleet-worker-proof-fleet-ops-8245	localhost/fleet-worker:0.85.1	Up 24 seconds

$ journalctl --user -u fleet-worker-proof@fleet-ops-8245.service
10:57:27 Starting fleet-worker-proof@fleet-ops-8245.service - Containerized fleet worker (proof) fleet-ops-8245...
10:57:28 Started fleet-worker-proof@fleet-ops-8245.service
10:57:28 d369d2a3fbb40528de606e8c9e888efdc6c44651511af8465b51cfe85dfe026d
10:58:53 - Cloned into the worktree, checked out `claim/issue-8245`.
10:58:53 - Committed with `docs: container-worker proof outputs (#8245)`, added by pathspec only, and pushed.
10:58:53 - Opened PR #8250 against main with the exact specified title/body
10:58:53 PR: https://github.com/Nishfleet/fleet-ops/pull/8250

$ systemctl --user show fleet-worker-proof@fleet-ops-8245.service -p Result,ExecMainStatus,MemoryPeak,Slice
Result=success
ExecMainStatus=0
MemoryPeak=193511424
Slice=fleet-container.slice

$ gh pr view 8250 -R Nishfleet/fleet-ops --json number,url,state,author,headRefName,files
{"author":"app/nishfleet-worker","files":["docs/container-worker-proof.md"],
 "head":"claim/issue-8245","number":8250,"state":"OPEN",
 "url":"https://github.com/Nishfleet/fleet-ops/pull/8250"}

$ gh api repos/Nishfleet/fleet-ops/commits/24011cf3 --jq '{sha,author:.commit.author.name}'
{"sha":"24011cf3","author":"nishfleet-worker[bot]"}
```

Claim, clone, edit, commit by pathspec, push, PR — all inside the container,
under the App identity, with the deploy clone and `~/.config` unreachable and
`example.com` blocked.

### Exit codes propagate, so every existing failure control still works

`Restart=on-failure`, `StartLimitBurst=` and the artifact gate all key off the
unit's result, so this was probed rather than assumed:

```
$ # a Quadlet unit whose container exits %i
exit 0 -> success 0 inactive
exit 7 -> exit-code 7 failed
```

## Sequence

A deletion is `agent-blocked` until its replacement has run once for real.

| order | issue | scope | label |
|---|---|---|---|
| K1 | image | add `containers/Containerfile`; build `localhost/fleet-worker:0.85.1`. **Proof: `pi --version`, `gh --version`, `git --version` from inside.** | `agent-ready` |
| K2 | slice + firewall | add `systemd/fleet-container.slice`; add the `inet fleetworker` table to `/etc/nftables.conf`; `systemctl enable nftables.service`. **Proof: the four-line curl matrix + a non-zero reject counter.** | `agent-ready` |
| K3 | one router name | `models.json` `baseUrl` -> `http://litellm.fleet.local:4000`; one `/etc/hosts` line. **Proof: one host-side `pi --print` tool call still routes.** | `agent-ready` |
| K4 | prompt | `prompts/worker.md` step 3: clone, not `worktree add`. | `agent-blocked` on K1 |
| K5 | the unit | add `systemd/pi-issue@.container`; delete `systemd/pi-issue@.service` and the live `~/.config/systemd/user/` copy. **Proof: one real `agent-ready` issue worked to a merged PR.** | `agent-blocked` on K1–K4 |
| K6 | vendor lanes | `devin-issue@` / `cursor-issue@`, only after the ACL trade above is decided. | `agent-blocked` on K5 |

```
K1  K2  K3          (parallel, no blockers)
 |       |
 K4 -----+--> K5 --> K6
```

## What Nish decides

1. **The seat.** Containerized workers route models through LiteLLM only (see
   the named loss in §4). Today's `pi-issue@` seat is `xai-oauth
   grok-4.7:xhigh`, direct. Either that seat moves behind LiteLLM, or K5 lands
   with a wider egress allowlist. This is the one choice the design cannot make
   for itself.
2. **The vendor lanes** (§6) — containerize with a wide-open ACL, or leave
   `devin-issue@` / `cursor-issue@` on the host until their upstreams can be
   enumerated.
