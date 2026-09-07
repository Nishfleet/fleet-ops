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

## 1. Postgres (local socket only, MemoryMax=1G)

```sh
sudo apt update
sudo apt install -y postgresql postgresql-contrib
# Socket-only: ensure /etc/postgresql/14/main/postgresql.conf has
#   listen_addresses = ''
# (default on Debian is already loopback; set to '' for socket-only).
sudo systemctl stop postgresql
sudo sed -i "s/^#*listen_addresses.*/listen_addresses = ''/" /etc/postgresql/14/main/postgresql.conf
sudo systemctl start postgresql
# Create the litellm DB + user (no password — socket auth).
sudo -u postgres createuser -d litellm
sudo -u postgres createdb -O litellm litellm
# Prove the socket works:
pg_isready -h /var/run/postgresql
#  /var/run/postgresql:5432 - accepting connections
```

The `fleet-litellm-postgres.service` unit wraps the distro postgres in
the `app-litellm-postgres.slice` (`MemoryMax=1G`). Enable it after the
apt install:

```sh
systemctl --user daemon-reload
systemctl --user enable --now fleet-litellm-postgres.service
```

## 2. Redis (bind 127.0.0.1, maxmemory 128mb)

```sh
sudo apt install -y redis-server
# Bind loopback, cap memory. The unit passes --maxmemory 128mb on the
# command line; the conf change is defence-in-depth.
sudo sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
sudo systemctl restart redis-server
redis-cli -h 127.0.0.1 PING   # PONG
```

Enable the wrapper unit:

```sh
systemctl --user enable --now fleet-litellm-redis.service
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
backup organ; this adds one line):

```sh
# In the existing backup script:
pg_dump -h /var/run/postgresql -U litellm litellm | gzip > /home/nish/workspaces/agent-state/backups/litellm-$(date -u +%Y%m%dT%H%M%SZ).sql.gz
# Retain per the existing backup rotation.
```

The P4 drill proves Postgres-down → workers fail loud <60s, restore
<10 min from this dump + the distro unit.

## Rollback (full)

```sh
systemctl --user stop fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis fleet-litellm-health-canary.timer
systemctl --user disable fleet-litellm-proxy fleet-litellm-postgres fleet-litellm-redis fleet-litellm-health-canary.timer
# Remove the litellm scrape job from config/prometheus.yml + reload prom.
# Drop the DB:
sudo -u postgres dropdb litellm
# The venv + apt packages can stay (no running organ); remove if desired:
# ~/.local/venvs/litellm/bin/pip uninstall litellm
# sudo apt remove postgresql redis-server   # Nish's call
```

No consumer exists in P1 (P2 lands the first), so rollback has zero
fleet impact.
