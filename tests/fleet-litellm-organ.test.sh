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
grep -q 'metrics_path: /metrics' "$prom" || fail "3: prom litellm job must set metrics_path /metrics"
ok "3: prometheus has litellm scrape job at 127.0.0.1:4000/metrics"

# --- 4: MANIFEST installs every new file
for f in \
    "systemd/app-litellm.slice" \
    "systemd/app-litellm-postgres.slice" \
    "systemd/app-litellm-redis.slice" \
    "systemd/fleet-litellm-proxy.service" \
    "systemd/fleet-litellm-postgres.service" \
    "systemd/fleet-litellm-redis.service" \
    "config/litellm-proxy.yaml" \
    "libexec/fleet-litellm-health-canary.py" \
    "systemd/fleet-litellm-health-canary.service" \
    "systemd/fleet-litellm-health-canary.timer"; do
    grep -q "^$f " "$manifest" || fail "4: MANIFEST missing install line for $f"
done
ok "4: MANIFEST installs every new LiteLLM file"

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
# organ-dead path: connection refused -> exit 1, prom still written with proxy_up=0
FLEET_LITELLM_PROM="$scratch/dead.prom" \
FLEET_LITELLM_STATE="$scratch/dead.json" \
FLEET_LITELLM_PROXY_URL=http://127.0.0.1:1 \
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
# detailed endpoints format. The canary must still report proxy_up=1 and
# a synthesised "proxy" group with healthy=1.
simple_stub="$scratch/simple.json"
printf '{"status":"healthy","db":"connected"}' > "$simple_stub"
FLEET_LITELLM_PROM="$scratch/simple.prom" \
FLEET_LITELLM_STATE="$scratch/simple.json" \
FLEET_LITELLM_STUB="$simple_stub" \
FLEET_LITELLM_STUB_PG=1 \
FLEET_LITELLM_STUB_REDIS=1 \
FLEET_LITELLM_STUB_INSTALLED=1 \
FLEET_LITELLM_NOW=1700000100 \
python3 "$canary" --quiet || fail "5c: canary simple-format path must exit 0"
grep -q 'fleet_litellm_proxy_up{endpoint="readiness"} 1' "$scratch/simple.prom" \
    || fail "5c: simple-format prom missing proxy_up=1"
grep -q 'fleet_litellm_proxy_healthy_deployments{group="proxy"} 1' "$scratch/simple.prom" \
    || fail "5c: simple-format prom missing proxy group healthy=1"
ok "5c: canary handles LiteLLM simple readiness format (proxy group synthesised)"

ok "5: canary compiles, proxy_up=1 path exits 0, organ-dead path exits 1"

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

# --- 6: no real credential in the repo config (placeholders only)
cfg="$repo_root/config/litellm-proxy.yaml"
if grep -Eq 'sk-[A-Za-z0-9]{20,}' "$cfg"; then
    fail "6: config/litellm-proxy.yaml contains a real-looking sk- key (must be command: placeholders)"
fi
grep -q 'command:/home/nish/.local/bin/' "$cfg" \
    || fail "6: config must use command: resolver placeholders, not inline keys"
ok "6: config uses command: resolver placeholders, no real key in repo"

# --- 7: organ-heartbeat gate passes on the live repo (every organ has its rule)
"$bin" verify >/tmp/litellm-organ-verify.out 2>&1 || {
    cat /tmp/litellm-organ-verify.out >&2
    fail "7: organ-heartbeat verify must pass on the live repo"
}
ok "7: organ-heartbeat verify passes on the live repo"

echo "ALL OK: fleet-litellm-organ"
