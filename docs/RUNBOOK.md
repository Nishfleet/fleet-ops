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
(full commands in README). Every root-owned file under `/etc` that the repo
ships lives in `rootfs/` and is `fleet-host-config.service`'s job (Ansible's
`ansible-pull` of `ansible/host.yml`, started by deploy-box.yml on every merge
and by a daily timer). Its `daemon-reload` re-applies a changed slice cap to
the running slice (fleet-ops#8862). A failed run is in
`journalctl -u fleet-host-config.service`; a `Hand-installed` line names a file
to add under `rootfs/`, delete, or list in `/etc/fleet-ops/box-only`. What still
stays a hand copy: the two Pi extension forks, the live-state JSON files under
`~/.local/state/` and the `~/.config/fleet-ops`-owned files.

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
same way. The container receives only the names that have a `PodmanArgs=--env=<NAME>` line in
`fleet-litellm-proxy.container` (fleet-ops#9020), so a new `os.environ/<NAME>` in the yaml needs a
matching `PodmanArgs=--env=<NAME>` line; `disable_prisma_schema_update: true` stays under `general_settings`
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

## Claude session credentials (fleet-ops#9020)

The systemd `--user` manager environment carries no Claude, Exa or Browser Use
names. The manager hands its environment to every user unit, every
`systemd-run --user` transient and every quadlet container, so the names were
removed from it in this order:

1. Delete `~/.config/environment.d/50-agent-secrets.conf`.
2. `systemctl --user daemon-reload`. The manager reads `environment.d` through
   its generator at startup and on reload, so without this the three names the
   file defined stay in the manager environment: `unset-environment` alone did
   not clear them.
3. `systemctl --user unset-environment <NAME>...` for any name that is still
   listed, `ANTHROPIC_BASE_URL` included.
4. Check names only, never values:
   `systemctl --user show-environment | cut -d= -f1 | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|EXA_API_KEY|BROWSER_USE_API_KEY|ANTHROPIC_BASE_URL)$'`
   must print nothing (`grep` exits 1).

A launcher that needs them reads one file, `~/.config/claude/oauth.env`, mode
0600 (`install -m 0600`, owner `nish`), holding `NAME=value` lines for exactly
these names: `CLAUDE_CODE_OAUTH_TOKEN`, `EXA_API_KEY`, `BROWSER_USE_API_KEY`.
`ANTHROPIC_BASE_URL` is not stored: nothing in the fleet needs it. Never
tracked, never printed; check it with `test -s` and `stat -c %a`.

Loading it is the stock property, required (no `-` prefix) so a missing file
fails the unit at start instead of running a session on the wrong login:

```
systemd-run --user --collect --unit <name> -p EnvironmentFile=%h/.config/claude/oauth.env \
  -- claude -p ...
```

The same line in a user unit is `EnvironmentFile=%h/.config/claude/oauth.env`.
It is deliberately not among the optional (`-`) seat globs the proxy reads: a
seat file may be absent, this one may not. In a system unit `%h` is the home of
the user running the manager, `/root` (`man systemd.unit`, Specifiers), not
`User=`, so a system unit with `User=nish` writes
`EnvironmentFile=/home/nish/.config/claude/oauth.env`.
`EnvironmentFile=` loads the whole file: a unit that must not hold all three
names gets its own file per need (`claude-token.env`, `exa.env`, ...), never
the shared one.

Readers in this repo: none (re-audited for every unit, drop-in, quadlet,
workflow, prompt and recipe that starts `claude`, `pi`, `devin`, `opencode`,
`cursor-agent` or a fleet worker):

- `claude-remote-control.service` is a system unit. A system manager never saw
  the user manager environment, so it never inherited these names. Its header
  says why it must stay without them: "that directory also exports
  CLAUDE_CODE_OAUTH_TOKEN, and Remote Control needs the claude.ai login
  instead."
- `agent.yml` jobs run in the `actions.runner.Nishfleet.netcup-agent-N`
  system units (`runs-on: [self-hosted, agent]`), so they did not inherit the
  user manager either. The worker engines read their own credentials: devin and
  opencode their own logins, cursor `seats/cursor.env`, pi the `litellm`
  provider with per-group keys plus `seats/mobbin-mcp.env`.
- `fleet-litellm-proxy.container` took the whole manager environment through
  `--env-host` until #9020; it now passes the named `PodmanArgs=--env=` list.
  Its `anthropic/` rows set `api_base` explicitly and take `MINIMAX_API_KEY`,
  so `ANTHROPIC_BASE_URL` is not read.
- `fleet-sync`, `fleet-unit-failed@`,
  `fleet-litellm-proxy-config`, the postgres, redis and aiostreams quadlets,
  and the `hermes-`, `tailscaled`, `oomd` and slice drop-ins start no agent.

The runner environment is the one thing the repo cannot show (the runner
`.env` and the live `~/.pi/agent` extensions are outside it). If a worker
engine ever needs one of these names, give that runner a drop-in with the line
above for the single file it needs; nothing in this repo asks for it today. A
hand-run `claude -p` or `systemd-run --user` that needs the token passes the
line above.

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
