#!/usr/bin/env python3
"""fleet-litellm-health-canary — LiteLLM proxy /health census probe
(fleet-ops#4130 P1, fleet-ops#4628).

Polls the LiteLLM proxy at 127.0.0.1:4000/health/readiness every tick for
organ-liveness, then GET /health (master key) for the per-deployment
census. Exports:

  fleet_litellm_proxy_up{endpoint="readiness"} 1|0
  fleet_litellm_organ_installed 1|0
  fleet_litellm_proxy_healthy_deployments{group="..."} <count>
  fleet_litellm_proxy_unhealthy_deployments{group="..."} <count>
  fleet_litellm_health_census                         <healthy+unhealthy>
  fleet_litellm_model_list_expected                   <yaml model_list>
  fleet_litellm_proxy_last_green_seconds            <unix ts>
  fleet_litellm_postgres_up                          1|0
  fleet_litellm_redis_up                             1|0

The first is the organ heartbeat metric (config/fleet-organs.json
litellm-proxy entry); its absent() rule is FleetLitellmProxyAbsent.
fleet_litellm_postgres_up / fleet_litellm_redis_up are the postgres/redis
organ heartbeats (absent rules FleetLitellmPostgresAbsent /
FleetLitellmRedisAbsent). The last_green_seconds gauge is the canary
freshness gauge; its absent() rule is FleetLitellmHealthCanaryAbsent.

Postgres is probed via `pg_isready -q` (distro client); Redis via a
inline PING over a redis-cli subprocess. Both are optional: if the
binary is missing (organ not installed yet), the gauge is 0 and a
debug line is logged, NOT a fail-loud exit — the organ-absent alert
fires on the missing metric, not on this canary's exit code.

Fail-loud: if the proxy is continuously unreachable for FLEET_LITELLM_DEAD_TOLERANCE_S
seconds (default 60), exit 1 so the service lands in --state=failed and the global
service.d/10-escalate.conf drop-in climbs the ladder. A single connection-refused
tick is held (dead_since persisted in the state file) so a legitimate install/restart
window that gaps one 60s tick does not false-trip. A single 5xx is recorded as
proxy_up=0 but does NOT exit 1 (transient — the router's own cooldown handles it);
only sustained connection-refused (organ dead) exits 1.

Deployment drill (fleet-ops#6054, #5792 accept line: "re-adding a dead deployment
fails the health canary loudly"): a POPULATED census that still carries an
unhealthy deployment also exits 1, naming the affected groups
(health-deployment-unhealthy). Organ-up is not fleet-green: the 2026-09-12
unhealthy_count=4 (dead-credit xkiro deepseek-v4-pro deployed in the active
groups) starved the box while every organ heartbeat stayed 1. The prom and
state writes still land before the exit so the affected group gauge stays
scrapeable through the failure.

Empty-census fail-loud (fleet-ops#4628): GET /health with background_health_checks
returns the in-memory cache, which starts as {}. After a Prisma reconnect crash
(engine_process_death / '_Prisma__engine) the cache stays empty even while
completions return 200 and /health/readiness is healthy. That made this canary
blind. Once readiness is 200, the canary fetches /health (master key) and
asserts healthy_endpoints + unhealthy_endpoints is non-empty. An empty census
is held for FLEET_LITELLM_EMPTY_CENSUS_TOLERANCE_S seconds (default 120 = two
health_check_intervals) so a restart that has not yet finished its first
background cycle does not false-trip; after that window, exit 1.

No new scheduler for the proxy_up heartbeat: this canary runs on a 60s
timer (systemd/fleet-litellm-health-canary.timer) because the proxy is a
daemon whose death must surface in <2 min, not on the 5-min
metrics-export cadence. The 60s timer is the named reason (organ-death
latency).

Stdlib only. No git, no GitHub writes.

Environment seams (tests):
  FLEET_LITELLM_PROXY_URL   default http://127.0.0.1:4000
  FLEET_LITELLM_PROM        prom textfile path
  FLEET_LITELLM_STATE       state json path
  FLEET_LITELLM_NOW         fixed now for tests
  FLEET_LITELLM_TIMEOUT_S   per-request timeout
  FLEET_LITELLM_STUB        path to a stub JSON response (tests; used for both
                            /health/readiness and /health unless STUB_HEALTH is set)
  FLEET_LITELLM_STUB_HEALTH path to a stub JSON /health census (tests)
  FLEET_LITELLM_STUB_COMPLETIONS  path to a stub (any file) making the 1-token
                            /chat/completions hang-probe answer 200 (tests; #6315)
  FLEET_LITELLM_COMPLETIONS_MODEL model id for the hang-probe completion
                            (default: first - model_name: in FLEET_LITELLM_CONFIG,
                            else worker-cheap)
  FLEET_LITELLM_MASTER_KEY  proxy master key for GET /health (never logged)
  FLEET_LITELLM_MASTER_KEY_FILE path to KEY=value env file carrying the master key
  FLEET_LITELLM_CONFIG      live yaml (model_list expected count)
  FLEET_LITELLM_EMPTY_CENSUS_TOLERANCE_S  hold window for empty /health (default 120)
  FLEET_LITELLM_PG_ISREADY  pg_isready binary (default searched on PATH)
  FLEET_LITELLM_REDIS_CLI   redis-cli binary (default searched on PATH)
  FLEET_LITELLM_PG_HOST     postgres host or socket dir (default the
                            fleet-owned cluster's own run dir;
                            pg_isready defaults to /var/run/postgresql,
                            which is root:postgres-owned and unwritable by
                            the user running the cluster)
  FLEET_LITELLM_PG_PORT     postgres port (default 5432)
  FLEET_LITELLM_PG_DB       postgres database name (default litellm)
  FLEET_LITELLM_PG_USER     postgres user name (default litellm)
  FLEET_LITELLM_REDIS_HOST  redis host (default 127.0.0.1)
  FLEET_LITELLM_REDIS_PORT  redis port (default 6379)
  FLEET_LITELLM_STUB_PG     "1" forces postgres_up=1 (tests)
  FLEET_LITELLM_STUB_REDIS  "1" forces redis_up=1 (tests)
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_PROXY_URL = os.environ.get("FLEET_LITELLM_PROXY_URL", "http://127.0.0.1:4000")
# The proxy organ's live install is Nish-gated (fleet-ops#4174 P1: "paper +
# installable units, NOT a live deploy"). The venv is the definitive install
# marker (the proxy unit's ExecStart runs this binary). When it is absent the
# organ is NOT installed yet, so the canary must fail-open (exit 0) rather than
# fail-loud on connection-refused — the proxy is legitimately absent, not dead.
DEFAULT_VENV = os.environ.get(
    "FLEET_LITELLM_VENV", "/home/nish/.local/venvs/litellm/bin/litellm"
)
DEFAULT_PROM = Path(
    os.environ.get("FLEET_LITELLM_PROM", "/var/lib/prometheus/node-exporter/fleet-litellm-health.prom")
)
DEFAULT_STATE = Path(
    os.environ.get("FLEET_LITELLM_STATE", "/home/nish/workspaces/agent-state/litellm/health.json")
)
DEFAULT_TIMEOUT_S = float(os.environ.get("FLEET_LITELLM_TIMEOUT_S", "10"))
# Fail-loud only after the proxy has been continuously unreachable this long.
# A single connection-refused tick can hit a legitimate restart window (the
# proxy organ is a live daemon whose install/restart gaps ~one 60s tick, e.g.
# the fleet-ops#4130 worker restarting organs to pick up config, or an
# event-loop wedge under a burst), so we hold through that window and only
# climb the escalation ladder on sustained death (<=2 min at the 60s default,
# honoring the unit's named '<2 min' reason).
DEFAULT_DEAD_TOLERANCE_S = float(os.environ.get("FLEET_LITELLM_DEAD_TOLERANCE_S", "60"))
# Two health_check_intervals (config default 60s) so a just-restarted proxy
# can finish its first background cycle before the empty-census fail-loud.
DEFAULT_EMPTY_CENSUS_TOLERANCE_S = float(
    os.environ.get("FLEET_LITELLM_EMPTY_CENSUS_TOLERANCE_S", "120")
)
DEFAULT_MASTER_KEY_FILE = os.environ.get(
    "FLEET_LITELLM_MASTER_KEY_FILE",
    "/home/nish/.config/fleet-ops/litellm-master-key.env",
)
DEFAULT_CONFIG = os.environ.get(
    "FLEET_LITELLM_CONFIG",
    "/home/nish/.config/fleet-ops/litellm-proxy.yaml",
)
DEFAULT_PG_HOST = os.environ.get(
    "FLEET_LITELLM_PG_HOST",
    "/home/nish/.local/share/fleet-litellm-postgres/run",
)
DEFAULT_PG_PORT = os.environ.get("FLEET_LITELLM_PG_PORT", "5432")
DEFAULT_REDIS_HOST = os.environ.get("FLEET_LITELLM_REDIS_HOST", "127.0.0.1")
DEFAULT_REDIS_PORT = os.environ.get("FLEET_LITELLM_REDIS_PORT", "6379")


def _atomic_write(path: Path, text: str, *, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    os.chmod(path, mode)


def _load_state(path: Path) -> dict[str, Any]:
    """Load the previous tick's state json (may be absent on first run)."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _organ_installed(venv: str) -> bool:
    """True if the LiteLLM proxy organ is installed (venv present).

    When the organ is not installed (Nish-gated live install not yet done), the
    canary must NOT fail loud on connection-refused — the proxy is legitimately
    absent, not dead. This mirrors the postgres/redis probes, which already
    treat a missing binary as "organ not installed" (gauge 0, no fail-loud).
    When Nish installs the venv, this canary automatically resumes fail-loud on
    real organ death — no re-arming needed.
    """
    if os.environ.get("FLEET_LITELLM_STUB_INSTALLED") == "1":
        return True
    return Path(venv).is_file()


def _now() -> float:
    fixed = os.environ.get("FLEET_LITELLM_NOW")
    if fixed:
        try:
            return float(fixed)
        except ValueError:
            pass
    return time.time()


def _fetch(
    url: str,
    timeout: float,
    *,
    headers: dict[str, str] | None = None,
    kind: str = "readiness",
) -> tuple[int, str]:
    """Return (status_code, body). status_code=0 means connection failed.

    kind=readiness uses FLEET_LITELLM_STUB. kind=health prefers
    FLEET_LITELLM_STUB_HEALTH, then STUB, and honours
    FLEET_LITELLM_STUB_HEALTH_STATUS for the 401 path (fleet-ops#4628).
    """
    if kind == "health":
        status_raw = os.environ.get("FLEET_LITELLM_STUB_HEALTH_STATUS")
        if status_raw:
            try:
                return int(status_raw), ""
            except ValueError:
                return 0, ""
        stub = os.environ.get("FLEET_LITELLM_STUB_HEALTH") or os.environ.get("FLEET_LITELLM_STUB")
    else:
        stub = os.environ.get("FLEET_LITELLM_STUB")
    if stub:
        p = Path(stub)
        if not p.is_file():
            return 0, ""
        with p.open(encoding="utf-8") as fh:
            return 200, fh.read()
    hdrs = {"Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    try:
        req = urllib.request.Request(url, headers=hdrs)
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosem: dynamic-urllib-use-detected
            return int(resp.status), resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return int(e.code), e.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return 0, ""


def _endpoint_group_name(ep: Any) -> str:
    if isinstance(ep, dict):
        mi = ep.get("model_info") or {}
        name = (mi.get("model_name") if isinstance(mi, dict) else None) or ep.get("model")
        if name:
            return str(name)
    return "unknown"


def _parse_census(body: str) -> tuple[dict[str, dict[str, int]], int]:
    """Parse GET /health. Empty lists are a blind verdict, not 'all healthy'.

    Never synthesise a proxy group from {"status":"healthy"}. That is what
    made the canary blind after a Prisma engine_process_death (fleet-ops#4628).
    """
    try:
        doc = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return {}, 0
    if not isinstance(doc, dict):
        return {}, 0
    healthy_eps = doc.get("healthy_endpoints") or []
    unhealthy_eps = doc.get("unhealthy_endpoints") or []
    if not isinstance(healthy_eps, list):
        healthy_eps = []
    if not isinstance(unhealthy_eps, list):
        unhealthy_eps = []
    out: dict[str, dict[str, int]] = {}
    for ep in healthy_eps:
        g = out.setdefault(_endpoint_group_name(ep), {"healthy": 0, "unhealthy": 0})
        g["healthy"] += 1
    for ep in unhealthy_eps:
        g = out.setdefault(_endpoint_group_name(ep), {"healthy": 0, "unhealthy": 0})
        g["unhealthy"] += 1
    return out, len(healthy_eps) + len(unhealthy_eps)


def _first_model_name(path: str) -> str:
    """First `- model_name:` entry in the live yaml, or '' (none)."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return ""
    for line in text.splitlines():
        if line.lstrip().startswith("- model_name:"):
            return line.split("model_name:", 1)[1].strip()
    return ""


def _probe_completion(proxy_url: str, timeout: float) -> int:
    """HTTP status of one 1-token /chat/completions, 0 when unanswered.

    fleet-ops#6315: the 2026-09-13 incident had /health/readiness 0-byte
    timing out 20s+ under the 40-worker load while POST /chat/completions
    returned 200 -- the /health fan-out wedges the event loop, the product
    path does not. A hung readiness therefore proves nothing on its own;
    one completion proves the daemon alive. Model resolution:
    FLEET_LITELLM_COMPLETIONS_MODEL, else the first - model_name: in the
    live config, else the literal worker-cheap. The completion costs 1
    token and never logs its (secret-free) reply; the master key is read,
    never printed.
    """
    stub = os.environ.get("FLEET_LITELLM_STUB_COMPLETIONS")
    if stub:
        if not Path(stub).is_file():
            return 0
        return 200
    model = (
        os.environ.get("FLEET_LITELLM_COMPLETIONS_MODEL", "")
        or _first_model_name(os.environ.get("FLEET_LITELLM_CONFIG", DEFAULT_CONFIG))
        or "worker-cheap"
    )
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if not _health_fetch_is_stubbed():
        master_key = _load_master_key()
        if master_key:
            headers["Authorization"] = "Bearer " + master_key
    try:
        req = urllib.request.Request(
            proxy_url.rstrip("/") + "/chat/completions",
            data=json.dumps(
                {"model": model, "messages": [{"role": "user", "content": "ping"}], "max_completion_tokens": 1}
            ).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosem: dynamic-urllib-use-detected
            resp.read()
            return int(resp.status)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return 0


def _count_model_list(path: str) -> int:
    """Count `- model_name:` entries in the live yaml. Stdlib only."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return 0
    return sum(1 for line in text.splitlines() if line.lstrip().startswith("- model_name:"))


def _load_master_key() -> str:
    """Return the proxy master key. Never log the value."""
    for name in ("FLEET_LITELLM_MASTER_KEY", "LITELLM_MASTER_KEY"):
        raw = os.environ.get(name)
        if raw:
            return raw.strip().strip('"').strip("'")
    path = Path(os.environ.get("FLEET_LITELLM_MASTER_KEY_FILE", DEFAULT_MASTER_KEY_FILE))
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            if key.strip() in ("LITELLM_MASTER_KEY", "FLEET_LITELLM_MASTER_KEY"):
                return value.strip().strip('"').strip("'")
    except OSError:
        return ""
    return ""


def _health_fetch_is_stubbed() -> bool:
    return bool(
        os.environ.get("FLEET_LITELLM_STUB_HEALTH_STATUS")
        or os.environ.get("FLEET_LITELLM_STUB_HEALTH")
        or os.environ.get("FLEET_LITELLM_STUB")
    )


def _probe_postgres(pg_host: str = DEFAULT_PG_HOST) -> int:
    """1 if pg_isready succeeds, 0 otherwise. Missing binary -> 0 (organ absent).

    Connects as user=litellm to database=litellm — the fleet-owned cluster
    only has that role/database. The pg_isready defaults (user=nish,
    database=nish) produce FATAL log spam every tick and could return a
    false-negative exit code on stricter Postgres configs (fleet-ops#4174
    reopen: 'FATAL: database "nish" does not exist' every 60s).
    """
    if os.environ.get("FLEET_LITELLM_STUB_PG") == "1":
        return 1
    bin_name = os.environ.get("FLEET_LITELLM_PG_ISREADY", "pg_isready")
    pg_bin = shutil.which(bin_name) if "/" not in bin_name else bin_name
    if not pg_bin:
        return 0
    pg_db = os.environ.get("FLEET_LITELLM_PG_DB", "litellm")
    pg_user = os.environ.get("FLEET_LITELLM_PG_USER", "litellm")
    try:
        r = subprocess.run(
            [pg_bin, "-q", "-h", pg_host, "-d", pg_db, "-U", pg_user],
            capture_output=True,
            timeout=5,
        )
        return 1 if r.returncode == 0 else 0
    except (subprocess.TimeoutExpired, OSError):
        return 0


def _probe_redis(host: str, port: str) -> int:
    """1 if redis-cli PING returns PONG, 0 otherwise. Missing binary -> 0."""
    if os.environ.get("FLEET_LITELLM_STUB_REDIS") == "1":
        return 1
    bin_name = os.environ.get("FLEET_LITELLM_REDIS_CLI", "redis-cli")
    rd_bin = shutil.which(bin_name) if "/" not in bin_name else bin_name
    if not rd_bin:
        return 0
    try:
        r = subprocess.run(
            [rd_bin, "-h", host, "-p", str(port), "PING"],
            capture_output=True,
            timeout=5,
            text=True,
        )
        return 1 if r.returncode == 0 and r.stdout.strip() == "PONG" else 0
    except (subprocess.TimeoutExpired, OSError):
        return 0


def render_prom(
    now: float,
    proxy_up: int,
    groups: dict[str, dict[str, int]],
    pg_up: int,
    redis_up: int,
    organ_installed: int,
    census_n: int = 0,
    expected_n: int = 0,
) -> str:
    lines: list[str] = []
    lines.append(f'# HELP fleet_litellm_proxy_up 1 if /health/readiness returned 200, 0 on 5xx, absent if organ dead')
    lines.append('# TYPE fleet_litellm_proxy_up gauge')
    lines.append(f'fleet_litellm_proxy_up{{endpoint="readiness"}} {int(proxy_up)}')
    lines.append('# HELP fleet_litellm_organ_installed 1 if the proxy organ venv is present, 0 if not (Nish-gated live install not done). Gates the absent() rules so a deliberately-uninstalled organ does not fire them (fleet-ops#4221).')
    lines.append('# TYPE fleet_litellm_organ_installed gauge')
    lines.append(f'fleet_litellm_organ_installed {int(organ_installed)}')
    lines.append('# HELP fleet_litellm_proxy_healthy_deployments count of healthy deployments per model group')
    lines.append('# TYPE fleet_litellm_proxy_healthy_deployments gauge')
    lines.append('# HELP fleet_litellm_proxy_unhealthy_deployments count of unhealthy deployments per model group')
    lines.append('# TYPE fleet_litellm_proxy_unhealthy_deployments gauge')
    for gname, counts in sorted(groups.items()):
        glabel = gname.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'fleet_litellm_proxy_healthy_deployments{{group="{glabel}"}} {counts.get("healthy", 0)}')
        lines.append(f'fleet_litellm_proxy_unhealthy_deployments{{group="{glabel}"}} {counts.get("unhealthy", 0)}')
    lines.append('# HELP fleet_litellm_health_census healthy_endpoints + unhealthy_endpoints from GET /health')
    lines.append('# TYPE fleet_litellm_health_census gauge')
    lines.append(f'fleet_litellm_health_census {int(census_n)}')
    lines.append('# HELP fleet_litellm_model_list_expected count of - model_name: entries in the live yaml')
    lines.append('# TYPE fleet_litellm_model_list_expected gauge')
    lines.append(f'fleet_litellm_model_list_expected {int(expected_n)}')
    lines.append('# HELP fleet_litellm_postgres_up 1 if pg_isready succeeded, 0 otherwise, absent if organ not installed')
    lines.append('# TYPE fleet_litellm_postgres_up gauge')
    lines.append(f'fleet_litellm_postgres_up {int(pg_up)}')
    lines.append('# HELP fleet_litellm_redis_up 1 if redis-cli PING returned PONG, 0 otherwise, absent if organ not installed')
    lines.append('# TYPE fleet_litellm_redis_up gauge')
    lines.append(f'fleet_litellm_redis_up {int(redis_up)}')
    lines.append('# HELP fleet_litellm_proxy_last_green_seconds unix ts of last proxy_up=1 tick')
    lines.append('# TYPE fleet_litellm_proxy_last_green_seconds gauge')
    if proxy_up == 1:
        lines.append(f'fleet_litellm_proxy_last_green_seconds {int(now)}')
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    p.add_argument("--proxy-url", default=DEFAULT_PROXY_URL)
    p.add_argument("--prom", default=str(DEFAULT_PROM))
    p.add_argument("--state", default=str(DEFAULT_STATE))
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    p.add_argument("--dead-tolerance", type=float, default=DEFAULT_DEAD_TOLERANCE_S)
    p.add_argument(
        "--empty-census-tolerance",
        type=float,
        default=DEFAULT_EMPTY_CENSUS_TOLERANCE_S,
    )
    p.add_argument("--venv", default=DEFAULT_VENV)
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)

    now = _now()

    # Fail-open when the organ is not installed (Nish-gated live install not yet
    # done). Write the prom file with the metrics present at 0, export
    # fleet_litellm_organ_installed=0, and exit 0 — do NOT fail loud. The
    # absent() rules are gated on the organ being installed via
    # `unless fleet_litellm_organ_installed == 0` (fleet-ops#4174 P1: paper, not
    # live deploy), so a deliberately-uninstalled organ stays silent and the
    # canary keeps a live liveness signal (proxy_up=0 present). When Nish
    # installs the venv, organ_installed flips to 1 and this canary resumes
    # fail-loud on real organ death.
    if not _organ_installed(args.venv):
        pg_up = _probe_postgres()
        redis_up = _probe_redis(DEFAULT_REDIS_HOST, DEFAULT_REDIS_PORT)
        _atomic_write(Path(args.prom), render_prom(now, 0, {}, pg_up, redis_up, 0))
        if not args.quiet:
            print(
                "fleet-litellm-health-canary: proxy organ not installed "
                f"(venv {args.venv} missing) — skip, no fail-loud",
                file=sys.stderr,
            )
        return 0

    url = args.proxy_url.rstrip("/") + "/health/readiness"
    status, _ready_body = _fetch(url, args.timeout)

    pg_up = _probe_postgres()
    redis_up = _probe_redis(DEFAULT_REDIS_HOST, DEFAULT_REDIS_PORT)

    if status == 0:
        # Organ unanswered. fleet-ops#6315: a health-only hang is not organ
        # death — the 2026-09-13 incident had readiness+health 0-byte
        # timing out for 120s+ while completions 200'd. One 1-token
        # completion answering 200 proves the daemon alive: hold, prom
        # written proxy_up=0 (readiness did not answer — honest), NO dead
        # latch, exit 0, for as long as the product path answers. The
        # /health census question stays unasked during the hang (it is
        # exactly what wedged); it resumes on the next 200-tick, with a
        # fresh empty-census hold, same as any post-restart window. When
        # the completion ALSO fails (true death / restart window — a
        # connection-refused organ cannot answer), the existing
        # dead-tolerance latch below applies unchanged.
        c_status = _probe_completion(args.proxy_url, args.timeout)
        if c_status == 200:
            _atomic_write(Path(args.prom), render_prom(now, 0, {}, pg_up, redis_up, 1))
            _atomic_write(
                Path(args.state),
                json.dumps(
                    {
                        "now": int(now),
                        "proxy_up": 0,
                        "status": 0,
                        "completions_status": 200,
                        "completions_ok": True,
                        "groups": {},
                        "postgres_up": pg_up,
                        "redis_up": redis_up,
                        "dead_since": None,
                        "empty_since": None,
                    },
                    indent=2,
                    sort_keys=True,
                ),
            )
            if not args.quiet:
                print(
                    f"fleet-litellm-health-canary: health-hang readiness unanswered at {url} "
                    f"but completions 200 — organ alive, not a death; holding (fail-open, fleet-ops#6315)",
                    file=sys.stderr,
                )
            return 0
        # Existing path: connection refused / fully starved. Hold through a
        # single-tick restart window (dead_since persisted in the state
        # file), and only fail loud once continuously unreachable for
        # --dead-tolerance seconds. The prom file is still written
        # proxy_up=0 immediately so the freshness/absent rules surface real
        # death even mid-window.
        state = _load_state(args.state)
        dead_since = state.get("dead_since")
        if not isinstance(dead_since, (int, float)):
            dead_since = now
        elapsed = now - float(dead_since)
        _atomic_write(Path(args.prom), render_prom(now, 0, {}, pg_up, redis_up, 1))
        state.update(
            {
                "now": int(now),
                "proxy_up": 0,
                "status": 0,
                "completions_status": c_status,
                "completions_ok": False,
                "groups": {},
                "postgres_up": pg_up,
                "redis_up": redis_up,
                "dead_since": int(dead_since),
            }
        )
        _atomic_write(Path(args.state), json.dumps(state, indent=2, sort_keys=True))
        if elapsed >= args.dead_tolerance:
            if not args.quiet:
                print(
                    f"fleet-litellm-health-canary: proxy unreachable at {url} "
                    f"for {int(elapsed)}s >= {int(args.dead_tolerance)}s (organ dead)",
                    file=sys.stderr,
                )
            return 1
        if not args.quiet:
            print(
                f"fleet-litellm-health-canary: proxy unreachable at {url} "
                f"(dead {int(elapsed)}s < {int(args.dead_tolerance)}s tolerance, "
                f"likely restart window — holding)",
                file=sys.stderr,
            )
        return 0

    proxy_up = 1 if status == 200 else 0
    groups: dict[str, dict[str, int]] = {}
    census_n = 0
    expected_n = _count_model_list(os.environ.get("FLEET_LITELLM_CONFIG", DEFAULT_CONFIG))
    census_status = 0

    if proxy_up:
        health_url = args.proxy_url.rstrip("/") + "/health"
        health_headers: dict[str, str] | None = None
        if not _health_fetch_is_stubbed():
            master_key = _load_master_key()
            if not master_key:
                census_status = 401
            else:
                health_headers = {"Authorization": "Bearer " + master_key}
        if census_status != 401:
            census_status, census_body = _fetch(
                health_url, args.timeout, headers=health_headers, kind="health"
            )
        else:
            census_body = ""
        if census_status == 401:
            _atomic_write(
                Path(args.prom),
                render_prom(now, proxy_up, {}, pg_up, redis_up, 1, 0, expected_n),
            )
            state = {
                "now": int(now),
                "proxy_up": proxy_up,
                "status": status,
                "census_status": 401,
                "groups": {},
                "census": 0,
                "expected": expected_n,
                "postgres_up": pg_up,
                "redis_up": redis_up,
                "dead_since": None,
                "empty_since": None,
            }
            _atomic_write(Path(args.state), json.dumps(state, indent=2, sort_keys=True))
            print(
                "fleet-litellm-health-canary: health-auth-401 GET /health needs the master key",
                file=sys.stderr,
            )
            return 1
        if census_status == 200:
            groups, census_n = _parse_census(census_body)
        if census_n == 0:
            state = _load_state(args.state)
            empty_since = state.get("empty_since")
            if not isinstance(empty_since, (int, float)):
                empty_since = now
            elapsed = now - float(empty_since)
            _atomic_write(
                Path(args.prom),
                render_prom(now, proxy_up, {}, pg_up, redis_up, 1, 0, expected_n),
            )
            state.update(
                {
                    "now": int(now),
                    "proxy_up": proxy_up,
                    "status": status,
                    "census_status": census_status,
                    "groups": {},
                    "census": 0,
                    "expected": expected_n,
                    "postgres_up": pg_up,
                    "redis_up": redis_up,
                    "dead_since": None,
                    "empty_since": int(empty_since),
                }
            )
            _atomic_write(Path(args.state), json.dumps(state, indent=2, sort_keys=True))
            msg = (
                "fleet-litellm-health-canary: health-verdict-empty "
                f"census=0 expected={expected_n} "
                f"held={int(elapsed)}s tolerance={int(args.empty_census_tolerance)}s"
            )
            if elapsed >= args.empty_census_tolerance:
                print(msg, file=sys.stderr)
                return 1
            if not args.quiet:
                print(msg, file=sys.stderr)
            return 0

    _atomic_write(
        Path(args.prom),
        render_prom(now, proxy_up, groups, pg_up, redis_up, 1, census_n, expected_n),
    )

    state = {
        "now": int(now),
        "proxy_up": proxy_up,
        "status": status,
        "census_status": census_status,
        "groups": groups,
        "census": census_n,
        "expected": expected_n,
        "postgres_up": pg_up,
        "redis_up": redis_up,
        "dead_since": None,
        "empty_since": None,
    }
    _atomic_write(Path(args.state), json.dumps(state, indent=2, sort_keys=True))

    # Deployment drill (fleet-ops#6054, #5792 accept line): a populated census
    # with ANY unhealthy deployment fails loud — organ-up is not fleet-green.
    # prom + state are already written, so the affected group gauge
    # (fleet_litellm_proxy_unhealthy_deployments) is scrapeable through the
    # failure. The connection-refused / 401 / empty-census exits returned
    # above; this is the remaining verdict of a fully-fetched, populated
    # census.
    unhealthy_groups = sorted(
        name for name, counts in groups.items() if counts.get("unhealthy", 0)
    )
    if unhealthy_groups:
        print(
            "fleet-litellm-health-canary: health-deployment-unhealthy "
            + ",".join(unhealthy_groups)
            + " — deployment(s) failing /health still deployed in the active"
            " groups; bench them (fleet-ops#6054 drill, #5792 accept line)",
            file=sys.stderr,
        )
        return 1

    if not args.quiet:
        print(
            f"fleet-litellm-health-canary: proxy_up={proxy_up} status={status} "
            f"census={census_n} expected={expected_n} groups={len(groups)} "
            f"pg_up={pg_up} redis_up={redis_up}"
        )
    # A 5xx on readiness is transient (router cooldown handles it); do not exit 1.
    # Connection-refused (status==0), /health 401, a sustained empty census, and
    # (above) any unhealthy deployment in a populated census exit 1.
    return 0


if __name__ == "__main__":
    sys.exit(main())
