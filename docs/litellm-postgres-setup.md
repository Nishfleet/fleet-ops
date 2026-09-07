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

Copy the repo config to the live path and fill in the credential
resolvers (the `api_key: command:...` lines). The repo
`config/litellm-proxy.yaml` is the shape; the live copy is operator-owned
so no key enters the repo:

```sh
mkdir -p ~/.config/fleet-ops
cp config/litellm-proxy.yaml ~/.config/fleet-ops/litellm-proxy.yaml
# Edit ~/.config/fleet-ops/litellm-proxy.yaml: replace each
#   api_key: command:/home/nish/.local/bin/<resolver>
# with the real resolver path (the same binaries models.json's `!cmd`
# style uses). Set master_key from a credential resolver and mint the
# sk-fleet-worker / sk-fleet-senior / sk-fleet-private virtual keys
# via `litellm --config ... --create-key` (see LiteLLM virtual_keys docs).
```

Start the proxy:

```sh
systemctl --user daemon-reload
systemctl --user enable --now fleet-litellm-proxy.service
curl -s http://127.0.0.1:4000/health/readiness | jq .
```

## 4. /health canary + prom scrape

```sh
systemctl --user enable --now fleet-litellm-health-canary.timer
# Prove one tick:
systemctl --user start fleet-litellm-health-canary.service
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
systemctl --user stop fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis fleet-litellm-health-canary.timer
systemctl --user disable fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis fleet-litellm-health-canary.timer
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
