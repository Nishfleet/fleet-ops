# Runbook

One page. How to run the fleet. What it is, install mechanics and the deploy
rail are in `README.md`; design and enforced rules are in
`docs/ARCHITECTURE.md`.

## Live-state check (the canonical order)

1. `ls ~/workspaces/agent-state/FLEET-PAUSED` — if it exists the fleet is
   deliberately down; respect it. Otherwise step 2 is the truth.
2. `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers`.
3. Same prefix, `systemctl --user list-units --state=failed` — must be empty.
4. `curl -s 127.0.0.1:4000/health/readiness` (expect
   `{"status":"healthy","db":"connected"}`), then
   `curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state` — one
   gauge per deployment (0 healthy, 1 partial, 2 outage).
5. `uptime` for load; merged-PR counts per repo for throughput.

## Deploy and wiring

`deploy-box.yml` (push to main) → `fleet-sync.service` runs
a `git fetch` of `main` into `refs/remotes/origin/main` + a
`git merge --ff-only` of that named ref + `daemon-reload`, and fails
(`DEPLOY-BLOCKED`) on a dirty
or diverged clone, so the canonical checkout
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone` stays clean on `main`.
It never uses `git pull`: a polluted `FETCH_HEAD` there merges into
`fatal: Cannot fast-forward to multiple branches` and silently stops every
deploy (fleet-ops#8893). A trailing `merge-base --is-ancestor` pair
asserts `HEAD == origin/main`, so a stopped deploy is a failed unit rather
than a lagging clone.
Its LINK-GUARD passes fail the unit while any live symlink under
`~/.config/systemd/user/`, `~/.local/bin/`, `~/.pi/agent/` or the vault is
broken or resolves into a throwaway root (`*worktrees/*`, `agent-state`,
`tmp`).

`~/.pi/agent/agents/` holds only the stock agents from `template/agents/`;
per-issue copies (`reviewer-issue-<N>.md`, removed under fleet-ops#8659) are
loaded by nothing.

Wiring a new unit or prompt is one `ln -sfn` into the deploy clone, once
(full commands in README). Two root-owned copies are `fleet-sync.service`'s
job instead of the hand copy: `/etc/prometheus/prometheus.yml` (check config +
copy + reload) and `/etc/systemd/system/agent.slice` (install -C + the system
`daemon-reload`, which re-applies a changed cap to the running slice —
fleet-ops#8862). Everything else that stays a copy — the two Pi extension
forks, the live-state JSON files under `~/.local/state/`, the
`~/.config/fleet-ops`-owned files and the other `/etc/**` paths — is still
refreshed by hand.

After a slice change, both the unit and the cgroup must read the new cap:
`systemctl show agent.slice -p MemorySwapMax` and
`cat /sys/fs/cgroup/agent.slice/memory.swap.max` (1073741824, not infinity).

## LiteLLM stack (rebuild reference)

Fleet-owned Postgres and Redis as user daemons — the distro packages are
stopped/disabled, they are never the fleet's. Cluster at
`~/.local/share/fleet-litellm-postgres` (loopback 127.0.0.1:5432 only, trust
auth, user-owned), Redis at `~/.local/share/fleet-litellm-redis`
(`bind 127.0.0.1`, maxmemory 128mb). `pg_isready` against the socket dir
before enabling the units; a correct deployment shows `active (running)`,
not `active (exited)`.

The proxy runs from `~/.local/venvs/litellm` on a pinned version. **Required
patch after every install or upgrade:** `patch -d
~/.local/venvs/litellm/lib/python3.12/site-packages -p1 <
/home/nish/workspaces/tooling/fleet-ops-deploy-clone/patches/litellm-1.98.0-gchunk-usage-union.patch`
— a plain `pip install` reverts it silently. On a version bump, first check
whether upstream fixed the line; if so drop the patch and this step.

The live config `~/.config/fleet-ops/litellm-proxy.yaml` is a copy of
`config/litellm-proxy.yaml`: `fleet-sync.service` installs it with `install -C`,
which overwrites a hand edit, and `fleet-litellm-proxy-config.path` restarts the
proxy only when the bytes change. Edit the repo file and nothing else; CI checks
it against `config/litellm-proxy.schema.json` (fleet-ops#8724). Keys resolve as `os.environ/<NAME>` from the seat env
files the unit globs (`~/.config/fleet-ops/seats/*.env`), the master key the
same way. The container receives only the names listed on the `Environment=` line of
`fleet-litellm-proxy.container` (fleet-ops#9020), so a new `os.environ/<NAME>` in the yaml needs its
name added there; `disable_prisma_schema_update: true` stays under `general_settings`
(startup `prisma migrate deploy` stalls every restart without it), and
`DATABASE_URL` is a unit `Environment=` in host-qualified form (the
socket-less form is rejected). Consumer credentials are per-group virtual keys
minted via the admin API, never the master key. An admin-API call keeps the
key out of argv — `curl -H "Authorization: Bearer $KEY"` leaves the key in
`/proc/<pid>/cmdline` for the life of the curl (fleet-ops#8403) — by handing
curl a config fd:
`curl --config <(sed -n 's|^LITELLM_MASTER_KEY=\(.*\)|header = "Authorization: Bearer \1"|p' ~/.config/fleet-ops/litellm-master-key.env)`.
`sed` rewrites the line into a header; the key never becomes an argument.
`-H @<0600 headers file>` works too. Do not `printf`/`echo` a `$..._KEY`
into the config instead: `printf` plus a key variable is what CI's
secret-scan gate blocks, and the gate is right — the printf form puts the key
back in argv.

Edits to that file are applied automatically. `fleet-litellm-proxy-config.path`
(`PathChanged=`) triggers `fleet-litellm-proxy-config.service`, which runs
`systemctl --user try-restart fleet-litellm-proxy.service` — the proxy reads
its config only at start, so the restart is the apply step, and `try-restart`
means an edit never starts a proxy that was stopped on purpose. Every save
restarts the proxy (~38 s), so batch edits into one write. Install it with
`systemctl --user link` on the .service, then `systemctl --user enable --now`
on the .path, both from the deploy clone (README "Install").

Backup: `pg_dump -h "$HOME/.local/share/fleet-litellm-postgres/run" -U
litellm litellm | gzip > .../litellm-<ts>.sql.gz` in the restic backup path.
Rollback: stop + disable the three units, drop the fleet-owned cluster and
`rm -rf` its two data dirs (no sudo needed — they are user-owned).

## Break-glass access (SSH is Tailscale-only)

If tailscaled is down, SSH is gone. The out-of-band layer exists today at zero
cost: the netcup provider VNC console.

- Use it when tailscaled will not return (`Restart=always` already applied),
  when the Tailscale interface is absent, or to confirm sshd still binds only
  Tailscale addresses. Never for routine work.
- Steps: netcup panel from a machine that does not depend on this VPS → VNC
  console → login as `nish` → `systemctl restart tailscaled` → `ss -ltn |
  grep ':22'` must show only `100.*`/`fd7a:*` — a `0.0.0.0:22` or `[::]:22`
  line is a public SSH bind, fix it before disconnecting → verify Tailscale
  SSH from another machine, then leave VNC.
- It is not a second SSH listener, not a standing open console, and not a
  live-tailscaled kill (a lockout, not an experiment — that stays a Nish
  game-day). Panel login lives in Nish's password manager; never here.
