#!/usr/bin/env bash
# tests/fleet-litellm-organ.test.sh
#
# fleet-ops#4130 P1 — every new LiteLLM organ (proxy + Postgres + Redis +
# /health canary) ships an absent() heartbeat rule in config/fleet_rules.yml
# in the same PR (fleet-ops#1010 standing pattern), a prom scrape job in
# config/prometheus.yml, a MANIFEST install line, and a working canary bin.
# This test proves all four are wired together and that the organ-heartbeat
# gate would not REJECT this PR.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-organ-heartbeat-check"
registry="$repo_root/config/fleet-organs.json"
rules="$repo_root/config/fleet_rules.yml"
prom="$repo_root/config/prometheus.yml"
manifest="$repo_root/MANIFEST"
canary="$repo_root/libexec/fleet-litellm-health-canary.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$registry" ]] || fail "missing: $registry"
[[ -f "$rules" ]] || fail "missing: $rules"
[[ -f "$prom" ]] || fail "missing: $prom"
[[ -f "$manifest" ]] || fail "missing: $manifest"
[[ -f "$canary" ]] || fail "missing: $canary"

# --- 1: registry has the four new organs with the right fields
python3 - "$registry" <<'PY' || fail "1: registry missing new organs"
import json, sys
data = json.load(open(sys.argv[1]))
organs = {o["name"]: o for o in data["organs"]}
for name in ("litellm-proxy", "litellm-postgres", "litellm-redis", "litellm-health-canary"):
    assert name in organs, f"{name} organ missing"
px = organs["litellm-proxy"]
assert px["heartbeat_metric"] == "fleet_litellm_proxy_up", px
assert px["absent_alert"] == "FleetLitellmProxyAbsent", px
assert "systemd/fleet-litellm-proxy.service" in px["files"], px
assert "systemd/app-litellm.slice" in px["files"], px
assert "config/litellm-proxy.yaml" in px["files"], px
assert "libexec/fleet-litellm-prisma-compat/sitecustomize.py" in px["files"], px
pg = organs["litellm-postgres"]
assert pg["heartbeat_metric"] == "fleet_litellm_postgres_up", pg
assert pg["absent_alert"] == "FleetLitellmPostgresAbsent", pg
assert "systemd/fleet-litellm-postgres.service" in pg["files"], pg
rd = organs["litellm-redis"]
assert rd["heartbeat_metric"] == "fleet_litellm_redis_up", rd
assert rd["absent_alert"] == "FleetLitellmRedisAbsent", rd
assert "systemd/fleet-litellm-redis.service" in rd["files"], rd
cn = organs["litellm-health-canary"]
assert cn["heartbeat_metric"] == "fleet_litellm_proxy_last_green_seconds", cn
assert cn["absent_alert"] == "FleetLitellmHealthCanaryAbsent", cn
assert "libexec/fleet-litellm-health-canary.py" in cn["files"], cn
assert "systemd/fleet-litellm-health-canary.service" in cn["files"], cn
assert "systemd/fleet-litellm-health-canary.timer" in cn["files"], cn
print("registry OK")
PY
ok "1: registry has all four LiteLLM organs with right fields"

# --- 2: rules carry all four absent() expressions
# fleet_litellm_proxy_up is a labeled gauge ({endpoint="readiness"}); the
# absent() rule matches the labeled form. The other three are unlabeled.
grep -q 'absent(fleet_litellm_proxy_up{endpoint="readiness"})' "$rules" \
    || fail "2: absent(fleet_litellm_proxy_up{endpoint=\"readiness\"}) missing"
for metric in \
    "fleet_litellm_postgres_up" \
    "fleet_litellm_redis_up" \
    "fleet_litellm_proxy_last_green_seconds"; do
    grep -q "absent($metric)" "$rules" || fail "2: absent($metric) missing"
done
for alert in \
    "FleetLitellmProxyAbsent" \
    "FleetLitellmPostgresAbsent" \
    "FleetLitellmRedisAbsent" \
    "FleetLitellmHealthCanaryAbsent"; do
    grep -q "$alert" "$rules" || fail "2: $alert alert missing"
done
grep -q 'fleet-ops#4130' "$rules" || fail "2: rules must reference fleet-ops#4130"
ok "2: rules carry all four absent() expressions and reference fleet-ops#4130"

# --- 3: prom scrape job for the proxy /metrics endpoint
grep -q 'job_name: litellm' "$prom" || fail "3: prom missing litellm scrape job"
grep -q '127.0.0.1:4000' "$prom" || fail "3: prom litellm job must target 127.0.0.1:4000"
# Trailing slash: LiteLLM serves /metrics/, and a bare /metrics is a 307
# with no body — Prometheus would report the target up while scraping
# nothing (fleet-ops#4174 reopen).
grep -q 'metrics_path: /metrics/' "$prom" \
    || fail "3: prom litellm job must set metrics_path /metrics/ (trailing slash — bare /metrics only 307s)"
ok "3: prometheus has litellm scrape job at 127.0.0.1:4000/metrics/"

# --- 4: MANIFEST installs every new file
for f in \
    "systemd/app-litellm.slice" \
    "systemd/app-litellm-postgres.slice" \
    "systemd/app-litellm-redis.slice" \
    "systemd/fleet-litellm-proxy.service" \
    "systemd/fleet-litellm-postgres.service" \
    "systemd/fleet-litellm-redis.service" \
    "libexec/fleet-litellm-health-canary.py" \
    "libexec/fleet-litellm-prisma-compat/sitecustomize.py" \
    "systemd/fleet-litellm-health-canary.service" \
    "systemd/fleet-litellm-health-canary.timer"; do
    grep -q "^$f " "$manifest" || fail "4: MANIFEST missing install line for $f"
done
ok "4: MANIFEST installs every new LiteLLM file"

# --- 4c: the health-canary pg-socket drop-in is repo-sourced (fleet-ops#4439)
# It was a real file under the live drop-in dir, invisible to the
# unit-name-only hunt (fleet-ops#2924 / #1548), and is now absorbed into
# systemd/ + MANIFEST so deploy symlinks it and the hunt stays clean. It is a
# pure [Service] Environment override pointing the postgres probe at the
# fleet-owned user-level socket dir (fleet-ops#4130), not new machinery.
dropin="$repo_root/systemd/fleet-litellm-health-canary.service.d/10-pg-socket.conf"
[[ -f "$dropin" ]] || fail "4c: repo drop-in missing: $dropin"
grep -q "^systemd/fleet-litellm-health-canary.service.d/10-pg-socket.conf " "$manifest" \
    || fail "4c: MANIFEST missing install line for the pg-socket drop-in"
grep -q 'FLEET_LITELLM_PG_HOST=/home/nish/.local/share/fleet-litellm-postgres/run' "$dropin" \
    || fail "4c: pg-socket drop-in must set the fleet-owned user-level socket dir"
ok "4c: health-canary pg-socket drop-in is repo-sourced + in MANIFEST"

# --- 4d: all three litellm organs resolve ManagedOOMPreference=avoid
# (fleet-ops#4861). systemd-oomd was free to pick the DB organ first because
# the litellm units carried ManagedOOMPreference=none; the fleet already
# protects other units with an avoid drop-in. Each organ must carry a
# repo-sourced 20-oom-avoid.conf drop-in that sets ManagedOOMPreference=avoid
# (postgres also MemoryMin=256M, no MemoryMax on any of the three).
for unit in fleet-litellm-postgres fleet-litellm-proxy fleet-litellm-redis; do
    dropin="$repo_root/systemd/$unit.service.d/20-oom-avoid.conf"
    [[ -f "$dropin" ]] || fail "4d: repo drop-in missing for $unit: $dropin"
    grep -q '^ManagedOOMPreference=avoid$' "$dropin" \
        || fail "4d: $unit drop-in must set ManagedOOMPreference=avoid"
    grep -q "^systemd/$unit.service.d/20-oom-avoid.conf " "$manifest" \
        || fail "4d: MANIFEST missing install line for $unit 20-oom-avoid.conf"
    if grep -q '^MemoryMax=' "$dropin"; then
        fail "4d: $unit drop-in must NOT set MemoryMax (fleet-ops#4861)"
    fi
done
# postgres alone carries MemoryMin=256M to protect its working set.
grep -q '^MemoryMin=256M$' "$repo_root/systemd/fleet-litellm-postgres.service.d/20-oom-avoid.conf" \
    || fail "4d: postgres drop-in must set MemoryMin=256M"
if grep -q '^MemoryMin=' "$repo_root/systemd/fleet-litellm-proxy.service.d/20-oom-avoid.conf" \
    || grep -q '^MemoryMin=' "$repo_root/systemd/fleet-litellm-redis.service.d/20-oom-avoid.conf"; then
    fail "4d: only the postgres drop-in may set MemoryMin (fleet-ops#4861)"
fi
ok "4d: all three litellm organs resolve ManagedOOMPreference=avoid (postgres MemoryMin=256M)"

# --- 4b: the repo router config is a SHAPE, never an install target
# (fleet-ops#4174 reopen). The live ~/.config/fleet-ops/litellm-proxy.yaml
# holds the operator's real baseUrls and seat set; installing the repo copy
# over it silently replaces them with *.example placeholders. A previous
# MANIFEST line did exactly that and fleet-ops#4219's backup exists to undo
# it. Pin that it never comes back.
if grep -qE '^config/litellm-proxy\.yaml[[:space:]]' "$manifest"; then
    fail "4b: MANIFEST must NOT install config/litellm-proxy.yaml — it is the shape reference, not the live operator config (fleet-ops#4174)"
fi
grep -q 'config/litellm-proxy.yaml' "$repo_root/docs/litellm-postgres-setup.md" \
    || fail "4b: the runbook must tell the operator how the live config is created from the repo shape"
ok "4b: repo router config stays out of the install path; runbook covers the live copy"

# --- 5: canary bin compiles + the organ-dead path exits 1
python3 -m py_compile "$canary" || fail "5: canary py_compile failed"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stub="$scratch/stub.json"
printf '{"healthy_endpoints":[{"model_info":{"model_name":"worker-cheap"}}],"unhealthy_endpoints":[]}' > "$stub"
# proxy_up=1 path: exit 0, prom written with the heartbeat metric
FLEET_LITELLM_PROM="$scratch/up.prom" \
FLEET_LITELLM_STATE="$scratch/up.json" \
FLEET_LITELLM_STUB="$stub" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1700000000 \
python3 "$canary" --quiet || fail "5: canary proxy_up=1 path must exit 0"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 1' "$scratch/up.prom" \
    || fail "5: prom missing proxy_up=1"
grep -q 'fleet_litellm_organ_installed 1' "$scratch/up.prom" \
    || fail "5: installed prom missing organ_installed=1"
grep -q 'fleet_litellm_postgres_up 1' "$scratch/up.prom" \
    || fail "5: prom missing postgres_up=1"
grep -q 'fleet_litellm_redis_up 1' "$scratch/up.prom" \
    || fail "5: prom missing redis_up=1"
grep -q 'fleet_litellm_proxy_last_green_seconds 1700000000' "$scratch/up.prom" \
    || fail "5: prom missing last_green_seconds"
# organ-dead path: connection refused with zero tolerance -> exit 1, prom still written with proxy_up=0
FLEET_LITELLM_PROM="$scratch/dead.prom" \
FLEET_LITELLM_STATE="$scratch/dead.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:1 \
FLEET_LITELLM_DEAD_TOLERANCE_S=0 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" --quiet && fail "5: canary organ-dead path must exit 1"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 0' "$scratch/dead.prom" \
    || fail "5: organ-dead prom missing proxy_up=0"
grep -q 'fleet_litellm_organ_installed 1' "$scratch/dead.prom" \
    || fail "5: organ-dead prom missing organ_installed=1 (installed marker stays 1 when organ dies)"
# --- 5c: simple readiness format (LiteLLM 1.98+ default, fleet-ops#4174 reopen)
# The proxy returns {"status":"healthy","db":"connected"} instead of the
# detailed endpoints format. The canary must still report proxy_up=1.
# Group gauges come from GET /health (fleet-ops#4628, tests 11-14).
simple_stub="$scratch/simple.json"
printf '{"status":"healthy","db":"connected"}' > "$simple_stub"
printf 'model_list:\n  - model_name: worker-cheap\n' > "$scratch/simple-models.yaml"
FLEET_LITELLM_PROM="$scratch/simple.prom" \
FLEET_LITELLM_STATE="$scratch/simple.state.json" \
FLEET_LITELLM_STUB="$simple_stub" \
FLEET_LITELLM_CONFIG="$scratch/simple-models.yaml" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1700000100 \
python3 "$canary" --quiet || fail "5c: canary simple-format path must exit 0"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 1' "$scratch/simple.prom" \
    || fail "5c: simple-format prom missing proxy_up=1"
# fleet-ops#4628: a simple {"status":"healthy"} body is NOT a deployment
# census. Group gauges come from GET /health (tests 11-14). Readiness
# still proves proxy_up=1.
ok "5c: canary handles LiteLLM simple readiness format (proxy_up=1)"

ok "5: canary compiles, proxy_up=1 path exits 0, sustained organ-dead exits 1"

# --- 5e: single connection-refused tick inside a restart window holds (exit 0),
# prom still written proxy_up=0 and dead_since persisted for the next tick.
printf '{"dead_since": 1699999995, "proxy_up": 0}'> "$scratch/hold.json"
FLEET_LITELLM_PROM="$scratch/hold.prom" \
FLEET_LITELLM_STATE="$scratch/hold.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:1 \
FLEET_LITELLM_DEAD_TOLERANCE_S=60 \
FLEET_LITELLM_NOW=1700000000 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" --quiet || fail "5e: single dead tick inside tolerance must hold (exit 0)"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 0' "$scratch/hold.prom" \
    || fail "5e: held tick prom missing proxy_up=0"
grep -q '"dead_since": 1699999995' "$scratch/hold.json" \
    || fail "5e: held tick must persist dead_since"
ok "5e: single dead tick inside a restart window is held (proxy_up=0, exit 0)"

# --- 5f: dead longer than the tolerance -> exit 1 (real organ death surfaces)
printf '{"dead_since": 1699999880, "proxy_up": 0}'> "$scratch/deadlong.json"
FLEET_LITELLM_PROM="$scratch/deadlong.prom" \
FLEET_LITELLM_STATE="$scratch/deadlong.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:1 \
FLEET_LITELLM_DEAD_TOLERANCE_S=60 \
FLEET_LITELLM_NOW=1700000000 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" --quiet && fail "5f: dead past tolerance must exit 1"
ok "5f: sustained dead past the tolerance exits 1 (fail-loud preserved)"

# --- 5g (fleet-ops#6315): a HEALTH-ONLY hang is not organ death. The
# 2026-09-13 incident: readiness+health 0-byte timeouts 120s+ while
# /chat/completions answered 200. Readiness unanswered + one 1-token
# completion answering => hold, exit 0, prom proxy_up=0 (honest — readiness
# did NOT answer), NO dead latch, NO exit 1. The hang listener accepts and
# never responds (a real event-loop wedge, not a refusal).
python3 - <<'PY' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 44971)); s.listen(8)
c, _ = s.accept(); time.sleep(20)
PY
HUNG6315=$!
sleep 0.6
: > "$scratch/hang-completions.ok"
FLEET_LITELLM_PROM="$scratch/hang6315.prom" \
FLEET_LITELLM_STATE="$scratch/hang6315.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:44971 \
FLEET_LITELLM_TIMEOUT_S=2 \
FLEET_LITELLM_STUB_COMPLETIONS="$scratch/hang-completions.ok" \
FLEET_LITELLM_STUB_PG=1 FLEET_LITELLM_STUB_REDIS=1 FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1757743200 \
python3 "$canary" --quiet || fail "5g: hang+completions-200 must hold (exit 0)"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 0' "$scratch/hang6315.prom" \
    || fail "5g: hang prom must keep proxy_up=0 (readiness did not answer)"
SCRATCH6315="$scratch" python3 -c "
import json, os
d = json.load(open(os.environ['SCRATCH6315'] + '/hang6315.json'))
assert d['completions_ok'] is True, d
assert d['completions_status'] == 200, d
assert d['dead_since'] is None, d
assert d['empty_since'] is None, d
assert d['proxy_up'] == 0, d
"
kill "$HUNG6315" 2>/dev/null; wait "$HUNG6315" 2>/dev/null || true
ok "5g: #6315 health-only hang holds (exit 0, completions_ok, no dead latch)"

# --- 5h (fleet-ops#6315): readiness hung AND the completion unanswered =>
# the existing #4130 dead-tolerance latch, exit 1 — unchanged.
python3 - <<'PY' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 44972)); s.listen(8)
c, _ = s.accept(); time.sleep(20)
PY
HUNG2_6315=$!
sleep 0.6
FLEET_LITELLM_PROM="$scratch/full6315.prom" \
FLEET_LITELLM_STATE="$scratch/full6315.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:44972 \
FLEET_LITELLM_TIMEOUT_S=2 \
FLEET_LITELLM_DEAD_TOLERANCE_S=0 \
FLEET_LITELLM_STUB_PG=1 FLEET_LITELLM_STUB_REDIS=1 FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1757743200 \
python3 "$canary" --quiet && fail "5h: hung readiness + unanswered completion must exit 1"
grep -q '"dead_since": 1757743200' "$scratch/full6315.json" \
    || fail "5h: fully-starved must still latch dead_since"
kill "$HUNG2_6315" 2>/dev/null; wait "$HUNG2_6315" 2>/dev/null || true
ok "5h: #6315 fully-starved (readiness+completion dead) keeps the #4130 fail-loud"

# --- 5b: organ-not-installed path (Nish-gated live install not yet done) -> exit 0, no fail-loud
FLEET_LITELLM_PROM="$scratch/notinst.prom" \
FLEET_LITELLM_STATE="$scratch/notinst.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:1 \
FLEET_LITELLM_VENV=/nonexistent/venv/litellm/bin/litellm \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
python3 "$canary" --quiet || fail "5b: canary organ-not-installed path must exit 0 (fail-open)"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 0' "$scratch/notinst.prom" \
    || fail "5b: not-installed prom missing proxy_up=0"
grep -q 'fleet_litellm_organ_installed 0' "$scratch/notinst.prom" \
    || fail "5b: not-installed prom missing organ_installed=0 (the absent() rule gate)"
ok "5b: canary fails open (exit 0) when the proxy organ is not installed"

# --- 5d: the Postgres probe must NOT rely on pg_isready's own defaults
# (fleet-ops#4174 reopen). Two live faults came from defaults:
#   a) no -h -> pg_isready probes /var/run/postgresql, which is not where
#      the fleet-owned cluster's user-owned socket lives;
#   b) no -d/-U -> pg_isready defaults to user=$USER database=$USER, which
#      logs 'FATAL: database "nish" does not exist' into the cluster every
#      60s and can exit non-zero on stricter configs.
# A stub pg_isready records its argv so both are asserted without needing a
# real cluster in CI.
stubbin="$scratch/pg_isready"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\nexit 0\n' "$scratch/pg.argv" > "$stubbin"
chmod +x "$stubbin"
rm -f "$scratch/pg.argv"
FLEET_LITELLM_PROM="$scratch/pg.prom" \
FLEET_LITELLM_STATE="$scratch/pg.state.json" \
FLEET_LITELLM_STUB="$simple_stub" \
FLEET_LITELLM_CONFIG="$scratch/simple-models.yaml" \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_PG_ISREADY="$stubbin" \
python3 "$canary" --quiet || fail "5d: canary with stub pg_isready must exit 0"
pgargv="$(tr '\n' ' ' <"$scratch/pg.argv")"
# Each argv item is written on its own line by the stub, so assert per token.
grep -qx -- '-h' "$scratch/pg.argv" \
    || fail "5d: pg probe must pass an explicit -h <socket dir>, got: $pgargv"
grep -qx -- '-d' "$scratch/pg.argv" \
    || fail "5d: pg probe must pass -d (not the \$USER database default), got: $pgargv"
grep -qx -- 'litellm' "$scratch/pg.argv" \
    || fail "5d: pg probe must name database/user litellm, got: $pgargv"
grep -qx -- '-U' "$scratch/pg.argv" \
    || fail "5d: pg probe must pass -U (not the \$USER default), got: $pgargv"
# The default host is the fleet-owned cluster's run dir, never the distro
# /var/run/postgresql (root:postgres-owned, unwritable by the cluster owner).
grep -qE '^/home/nish/\.local/share/fleet-litellm-postgres/run$' "$scratch/pg.argv" \
    || fail "5d: default pg host must be the fleet-owned cluster socket dir, got: $(tr '\n' ' ' <"$scratch/pg.argv")"
ok "5d: pg probe passes explicit -h/-d/-U (no pg_isready defaults)"

# --- 5e: the proxy unit must ExecStart the credential-resolving start
# wrapper, not a bare venv invocation. LiteLLM reads DATABASE_URL from the
# environment (not general_settings.database_url) and resolves keys via
# os.environ/<NAME>; a bare `litellm --config ...` therefore exits 3 at
# startup with Prisma P1012 — the exact failure that left the installed
# organ dead after #4337 (fleet-ops#4174 reopen). The wrapper itself is
# operator-installed (it sources secret-bearing env files) and is carried
# by docs/litellm-postgres-setup.md §3; this asserts the unit points at it.
proxy_unit="$repo_root/systemd/fleet-litellm-proxy.service"
grep -qE '^ExecStart=.*/fleet-litellm-proxy-start$' "$proxy_unit" \
    || fail "5e: $proxy_unit must ExecStart the fleet-litellm-proxy-start wrapper"
# The wrapper is a host-local binary, so the unit must invoke it through
# /usr/bin/env (a runner-safe first token). That keeps CI's unit-verify job
# green WITHOUT a Workflows-scope ci.yml stub: systemd-analyze only checks the
# first ExecStart token, and p14-unstubbed-unit-verify only flags a first
# token that is not a runner-safe bin. A bare `ExecStart=/home/nish/.local/...`
# would need the ci.yml stub workers cannot add (fleet-ops#4398).
grep -qE '^ExecStart=/usr/bin/env .*/fleet-litellm-proxy-start$' "$proxy_unit" \
    || fail "5e: $proxy_unit must ExecStart the wrapper via /usr/bin/env (runner-safe first token, no ci.yml stub needed)"
grep -q 'ConditionPathExists=%h/.config/fleet-ops/litellm-proxy.yaml' "$proxy_unit" \
    || fail "5e: proxy unit must gate on the operator config path"
# The runbook has to install that same wrapper, or a rebuild ships a unit
# whose ExecStart names a missing binary (conditionless instant death).
grep -q 'fleet-litellm-proxy-start' "$repo_root/docs/litellm-postgres-setup.md" \
    || fail "5e: docs/litellm-postgres-setup.md must carry the proxy start wrapper"
ok "5e: proxy unit ExecStarts the start wrapper via /usr/bin/env and the runbook installs it"

# --- 6: no real credential in the repo config (env-var references only)
cfg="$repo_root/config/litellm-proxy.yaml"
if grep -Eq 'sk-[A-Za-z0-9]{20,}' "$cfg"; then
    fail "6: config/litellm-proxy.yaml contains a real-looking sk- key (must be os.environ/ references)"
fi
# The resolver form LiteLLM actually supports. `command:` is NOT supported
# by litellm 1.98 (fleet-ops#4174 reopen), so the shape must not claim it.
grep -q 'api_key: os.environ/' "$cfg" \
    || fail "6: config must resolve keys via os.environ/<NAME>, not inline values"
if grep -q 'api_key: command:' "$cfg"; then
    fail "6: config must not use the unsupported api_key command: resolver form"
fi
# Every deployment names an env var rather than a literal secret.
bad_keys=$( { grep -E '^[[:space:]]*api_key:' "$cfg" | grep -vc 'os\.environ/'; } || true )
[[ "$bad_keys" = 0 ]] || fail "6: $bad_keys api_key line(s) are not os.environ/ references"
ok "6: config resolves keys via os.environ/ placeholders, no real key in repo"

# --- 7: organ-heartbeat gate passes on the live repo (every organ has its rule)
"$bin" verify >/tmp/litellm-organ-verify.out 2>&1 || {
    cat /tmp/litellm-organ-verify.out >&2
    fail "7: organ-heartbeat verify must pass on the live repo"
}
ok "7: organ-heartbeat verify passes on the live repo"

# --- 8: retired with the straitly seat (fleet-ops#4887, 2026-09-10).
# The straitly 402 credit-exhaustion bench-policy test is gone with the
# deployment; straitly was wiped (Nish: 402 credit exhausted, seat retired).

# --- 9: worker-capable must not dead-end the fallback chain (fleet-ops#4404)
# worker-cheap -> worker-capable used to dead-end at worker-capable (no
# fallback of its own -> "No fallback model group found"). Give worker-capable
# a terminal healthy route (senior) and let worker-cheap fall through it.
grep -qE '^\s*- worker-capable: \[senior\]$' "$cfg" \
    || fail "9: worker-capable must fall back to senior (terminal healthy group), got: no worker-capable fallback (fleet-ops#4404)"
grep -qE '^\s*- worker-cheap: \[worker-capable, senior\]$' "$cfg" \
    || fail "9: worker-cheap must fall through to senior after worker-capable (fleet-ops#4404)"
# Avoid a cheap<->capable ping-pong: worker-cheap must NOT fall back directly
# to another worker-cheap, and worker-capable must NOT loop back to worker-cheap.
if grep -qE 'worker-capable: \[worker-cheap\]' "$cfg"; then
    fail "9: fallback chain must not loop worker-capable back into worker-cheap (fleet-ops#4404)"
fi
ok "9: worker-capable has a terminal fallback (senior); worker-cheap chain no longer dead-ends"

# --- 10: grok-4.6 / xai-oauth deployments send the cli-chat-proxy identity
# headers (fleet-ops#4629). Live 2026-09-09 08:52 IST: LiteLLM's plain OpenAI
# client hit https://cli-chat-proxy.grok.com/v1/chat/completions with no
# x-grok-client-version and the proxy returned 426 "Your Grok CLI version
# (none) is outdated. Please update to version 0.1.202 or later". The same
# token with pi-grok's buildProxyHeaders (models.ts) returns 200. The floor
# is 0.1.202; the fleet stamps 0.2.101 to match fleet-seat-live-validate and
# the stnly/pi-grok GROK_CLIENT_VERSION default. extra_headers lives on
# litellm_params (LiteLLM docs.litellm.ai/docs/completion/input: extra_headers
# is an alternative to headers, forwarded as OpenAI extra_headers).
python3 - "$cfg" <<'PY' || fail "10: grok-4.6 / xai-oauth deployments must stamp cli-chat-proxy identity extra_headers (fleet-ops#4629)"
import sys, yaml

def parse_ver(s):
    parts = []
    for p in str(s).split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)

cfg = yaml.safe_load(open(sys.argv[1]))
needed = {
    "x-grok-client-identifier",
    "x-grok-client-version",
    "x-grok-client-mode",
    "X-XAI-Token-Auth",
    "x-authenticateresponse",
}
floor = parse_ver("0.1.202")
found = []
for d in cfg["model_list"]:
    params = d.get("litellm_params") or {}
    model = str(params.get("model") or "")
    base = str(params.get("api_base") or "")
    # xai-oauth / cli-chat-proxy only. cursor-grok-4.6-high is a Cursor
    # deployment and does not speak the grok CLI identity headers.
    is_grok = (
        model == "openai/grok-4.6"
        or "cli-chat-proxy" in base
        or "xai-oauth" in base
    )
    if not is_grok:
        continue
    found.append((d.get("model_name"), model, base))
    headers = params.get("extra_headers") or {}
    assert isinstance(headers, dict) and headers, (
        f"{d.get('model_name')} {model} @{base} missing litellm_params.extra_headers"
    )
    missing = needed - set(headers)
    assert not missing, (
        f"{d.get('model_name')} {model} extra_headers missing {sorted(missing)}"
    )
    ver = str(headers["x-grok-client-version"])
    assert parse_ver(ver) >= floor, (
        f"{d.get('model_name')} x-grok-client-version {ver!r} is below the proxy floor 0.1.202"
    )
    ua = headers.get("User-Agent") or headers.get("user-agent") or ""
    assert ua, f"{d.get('model_name')} extra_headers missing User-Agent"
    assert ver in ua, f"{d.get('model_name')} User-Agent {ua!r} must carry version {ver}"
# 2026-09-12: presence is a routing decision (grok was benched 403 / out of credits);
# the class this check pins (#4629) is header stamping WHEN a grok deployment is wired.
print(f"grok identity headers OK on {len(found)} deployment(s)" if found else "no grok deployment wired (benched) — header rule vacuously satisfied")
PY
ok "10: grok-4.6 / xai-oauth deployments stamp cli-chat-proxy identity extra_headers (fleet-ops#4629)"

# --- 11: empty /health census is held inside two health_check_intervals
# (fleet-ops#4628). Readiness can be healthy while GET /health returns
# healthy_endpoints=[] AND unhealthy_endpoints=[] (Prisma engine_process_death
# empties the background cache). That must log health-verdict-empty and
# must NOT pass as a green census.
printf '{"status":"healthy","db":"connected"}' > "$scratch/ready-ok.json"
printf '{"healthy_endpoints":[],"unhealthy_endpoints":[]}' > "$scratch/census-empty.json"
printf 'model_list:\n  - model_name: worker-cheap\n  - model_name: worker-capable\n' > "$scratch/models.yaml"
printf '{"empty_since": 1699999940, "proxy_up": 1}' > "$scratch/empty-hold.json"
FLEET_LITELLM_PROM="$scratch/empty-hold.prom" \
FLEET_LITELLM_STATE="$scratch/empty-hold.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH="$scratch/census-empty.json" \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_EMPTY_CENSUS_TOLERANCE_S=120 \
FLEET_LITELLM_NOW=1700000000 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" >"$scratch/empty-hold.out" 2>"$scratch/empty-hold.err" \
    || fail "11: empty census inside 120s must hold (exit 0)"
grep -q 'health-verdict-empty' "$scratch/empty-hold.err" "$scratch/empty-hold.out" \
    || fail "11: empty census must log health-verdict-empty, got: $(cat "$scratch/empty-hold.err" "$scratch/empty-hold.out")"
grep -q 'fleet_litellm_health_census 0' "$scratch/empty-hold.prom" \
    || fail "11: empty census prom missing fleet_litellm_health_census 0"
grep -q 'fleet_litellm_model_list_expected 2' "$scratch/empty-hold.prom" \
    || fail "11: empty census prom missing model_list_expected 2"
ok "11: empty /health census inside 120s holds and logs health-verdict-empty"

# --- 12: empty census past two health_check_intervals fails loud
printf '{"empty_since": 1699999800, "proxy_up": 1}' > "$scratch/empty-dead.json"
FLEET_LITELLM_PROM="$scratch/empty-dead.prom" \
FLEET_LITELLM_STATE="$scratch/empty-dead.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH="$scratch/census-empty.json" \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_EMPTY_CENSUS_TOLERANCE_S=120 \
FLEET_LITELLM_NOW=1700000000 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" >"$scratch/empty-dead.out" 2>"$scratch/empty-dead.err" \
    && fail "12: empty census past 120s must exit 1"
grep -q 'health-verdict-empty' "$scratch/empty-dead.err" "$scratch/empty-dead.out" \
    || fail "12: empty-past-tolerance must log health-verdict-empty"
ok "12: empty /health census past 120s exits 1 (canary no longer blind)"

# --- 13: unauthenticated /health (401) fails loud immediately
FLEET_LITELLM_PROM="$scratch/auth401.prom" \
FLEET_LITELLM_STATE="$scratch/auth401.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH_STATUS=401 \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" >"$scratch/auth401.out" 2>"$scratch/auth401.err" \
    && fail "13: /health 401 must exit 1"
grep -q 'health-auth-401' "$scratch/auth401.err" "$scratch/auth401.out" \
    || fail "13: 401 path must log health-auth-401, got: $(cat "$scratch/auth401.err" "$scratch/auth401.out")"
ok "13: GET /health 401 fails loud (canary must authenticate)"

# --- 14: populated census buckets by group and census == model_list
printf '{"healthy_endpoints":[{"model_info":{"model_name":"worker-cheap"}},{"model_info":{"model_name":"worker-capable"}}],"unhealthy_endpoints":[]}' > "$scratch/census-full.json"
FLEET_LITELLM_PROM="$scratch/census-full.prom" \
FLEET_LITELLM_STATE="$scratch/census-full.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH="$scratch/census-full.json" \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_NOW=1700000200 \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
python3 "$canary" --quiet || fail "14: populated census must exit 0"
grep -q 'fleet_litellm_health_census 2' "$scratch/census-full.prom" \
    || fail "14: populated census missing fleet_litellm_health_census 2"
grep -q 'fleet_litellm_model_list_expected 2' "$scratch/census-full.prom" \
    || fail "14: populated census missing model_list_expected 2"
grep -q 'fleet_litellm_proxy_healthy_deployments{group="worker-cheap"} 1' "$scratch/census-full.prom" \
    || fail "14: populated census must bucket worker-cheap from /health, not synthesise a proxy group"
ok "14: populated /health census == model_list and buckets by group"

# --- 15: Prisma 0.15 slotted client rejects _Prisma__engine; the compat
# hook writes through the _engine setter instead (fleet-ops#4628).
compat="$repo_root/libexec/fleet-litellm-prisma-compat/sitecustomize.py"
[[ -f "$compat" ]] || fail "15: missing prisma compat sitecustomize"
python3 - "$compat" <<'PY' || fail "15: prisma _engine setter patch must stop the slotted AttributeError"
import importlib.util, sys, types

compat = sys.argv[1]
spec = importlib.util.spec_from_file_location("fleet_litellm_prisma_compat", compat)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class SlottedPrisma:
    __slots__ = ("_internal_engine",)
    def __init__(self):
        self._internal_engine = None
    @property
    def _engine(self):
        return self._internal_engine
    @_engine.setter
    def _engine(self, engine):
        self._internal_engine = engine

client = SlottedPrisma()
try:
    client._Prisma__engine = object()
except AttributeError:
    pass
else:
    raise SystemExit("slotted Prisma unexpectedly accepted _Prisma__engine")

wrapper_mod = types.ModuleType("fake_prisma_client")
class PrismaWrapper:
    @staticmethod
    def _write_engine(prisma_client, engine):
        prisma_client._Prisma__engine = engine
wrapper_mod.PrismaWrapper = PrismaWrapper
assert mod.patch_write_engine(wrapper_mod) is True
engine = object()
wrapper_mod.PrismaWrapper._write_engine(client, engine)
assert client._internal_engine is engine, "patch must assign through _engine setter"
print("prisma engine setter OK")
PY
ok "15: prisma compat hook writes through _engine (slotted 0.15 no longer AttributeErrors)"

# --- 16: canary unit loads the master key env file so GET /health authenticates
canary_unit="$repo_root/systemd/fleet-litellm-health-canary.service"
grep -qE '^EnvironmentFile=-?/home/nish/.config/fleet-ops/litellm-master-key.env$' "$canary_unit" \
    || fail "16: canary unit must EnvironmentFile the operator master-key env (GET /health is auth-gated)"
grep -q 'PYTHONPATH=/home/nish/.local/libexec/fleet-litellm-prisma-compat' "$proxy_unit" \
    || fail "16: proxy unit must set PYTHONPATH to the prisma compat hook"
ok "16: canary authenticates /health; proxy loads prisma compat via PYTHONPATH"

# --- 17: the canary unit carries starvation headroom, not a 30s knife
# 2026-09-11: this unit was SIGTERMed at 30s during a memory-pressure stall
# having printed nothing and written no prom file (3.277s CPU vs 0.18s for a
# healthy run), so the trip carried no diagnosis and the organ heartbeat went
# dark. Measured worst case for a complete run is 70s (readiness 60s + pg 5s
# + redis 5s; readiness raised 10s->60s 2026-09-13, see the canary source).
# Assert the PROPERTY (generous headroom), not the exact number, so a later
# raise is not a red.
ts=$(grep -E '^TimeoutStartSec=' "$canary_unit" | tail -1 | cut -d= -f2)
case "$ts" in
    *min) ts_s=$(( ${ts%min} * 60 ));;
    *)    ts_s=${ts:-0};;
esac
[[ "$ts_s" -ge 90 ]] \
    || fail "17: canary unit TimeoutStartSec=$ts is under 90s starvation headroom (2026-09-11 trip: SIGTERM at 30s, nothing printed, no prom write)"
ok "17: canary unit carries >=90s starvation headroom (TimeoutStartSec=$ts)"

# --- 18: the loud deployment drill (fleet-ops#6054, #5792 accept line).
# #5792: "re-adding a dead deployment fails the health canary loudly". A
# populated census that still carries an UNHEALTHY deployment (the
# 2026-09-12 fault: 4x xkiro deepseek-v4-pro 503s deployed in the active
# groups, unhealthy_count=4, nobody noticed because organ liveness was
# green) must exit 1 with a named verdict. After the deployment is benched
# (census all-healthy) the same canary is a quiet 0.
printf '{"healthy_endpoints":[{"model_info":{"model_name":"worker-cheap"}}],"unhealthy_endpoints":[{"model_info":{"model_name":"senior"},"error":"litellm.ServiceUnavailableError: OpenAIException - A server error occurred. Please try again."}]}' > "$scratch/census-dead.json"
FLEET_LITELLM_PROM="$scratch/drill.prom" \
FLEET_LITELLM_STATE="$scratch/drill.state.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH="$scratch/census-dead.json" \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1700000300 \
python3 "$canary" >"$scratch/drill.out" 2>"$scratch/drill.err" \
    && fail "18: a deployed dead deployment must fail the canary loudly (fleet-ops#6054 drill), got exit 0"
grep -q 'health-deployment-unhealthy' "$scratch/drill.err" "$scratch/drill.out" \
    || fail "18: drill verdict must log health-deployment-unhealthy, got: $(cat "$scratch/drill.err" "$scratch/drill.out")"
grep -q 'fleet_litellm_proxy_unhealthy_deployments{group="senior"} 1' "$scratch/drill.prom" \
    || fail "18: prom must keep the unhealthy-deployment gauge scrapeable through the drill exit"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 1' "$scratch/drill.prom" \
    || fail "18: drill must NOT conceal organ liveness (proxy_up=1 stays exported)"
# 18b: the same deployment benched -> the census is all-healthy -> quiet 0.
printf '{"healthy_endpoints":[{"model_info":{"model_name":"worker-cheap"}},{"model_info":{"model_name":"senior"}}],"unhealthy_endpoints":[]}' > "$scratch/census-benched.json"
FLEET_LITELLM_PROM="$scratch/drill2.prom" \
FLEET_LITELLM_STATE="$scratch/drill2.state.json" \
FLEET_LITELLM_STUB="$scratch/ready-ok.json" \
FLEET_LITELLM_STUB_HEALTH="$scratch/census-benched.json" \
FLEET_LITELLM_CONFIG="$scratch/models.yaml" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1700000400 \
python3 "$canary" --quiet || fail "18b: all-healthy census after benching must stay quiet (exit 0)"
ok "18: deployed dead deployment fails the canary loudly (exit 1); benched, all-healthy census is a quiet 0"

echo "ALL OK: fleet-litellm-organ"
