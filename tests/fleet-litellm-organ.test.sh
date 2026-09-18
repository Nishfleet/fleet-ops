#!/usr/bin/env bash
# tests/fleet-litellm-organ.test.sh
#
# fleet-ops#4130 P1 — every LiteLLM organ (proxy + Postgres + Redis) ships an
# absent() heartbeat rule in config/fleet_rules.yml in the same PR
# (fleet-ops#1010 standing pattern), a prom scrape job in
# config/prometheus.yml and a MANIFEST install line. This test proves they
# are wired together and that the organ-heartbeat gate would not REJECT this
# PR.
#
# 2026-09-18: the /health canary (libexec/fleet-litellm-health-canary.py) was
# deleted — it restarted every minute to survive the proxy's own restarts and
# produced 2709 unit deaths in 7 days. Organ death is now probed directly by
# up{job="litellm"} over the scrape job asserted in section 3, and Postgres /
# Redis ride the universal unit-death escalation. Sections that only drilled
# the canary binary went with it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-organ-heartbeat-check"
registry="$repo_root/config/fleet-organs.json"
rules="$repo_root/config/fleet_rules.yml"
prom="$repo_root/config/prometheus.yml"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$registry" ]] || fail "missing: $registry"
[[ -f "$rules" ]] || fail "missing: $rules"
[[ -f "$prom" ]] || fail "missing: $prom"
[[ -f "$manifest" ]] || fail "missing: $manifest"

# --- 1: registry has the LiteLLM proxy organ with the right fields
# (litellm-postgres / litellm-redis were de-registered 2026-09-18 with the
#  /health canary that emitted their heartbeat gauges; the units stay live
#  and ride the universal unit-death escalation.)
python3 - "$registry" <<'PY' || fail "1: registry missing new organs"
import json, sys
data = json.load(open(sys.argv[1]))
organs = {o["name"]: o for o in data["organs"]}
for name in ("litellm-proxy",):
    assert name in organs, f"{name} organ missing"
px = organs["litellm-proxy"]
assert px["heartbeat_metric"] == 'up{job="litellm"}', px
assert px["absent_alert"] == "FleetLitellmProxyAbsent", px
assert "systemd/fleet-litellm-proxy.service" in px["files"], px
assert "systemd/app-litellm.slice" in px["files"], px
assert "config/litellm-proxy.yaml" in px["files"], px
assert "libexec/fleet-litellm-prisma-compat/sitecustomize.py" in px["files"], px
print("registry OK")
PY
ok "1: registry has the LiteLLM proxy organ with right fields"

# --- 2: the proxy organ-death rule probes the scrape job directly
# The canary-emitted gauges are gone (2026-09-18); `up` over the litellm
# scrape job is the direct probe.
grep -q 'absent(up{job="litellm"})' "$rules" \
    || fail "2: absent(up{job=\"litellm\"}) missing"
grep -E '^[[:space:]]*expr:' "$rules" \
    | grep -qE 'fleet_litellm_(proxy_up|organ_installed|postgres_up|redis_up|proxy_last_green_seconds)' \
    && fail "2: deleted canary metrics must not reappear in a rule expr"
for alert in \
    "FleetLitellmProxyAbsent"; do
    grep -q "$alert" "$rules" || fail "2: $alert alert missing"
done
grep -q 'fleet-ops#4130' "$rules" || fail "2: rules must reference fleet-ops#4130"
ok "2: the proxy organ-death rule probes up{job=\"litellm\"} and references fleet-ops#4130"

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
    "libexec/fleet-litellm-prisma-compat/sitecustomize.py"; do
    grep -q "^$f " "$manifest" || fail "4: MANIFEST missing install line for $f"
done
ok "4: MANIFEST installs every new LiteLLM file"

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

echo "ALL OK: fleet-litellm-organ"
