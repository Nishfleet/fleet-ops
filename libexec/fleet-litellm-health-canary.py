#!/usr/bin/env python3
"""fleet-litellm-health-canary — LiteLLM proxy /health/readiness probe
(fleet-ops#4130 P1).

Polls the LiteLLM proxy at 127.0.0.1:4000/health/readiness every tick and
exports:

  fleet_litellm_proxy_up{endpoint="readiness"} 1|0
  fleet_litellm_organ_installed 1|0
  fleet_litellm_proxy_healthy_deployments{group="..."} <count>
  fleet_litellm_proxy_unhealthy_deployments{group="..."} <count>
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
  FLEET_LITELLM_STUB        path to a stub JSON response (tests)
  FLEET_LITELLM_PG_ISREADY  pg_isready binary (default searched on PATH)
  FLEET_LITELLM_REDIS_CLI   redis-cli binary (default searched on PATH)
  FLEET_LITELLM_PG_HOST     postgres host (default /var/run/postgresql)
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
# the fleet-ops#4130 worker restarting organs to pick up config), so we hold
# through that window and only climb the escalation ladder on sustained death
# (<=2 min at the 60s default, honoring the unit's named '<2 min' reason).
DEFAULT_DEAD_TOLERANCE_S = float(os.environ.get("FLEET_LITELLM_DEAD_TOLERANCE_S", "60"))
DEFAULT_PG_HOST = os.environ.get(
    "FLEET_LITELLM_PG_HOST", "/home/nish/.local/share/fleet-litellm-postgres/run"
)
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


def _fetch(url: str, timeout: float) -> tuple[int, str]:
    """Return (status_code, body). status_code=0 means connection failed."""
    stub = os.environ.get("FLEET_LITELLM_STUB")
    if stub:
        p = Path(stub)
        if not p.is_file():
            return 0, ""
        with p.open(encoding="utf-8") as fh:
            return 200, fh.read()
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosem: dynamic-urllib-use-detected
            return int(resp.status), resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return int(e.code), e.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
        return 0, ""


def _parse_readiness(body: str) -> dict[str, Any]:
    """Parse /health/readiness response. Returns {group: {healthy: n, unhealthy: n}}.
    LiteLLM /health/readiness returns {"healthy_endpoints": [...], "unhealthy_endpoints": [...]}.
    Each endpoint carries model_info; we bucket by model_name (the group alias)."""
    try:
        doc = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return {}
    out: dict[str, dict[str, int]] = {}
    for ep in doc.get("healthy_endpoints", []) or []:
        name = "unknown"
        if isinstance(ep, dict):
            mi = ep.get("model_info") or {}
            name = (mi.get("model_name") if isinstance(mi, dict) else None) or ep.get("model") or "unknown"
        g = out.setdefault(str(name), {"healthy": 0, "unhealthy": 0})
        g["healthy"] += 1
    for ep in doc.get("unhealthy_endpoints", []) or []:
        name = "unknown"
        if isinstance(ep, dict):
            mi = ep.get("model_info") or {}
            name = (mi.get("model_name") if isinstance(mi, dict) else None) or ep.get("model") or "unknown"
        g = out.setdefault(str(name), {"healthy": 0, "unhealthy": 0})
        g["unhealthy"] += 1
    return out


def _probe_postgres(pg_host: str) -> int:
    """1 if pg_isready succeeds, 0 otherwise. Missing binary -> 0 (organ absent)."""
    if os.environ.get("FLEET_LITELLM_STUB_PG") == "1":
        return 1
    bin_name = os.environ.get("FLEET_LITELLM_PG_ISREADY", "pg_isready")
    pg_bin = shutil.which(bin_name) if "/" not in bin_name else bin_name
    if not pg_bin:
        return 0
    try:
        r = subprocess.run(
            [pg_bin, "-q", "-h", pg_host],
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
        pg_up = _probe_postgres(DEFAULT_PG_HOST)
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
    status, body = _fetch(url, args.timeout)

    pg_up = _probe_postgres(DEFAULT_PG_HOST)
    redis_up = _probe_redis(DEFAULT_REDIS_HOST, DEFAULT_REDIS_PORT)

    if status == 0:
        # Organ unreachable — connection refused. Hold through a single-tick
        # restart window (dead_since persisted in the state file), and only
        # fail loud once continuously unreachable for --dead-tolerance
        # seconds. The prom file is still written proxy_up=0 immediately so
        # the freshness/absent rules surface real death even mid-window.
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
    groups = _parse_readiness(body) if proxy_up else {}

    _atomic_write(Path(args.prom), render_prom(now, proxy_up, groups, pg_up, redis_up, 1))

    state = {
        "now": int(now),
        "proxy_up": proxy_up,
        "status": status,
        "groups": groups,
        "postgres_up": pg_up,
        "redis_up": redis_up,
        "dead_since": None,
    }
    _atomic_write(Path(args.state), json.dumps(state, indent=2, sort_keys=True))

    if not args.quiet:
        print(
            f"fleet-litellm-health-canary: proxy_up={proxy_up} status={status} "
            f"groups={len(groups)} pg_up={pg_up} redis_up={redis_up}"
        )
    # A 5xx is transient (router cooldown handles it); do not exit 1.
    # Only connection-refused (status==0) exits 1, handled above.
    return 0


if __name__ == "__main__":
    sys.exit(main())
