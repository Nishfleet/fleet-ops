# LiteLLM proxy + Postgres + Redis — VPS install runbook (fleet-ops#4130 P1)

This is the **Nish-gated** live-install runbook. The repo ships the
systemd units, slices, config shape, and canary; this document is the
operator sequence for putting them live on the VPS. Everything here is
reversible.

**Do not run any of this without Nish's explicit go.** Money (apt is
free; pip is free; no paid LiteLLM tier) is not the gate — the gate is
that a new organ needs Nish's endorsement, which he gave 2026-09-07 for
the program, and the live install is the moment the organ starts
running.

## 0. Disable the distro Postgres + Redis (if present)

The organ runs its OWN fleet-owned Postgres + Redis as user systemd
daemons (Nish, 2026-09-07 reopen of fleet-ops#4174). The distro system
services are NOT used and must be stopped + disabled so they do not
hold port 5432 / 6379. An earlier live-install attempt used the distro
services with the fleet units as oneshot readiness markers — that shape
is rejected (Postgres/Redis showed `active (exited)` instead of
`active (running)`). Skip this step only if the distro packages were
never installed.

```sh
sudo systemctl stop redis-server.service postgresql@16-main.service 2>/dev/null
sudo systemctl disable redis-server.service postgresql@16-main.service postgresql.service 2>/dev/null
# Confirm the ports are free:
ss -tlnp | grep -E '5432|6379'   # (empty)
```

## 1. Postgres (fleet-owned cluster, loopback 127.0.0.1:5432, MemoryMax=1G)

The cluster lives at `~/.local/share/fleet-litellm-postgres`, owned by
the user (NOT the distro `/var/lib/postgresql`). The
`fleet-litellm-postgres.service` unit runs `postgres -D` against it as a
real long-running daemon in `app-litellm-postgres.slice`
(`MemoryMax=1G`). The proxy `Requires=`+`After=` it.

```sh
# The postgres client binaries ship in the postgresql apt package; the
# server binary is in postgresql-16. Install once (no system service use):
sudo apt install -y postgresql-16 postgresql-client-16

PGDATA=$HOME/.local/share/fleet-litellm-postgres
mkdir -p "$(dirname "$PGDATA")"
# initdb a fresh user-owned cluster (trust auth — loopback-only organ).
/usr/lib/postgresql/16/bin/initdb -D "$PGDATA" \
  --auth-local=trust --auth-host=trust --encoding=UTF8 --locale=C
# Loopback-only listener + user-owned socket dir.
cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 5432
unix_socket_directories = '$PGDATA/run'
EOF
mkdir -p "$PGDATA/run"
# Start it once to create the litellm role + DB, then stop (the unit
# owns the long-running process from here).
/usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -l "$PGDATA/start.log" -w start
psql -h 127.0.0.1 -p 5432 -U "$USER" -d postgres -c "CREATE ROLE litellm WITH LOGIN CREATEDB;"
psql -h 127.0.0.1 -p 5432 -U "$USER" -d postgres -c "CREATE DATABASE litellm OWNER litellm;"
/usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -w stop
# Prove the socket dir path the canary probes:
pg_isready -h "$PGDATA/run"
#  /home/nish/.local/share/fleet-litellm-postgres/run:5432 - accepting connections
```

Enable the fleet unit (real daemon, not a readiness marker):

```sh
systemctl --user daemon-reload
systemctl --user enable --now fleet-litellm-postgres.service
systemctl --user status fleet-litellm-postgres.service   # Active: active (running)
```

## 2. Redis (fleet-owned, bind 127.0.0.1, maxmemory 128mb)

The config lives at `~/.local/share/fleet-litellm-redis/redis.conf`,
owned by the user (NOT the distro `/etc/redis/redis.conf`). The
`fleet-litellm-redis.service` unit runs `redis-server` against it as a
real long-running daemon in `app-litellm-redis.slice`
(`MemoryMax=128M`). The proxy `Requires=`+`After=` it.

```sh
sudo apt install -y redis-tools   # redis-server binary is already on the host
RD=$HOME/.local/share/fleet-litellm-redis
mkdir -p "$RD"
cat > "$RD/redis.conf" <<'EOF'
bind 127.0.0.1
port 6379
protected-mode yes
maxmemory 128mb
maxmemory-policy allkeys-lru
dir /home/nish/.local/share/fleet-litellm-redis
dbfilename dump.rdb
save ""
appendonly no
daemonize no
supervised no
loglevel notice
EOF
```

Enable the fleet unit (real daemon, not a readiness marker):

```sh
systemctl --user daemon-reload
systemctl --user enable --now fleet-litellm-redis.service
systemctl --user status fleet-litellm-redis.service   # Active: active (running)
redis-cli -h 127.0.0.1 -p 6379 PING   # PONG
```

## 3. LiteLLM proxy (venv, port 127.0.0.1:4000)

```sh
python3 -m venv ~/.local/venvs/litellm
~/.local/venvs/litellm/bin/pip install --upgrade pip
# Pin a digest, not a floating tag. Check the latest stable at
# https://pypi.org/project/litellm/ and pin to a version >= 7 days old.
~/.local/venvs/litellm/bin/pip install 'litellm[proxy]==<pinned-version>'
~/.local/venvs/litellm/bin/pip audit   # CVE check before first start
```

**fleet-ops#6863 — required post-install patch on litellm 1.98.0.** The
generic-streaming-chunk branch of
`litellm/litellm_core_utils/streaming_handler.py`
(`CustomStreamWrapper._dispatch_provider_chunk`) does
`Usage(**chunk["usage"])`, which raises `TypeError: ... argument after **
must be a mapping, not Usage` whenever a provider's chunk dict carries an
already-materialized usage object (anthropic-shaped/CustomLLM chunks —
the shape that killed `litellm/senior` mid-stream on 2026-09-14). Still
unfixed upstream at 1.101.0. The fleet patch normalizes objects through
`model_dump()` before the `**` unpack, matching the three-shape
(dict/Usage/BaseModel) handling the same file already uses downstream:

```sh
patch -d ~/.local/venvs/litellm/lib/python3.12/site-packages -p1 \
  < /home/nish/workspaces/tooling/fleet-ops-deploy-clone/patches/litellm-1.98.0-gchunk-usage-union.patch
```

Apply it on every venv rebuild — a plain `pip install` reverts the file
silently. `tests/litellm-gchunk-usage-patch.test.sh` is the detector: it
fails when the installed file drops the patch or a litellm bump breaks
the hunk's context. On a version bump, first check whether upstream
fixed the line — if so, drop the patch and this step.

Copy the repo config to the live path and fill in the credential
resolvers. **The repo file is a shape reference only — it is NOT in
MANIFEST and `install.sh` never touches this path.** It carries
`*.example` baseUrls and env-var key names; installing it over a live
router replaces the operator's real seat set with placeholders
(fleet-ops#4174 reopen).

**Fresh checkout:** the live file is operator-owned and is never seeded
by `install.sh`. On a fresh checkout there is no live file, so the proxy
unit's `ConditionPathExists` stays false and the proxy intentionally does
not start — that is fail-closed by design, not a fault. The operator
creates the live copy by hand per this section before the proxy runs. **LiteLLM 1.98 does NOT support a command-style
`api_key:` resolver** — that assumption in the original shape was wrong.
The supported form is `api_key: os.environ/<NAME>` (litellm
`secret_managers`), so the live copy names env vars and §3a's start wrapper
puts the real values into the process environment. No key value ever
enters the repo:

```sh
mkdir -p ~/.config/fleet-ops
cp config/litellm-proxy.yaml ~/.config/fleet-ops/litellm-proxy.yaml
# Then edit that NEW file by hand:
#   1. replace every *.example api_base with the provider's real baseUrl;
#   2. keep each deployment's api_key as os.environ/<PROVIDER>_API_KEY —
#      the name must match what the section 3a wrapper exports;
#   3. set master_key: os.environ/LITELLM_MASTER_KEY;
#   4. mint the sk-fleet-worker / sk-fleet-senior / sk-fleet-private
#      virtual keys via the proxy's /key/generate admin API (LiteLLM
#      virtual_keys docs), pinning each key's model allowlist to a group.
#   5. keep `disable_prisma_schema_update: true` under general_settings
#      (fleet-ops#4832): without it, startup `prisma migrate deploy`
#      retries 20250416115320_add_tag_table_to_db, whose redundant
#      single-column unique index LiteLLM_DailyTagSpend_tag_key cannot
#      build on a table that holds several rows per tag (they differ on
#      the composite key — legitimate rows, not duplicates). The retry
#      loop stalls every restart ~10min on P3018. Upstream's own
#      20250416151339_drop_tag_uniqueness_requirement drops that index;
#      the composite unique index is the real constraint. Re-enable the
#      flag only to apply migrations from a LiteLLM bump, then re-disable.
# If a live config already exists, edit it in place instead of copying.
```

### 3a. The start wrapper (`~/.local/bin/fleet-litellm-proxy-start`)

The proxy unit's `ExecStart` IS this wrapper. It exists because two things
LiteLLM needs cannot be expressed in the config file (fleet-ops#4174
reopen — without it the installed organ dies at startup):

1. Keys come from `os.environ/<NAME>`, so something has to export them.
   The wrapper sources the credential env files that already exist on the
   host and reads the xai OAuth access token out of Pi's `auth.json`. It
   prints nothing, moves nothing, duplicates nothing — the stores stay
   where they are.
2. LiteLLM's Prisma layer reads `DATABASE_URL` from the ENVIRONMENT, not
   from `general_settings.database_url`. And the socket-less form
   `postgresql:///litellm` is rejected by the query engine (P1012); the
   working form is host-qualified.

It is operator-owned (it names secret-bearing paths) so it is NOT a MANIFEST
entry; this runbook is its canonical copy, which is what makes a bare-metal
rebuild complete. `tests/fleet-litellm-organ.test.sh` §5e pins that the unit
and this section stay in sync.

The unit invokes it through `/usr/bin/env` (`ExecStart=/usr/bin/env
~/.local/bin/fleet-litellm-proxy-start`). That keeps the first ExecStart token
runner-safe, so CI's `systemd-analyze` job and `p14-unstubbed-unit-verify` pass
without a Workflows-scope ci.yml stub (fleet-ops#4398); `/usr/bin/env` execs the
wrapper via its shebang, so the live organ is unchanged.

```sh
cat > ~/.local/bin/fleet-litellm-proxy-start <<'EOF'
#!/bin/bash
# fleet-litellm-proxy-start — resolve credentials into the environment at
# runtime, then exec litellm. See docs/litellm-postgres-setup.md §3a.
set -euo pipefail
set -a

# --- env-file providers (KEY=value format, safe to source) ---
# fleet-ops#6748: use the seats directory from repair record #7100.
# The old fleet2 directory was removed; see the incident note below.
source /home/nish/.config/fleet-ops/seats/opencode.env
source /home/nish/.config/fleet-ops/seats/commandcode.env
source /home/nish/.config/fleet-ops/seats/hetzner.env
source /home/nish/.config/fleet-ops/seats/devin.env
source /home/nish/.config/fleet-ops/seats/cursor.env
source /home/nish/.config/fleet-ops/seats/openrouter.env
# fleet-ops#4219: P3a dual-run found the original pool walled/dead in seat-lib
# (opencode-zen balance, commandcode model unsupported, hetzner corpse, straitly
# credits exhausted, grok cli-chat-proxy 426). Source the credential env files of
# the seats that are actually usable and OpenAI-compatible.
source /home/nish/.config/fleet-ops/seats/alibaba-coding.env
source /home/nish/.config/fleet-ops/seats/groq.env
source /home/nish/.config/fleet-ops/seats/ollama.env
source /home/nish/.config/fleet-ops/seats/cline.env
source /home/nish/.config/fleet-ops/seats/paretoinference.env
source /home/nish/.config/xkiro/.env
source /home/nish/.config/fleet-ops/seats/runinfra.env
source /home/nish/.config/fleet-ops/seats/entrim.env
source /home/nish/.config/fleet-ops/seats/crof.env
# 2026-09-11 seat wire-up: synthetic + llmgateway-devpass prepaid worker seats
# (fleet-ops packet; env files mode 600 under ~/.config/fleet-ops/seats/).
source /home/nish/.config/fleet-ops/seats/synthetic.env
source /home/nish/.config/fleet-ops/seats/llmgateway-devpass.env
# 2026-09-12 seat wire-up: nebius Token Factory metered worker seat (same
# packet; env file mode 600 under ~/.config/fleet-ops/seats/).
source /home/nish/.config/fleet-ops/seats/nebius.env

# --- straitly (lives in ~/.config/straitly/) ---
source /home/nish/.config/straitly/straitly.env

# --- xai-oauth: OAuth access token from auth.json (refreshed every 4h by
# grok-token-refresh). Read once at proxy start; grok-token-refresh restarts
# this unit after a successful rotate so the new token is picked up
# (fleet-ops#4629). cli-chat-proxy identity headers live on the grok-4.6
# deployments as litellm_params.extra_headers in the live yaml, not here.
export XAI_OAUTH_ACCESS_TOKEN=$(/usr/bin/python3 -c "
import json, sys
try:
    a = json.load(open('/home/nish/.pi/agent/auth.json'))
    sys.stdout.write(a.get('xai-oauth', {}).get('access', ''))
except Exception:
    sys.stdout.write('')
")

# --- MiniMax (fleet-ops#5788): the claude-minimax-key wrapper resolves
# ~/.mmx/config.json into an access token, refreshing it transparently if
# within 5 min of expiry. Captured once at proxy start.
#
# The minimax-token-refresh timer that used to compare this captured value
# against a fresh wrapper key every 2h and bounce the proxy on a mismatch
# was DELETED in the 2026-09-18 glue sweep: the live yaml carries no MiniMax
# deployment any more (the key 401s "login fail" — see the yaml header), so
# there was nothing left for a rotated key to reach. Its last 8 hours of runs
# all logged "SKIP: no live fleet-litellm-proxy process to inspect" — its
# /proc detection had stopped matching the running proxy too.
# Restore the timer from git history if a MiniMax deployment ever returns.
export MINIMAX_API_KEY=$(/home/nish/.local/bin/claude-minimax-key)

# --- the proxy's own admin key (virtual-key minting). Generated once,
# stored in a mode-0600 env file owned by the operator, never in the repo.
source /home/nish/.config/fleet-ops/litellm-master-key.env

# --- DATABASE_URL: Prisma reads this from the ENV, not the config file.
# The fleet-owned cluster listens on loopback; the socket-only form is
# rejected by the query engine (P1012).
export DATABASE_URL=postgresql://litellm@localhost:5432/litellm
# venv/bin first so `prisma` is on PATH (proxy_cli.py looks it up as a
# bare binary). PYTHONPATH loads the prisma 0.15 _engine-setter compat
# hook (fleet-ops#4628) so reconnect does not AttributeError on the
# dropped _Prisma__engine mangled name.
export PATH=/home/nish/.local/venvs/litellm/bin:$PATH
export PYTHONPATH=/home/nish/.local/libexec/fleet-litellm-prisma-compat${PYTHONPATH:+:$PYTHONPATH}

set +a
exec /home/nish/.local/venvs/litellm/bin/litellm \
  --config /home/nish/.config/fleet-ops/litellm-proxy.yaml \
  --port 4000 \
  --host 127.0.0.1
EOF
chmod 700 ~/.local/bin/fleet-litellm-proxy-start
```

#### September 15–16 outage evidence, #6748

The preserved user journal identifies a startup failure, not a slow boot.
All times below are UTC. Read with `journalctl --user --utc -o short-iso`
and the named unit and time range.

- `fleet-litellm-proxy.service`, September 14 18:31:42: the service stopped.
  From 18:31:43 to 19:15:13, 20 starts failed at wrapper line 16 because
  `/home/nish/fleet2/etc/opencode.env` was missing. Under `set -euo pipefail`,
  that first failed source aborts startup. The other 13 sources are not
  evidence of 13 additional failures. Systemd exhausted its restart limit.
- `fleet-litellm-health-canary.service` remained unreachable through
  September 15 and into September 16. At September 16 04:03:00 its dead
  counter was 120,660 seconds. This was about 33.5 hours, not a restart gap.
- At September 16 04:00:36 through 04:02:12 the proxy journal records a
  second startup error in the restored `devin.env`: an unbound variable.
  The token fragment from that error is deliberately omitted here.
- [Repair record #7100](https://github.com/Nishfleet/fleet-ops/issues/7100)
  describes restoring the missing files, fixing shell quoting, then moving
  the 14 sources to the seats directory and updating the wrapper. Its
  claim that gap-audit caused the deletion is an attributed report: the
  journal proves the missing file, not who deleted it. Its approximate
  outage start time is superseded by the 18:31:43 journal record above.
- The canary's first green record in the recovery window is September 16
  04:04:01: `proxy_up=1 status=200 census=6 expected=6 groups=2 pg_up=1
  redis_up=1`. The 04:05, 04:06 and 04:07 runs agree. Restoration preceded
  the final directory move; the live wrapper's mtime is 04:15:27 UTC.
  Inspection on September 17 found the 14 replacement source paths in
  that wrapper, no old directory references, and a clean `bash -n` result.

This PR records that existing repair and fixes the reinstall instructions;
it does not deploy the wrapper or claim a fresh production repair. No
merged repair SHA was found for the operator-owned wrapper. The identity
and command responsible for deleting the old directory remain unproven.
The separate routing and audit-policy follow-ups in #7100 are not closed
by this mapping. Failed attempts retained from #7028, #7030, #7061, #7088,
#7056 and #7082 are not counted as successful repairs.

The inherited commits `9b8ef205b177fedebf7bbc83f81c3d02cc57642b` and
`0b8ef1d031dd434e65e301a22c5267395f54d161` are rejected, not carried forward.
Their 300-second restart hold and resettable clock could hide a sustained
outage. Neither commit is an ancestor of the checked base
`9f4d08bfef7dfd6e0e2b13ee8bbdedaece76565a`. The existing 60-second dead
alarm remains unchanged. No new checker or timeout relaxation is added.

### 3b. Pi's client side (`config/pi-models.json` provider `litellm`)

Pi reaches the proxy as an OpenAI-compatible provider whose key is a virtual
key minted for one group. The repo already ships that row; it resolves its
key through `~/.local/bin/fleet-litellm-key <group>` (the `!cmd` apiKey form
Pi does support — unlike LiteLLM's config, which has no command resolver).
Create that resolver so a consumer can authenticate:

```sh
install -m 700 /dev/null ~/.local/bin/fleet-litellm-key
# Then edit it: read the group->virtual-key map from
# ~/.config/fleet-ops/litellm-virtual-keys.env and print exactly one key for
# the group named in $1. Print nothing on an unknown group — a silent empty
# key fails the request loudly instead of falling back to master_key.
```

Do not hand the master key to consumers: it is the admin credential that
mints and revokes virtual keys.

### 3c. Devin CustomLLM sibling (fleet-ops#6228)

LiteLLM loads `litellm_settings.custom_provider_map` handlers as a file
next to the live config (`get_instance_fn` joins the config directory with
the module name). After a yaml sync, the handler must exist at
`~/.config/fleet-ops/fleet_devin_adapter.py` or the proxy fails to start.

MANIFEST/install.sh are gone. The durable copy is a symlink into the
deploy clone, the same pattern as prisma-compat:

```sh
ln -sfn /home/nish/workspaces/tooling/fleet-ops-deploy-clone/libexec/fleet-litellm-devin-adapter/fleet_devin_adapter.py \
  /home/nish/.config/fleet-ops/fleet_devin_adapter.py
```

Do not run this without Nish's go: it is part of putting the organ live,
not part of landing the repo file. The unit's PYTHONPATH also lists the
deploy-clone adapter directory so `import_module` can find the handler if
the sibling file is missing. `custom_provider_map` in
`config/litellm-proxy.yaml` names `fleet_devin_adapter.devin_windsurf_llm`.

Start the proxy:

```sh
systemctl --user daemon-reload
systemctl --user enable --now fleet-litellm-proxy.service
curl -s http://127.0.0.1:4000/health/readiness | jq .
# Expect {"status":"healthy","db":"connected"} — db:connected is the proof
# the Prisma layer reached the fleet-owned cluster, not just that uvicorn bound.
```

## 4. /health canary + prom scrape

```sh
# Prove one tick:
cat /var/lib/prometheus/node-exporter/fleet-litellm-health.prom
# Reload prometheus so the new litellm scrape job + absent() rules load:
sudo systemctl reload prometheus
# Prove the rules loaded (fleet-ops#1307):
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[].rules[].name' | grep -i litellm
```

## 5. Backup (Postgres)

Add a `pg_dump` to the existing backup job (the fleet already has a
backup organ; this adds one line). The fleet-owned cluster socket is
user-owned, so no sudo:

```sh
# In the existing backup script (fleet-owned cluster socket):
pg_dump -h "$HOME/.local/share/fleet-litellm-postgres/run" -U litellm litellm \
  | gzip > /home/nish/workspaces/agent-state/backups/litellm-$(date -u +%Y%m%dT%H%M%SZ).sql.gz
# Retain per the existing backup rotation.
```

The P4 drill proves Postgres-down → workers fail loud <60s, restore
<10 min from this dump + the fleet unit.

## Rollback (full)

```sh
systemctl --user stop fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis
systemctl --user disable fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis
# Remove the litellm scrape job from config/prometheus.yml + reload prom.
# Drop the fleet-owned cluster (no sudo — it is user-owned):
psql -h 127.0.0.1 -p 5432 -U "$USER" -d postgres -c "DROP DATABASE litellm;"
rm -rf "$HOME/.local/share/fleet-litellm-postgres" "$HOME/.local/share/fleet-litellm-redis"
# The venv + apt packages can stay (no running organ); remove if desired:
# ~/.local/venvs/litellm/bin/pip uninstall litellm
# sudo apt remove postgresql-16 redis-tools   # Nish's call
```

No consumer exists in P1 (P2 lands the first), so rollback has zero
fleet impact.
