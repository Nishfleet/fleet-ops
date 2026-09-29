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
`git pull --ff-only` + `daemon-reload` and fails (`DEPLOY-BLOCKED`) on a dirty
or diverged clone, so the canonical checkout
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone` stays clean on `main`.
Its LINK-GUARD passes fail the unit while any live symlink under
`~/.config/systemd/user/`, `~/.local/bin/`, `~/.pi/agent/` or the vault is
broken or resolves into a throwaway root (`*worktrees/*`, `agent-state`,
`tmp`).

`~/.pi/agent/agents/` holds only the stock agents from `template/agents/`;
per-issue copies (`reviewer-issue-<N>.md`, removed under fleet-ops#8659) are
loaded by nothing.

Wiring a new unit or prompt is one `ln -sfn` into the deploy clone, once
(full commands in README). Four classes stay copies rather than symlinks:
the two `/etc/prometheus` files (fleet-sync does the copy + reload), the two
Pi extension forks, the live-state JSON files under `~/.local/state/` and
`~/.config/fleet-ops`-owned files that cross a privilege boundary.

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
same way; `disable_prisma_schema_update: true` stays under `general_settings`
(startup `prisma migrate deploy` stalls every restart without it), and
`DATABASE_URL` is a unit `Environment=` in host-qualified form (the
socket-less form is rejected). Consumer credentials are per-group virtual keys
minted via the admin API, never the master key. An admin-API call keeps the
key out of argv — `curl -H "Authorization: Bearer $KEY"` leaves the key in
`/proc/<pid>/cmdline` for the life of the curl (fleet-ops#8403) — via
`curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$LITELLM_MASTER_KEY")`
or `-H @<0600 headers file>`.

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
