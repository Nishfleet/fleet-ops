#!/usr/bin/env python3
"""Weekly AEO visibility probe for 0509 (fleet-ops#1236).

Asks the money-queries against ChatGPT / Perplexity / Claude when a
prepaid or already-configured API seat exists. Missing seats are
recorded as unavailable (engine_up=0), not as "0509 is invisible".
Never spends a metered key unless AEO_ALLOW_METERED=1.

Stdlib only. Writes Prometheus textfile + JSON log. Shape borrowed
from aarpee1982/synthetic-research-watch (scheduled read, durable
log); none of its code.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_CONFIG = Path("/home/nish/.config/fleet-aeo/probe.json")
DEFAULT_PROM = Path("/var/lib/prometheus/node-exporter/fleet-aeo.prom")
DEFAULT_LOG = Path("/home/nish/workspaces/agent-state/aeo-probe/latest.json")

SNIPPET_CHARS = 400
HTTP_TIMEOUT_S = 30
ANTHROPIC_VERSION = "2023-06-01"


def _atomic_write(path: Path, text: str, *, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
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


def load_env_file(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines. Never logs values."""
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key:
            out[key] = value
    return out


def getenv_engine(engine: dict[str, Any], environ: dict[str, str]) -> dict[str, str]:
    merged: dict[str, str] = {}
    env_file = engine.get("env_file") or ""
    if env_file:
        merged.update(load_env_file(Path(os.path.expanduser(str(env_file)))))
    merged.update(environ)
    return merged


def brand_flags(text: str, brand: dict[str, Any]) -> tuple[bool, bool]:
    """Return (cited, mentioned). cited => URL/host; mentioned => name."""
    body = text or ""
    cited = False
    for host in brand.get("hosts") or []:
        if host and host.lower() in body.lower():
            cited = True
            break
    mentioned = cited
    if not mentioned:
        for pat in brand.get("mention_patterns") or []:
            if pat and re.search(pat, body, flags=re.IGNORECASE):
                mentioned = True
                break
    return cited, mentioned


def competitor_hits(text: str, names: list[str]) -> list[str]:
    found: list[str] = []
    body = text or ""
    for name in names:
        if not name:
            continue
        if re.search(re.escape(name), body, flags=re.IGNORECASE):
            found.append(name)
    return found


def _prom_escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace('"', '\\"')
    )


def render_prom(run: dict[str, Any]) -> str:
    lines: list[str] = [
        "# HELP fleet_aeo_cited Money-queries where 0509 was cited (host/URL) this weekly probe.",
        "# TYPE fleet_aeo_cited gauge",
        "# HELP fleet_aeo_mentioned Money-queries where 0509 was named this weekly probe.",
        "# TYPE fleet_aeo_mentioned gauge",
        "# HELP fleet_aeo_queries_total Queries in this weekly probe by engine status.",
        "# TYPE fleet_aeo_queries_total gauge",
        "# HELP fleet_aeo_engine_up 1 if the engine answered at least one query this run.",
        "# TYPE fleet_aeo_engine_up gauge",
        "# HELP fleet_aeo_probe_last_run_seconds Unix time the weekly AEO probe finished.",
        "# TYPE fleet_aeo_probe_last_run_seconds gauge",
    ]
    qclass = _prom_escape(str(run.get("query_class") or "unknown"))
    engines = run.get("engines") or {}
    for engine_id, row in engines.items():
        eid = _prom_escape(str(engine_id))
        status = _prom_escape(str(row.get("status") or "unavailable"))
        cited = int(row.get("cited") or 0)
        mentioned = int(row.get("mentioned") or 0)
        queries = int(row.get("queries") or 0)
        up = 1 if row.get("status") == "ok" else 0
        lines.append(
            f'fleet_aeo_cited{{engine="{eid}",query_class="{qclass}"}} {cited}'
        )
        lines.append(
            f'fleet_aeo_mentioned{{engine="{eid}",query_class="{qclass}"}} {mentioned}'
        )
        lines.append(
            f'fleet_aeo_queries_total{{engine="{eid}",query_class="{qclass}",status="{status}"}} {queries}'
        )
        lines.append(f'fleet_aeo_engine_up{{engine="{eid}"}} {up}')
    lines.append(
        f'fleet_aeo_probe_last_run_seconds {int(run.get("run_at_unix") or 0)}'
    )
    lines.append("")
    return "\n".join(lines)


def _post_json(
    url: str, payload: dict[str, Any], headers: dict[str, str]
) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"https", "http"}:
        raise RuntimeError(f"refusing non-HTTP URL scheme: {parsed.scheme}")
    if not parsed.hostname:
        raise RuntimeError("URL has no host")
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:  # nosem: dynamic-urllib-use-detected
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:200]
        raise RuntimeError(f"HTTP {exc.code} from {url.split('?', 1)[0]}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"network error talking to engine: {exc.reason}") from exc
    try:
        parsed_json = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("engine returned non-JSON") from exc
    if not isinstance(parsed_json, dict):
        raise RuntimeError("engine JSON root is not an object")
    return parsed_json


def call_openai_chat(
    env: dict[str, str], engine: dict[str, Any], query: str
) -> str:
    key_env = str(engine.get("api_key_env") or "OPENAI_API_KEY")
    key = env.get(key_env) or ""
    if not key:
        raise RuntimeError("missing api key")
    base = (
        env.get(str(engine.get("base_url_env") or "OPENAI_BASE_URL"))
        or str(engine.get("base_url") or "https://api.openai.com/v1")
    ).rstrip("/")
    model = str(engine.get("model") or "")
    if not model:
        raise RuntimeError("engine model is empty")
    parsed = _post_json(
        f"{base}/chat/completions",
        {
            "model": model,
            "temperature": 0,
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": query}],
        },
        {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )
    choices = parsed.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        raise RuntimeError("openai chat: no choices")
    message = choices[0].get("message") or {}
    content = message.get("content") if isinstance(message, dict) else ""
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("openai chat: empty content")
    return content


def call_anthropic(
    env: dict[str, str], engine: dict[str, Any], query: str
) -> str:
    key_env = str(engine.get("api_key_env") or "ANTHROPIC_API_KEY")
    key = env.get(key_env) or ""
    if not key:
        raise RuntimeError("missing api key")
    base = (
        env.get(str(engine.get("base_url_env") or "ANTHROPIC_BASE_URL"))
        or str(engine.get("base_url") or "https://api.anthropic.com")
    ).rstrip("/")
    model = str(engine.get("model") or "")
    if not model:
        raise RuntimeError("engine model is empty")
    parsed = _post_json(
        f"{base}/v1/messages",
        {
            "model": model,
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": query}],
        },
        {
            "x-api-key": key,
            "anthropic-version": ANTHROPIC_VERSION,
            "Content-Type": "application/json",
        },
    )
    content = parsed.get("content") or []
    texts: list[str] = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(str(block.get("text") or ""))
    joined = "\n".join(texts).strip()
    if not joined:
        raise RuntimeError("anthropic: empty content")
    return joined


def engine_ready(
    engine: dict[str, Any], env: dict[str, str], allow_metered: bool
) -> str | None:
    """Return a skip reason, or None if the engine can be called."""
    if engine.get("metered") and not allow_metered:
        return "metered seat skipped (AEO_ALLOW_METERED!=1)"
    key_env = str(engine.get("api_key_env") or "")
    if not key_env:
        return "api_key_env missing from config"
    if not (env.get(key_env) or "").strip():
        return "no configured seat"
    return None


def run_probe(
    config: dict[str, Any],
    *,
    fixture: dict[str, Any] | None,
    environ: dict[str, str],
    now: int,
    allow_metered: bool,
) -> dict[str, Any]:
    brand = config.get("brand") or {}
    queries = list(config.get("queries") or [])
    competitors = list(config.get("competitors") or [])
    qclass = str(config.get("query_class") or "unknown")
    engines_cfg = list(config.get("engines") or [])
    if not queries:
        raise SystemExit("aeo-probe: config.queries is empty")
    if not engines_cfg:
        raise SystemExit("aeo-probe: config.engines is empty")

    run: dict[str, Any] = {
        "run_at_unix": now,
        "query_class": qclass,
        "engines": {},
    }

    for engine in engines_cfg:
        if not isinstance(engine, dict) or not engine.get("id"):
            raise SystemExit("aeo-probe: engine is missing id")
        eid = str(engine["id"])
        kind = str(engine.get("kind") or "openai_chat")
        env = getenv_engine(engine, environ)
        row: dict[str, Any] = {
            "status": "unavailable",
            "reason": "",
            "cited": 0,
            "mentioned": 0,
            "queries": len(queries),
            "results": [],
        }

        fixture_map = (fixture or {}).get(eid) if fixture is not None else None
        if fixture is not None and not isinstance(fixture_map, dict):
            row["reason"] = "not in fixture"
            run["engines"][eid] = row
            continue

        if fixture is None:
            skip = engine_ready(engine, env, allow_metered)
            if skip:
                row["reason"] = skip
                run["engines"][eid] = row
                continue

        cited_n = 0
        mentioned_n = 0
        errors = 0
        for query in queries:
            text = ""
            err = ""
            if fixture_map is not None:
                text = str(fixture_map.get(query) or "")
                if not text:
                    err = "fixture missing this query"
            else:
                try:
                    if kind == "anthropic_messages":
                        text = call_anthropic(env, engine, query)
                    elif kind == "openai_chat":
                        text = call_openai_chat(env, engine, query)
                    else:
                        err = f"unknown kind {kind}"
                except RuntimeError as exc:
                    err = str(exc)
            if err:
                errors += 1
                row["results"].append(
                    {
                        "query": query,
                        "cited_0509": False,
                        "mentioned_0509": False,
                        "competitors_cited": [],
                        "raw_snippet": "",
                        "error": err,
                    }
                )
                continue
            cited, mentioned = brand_flags(text, brand)
            if cited:
                cited_n += 1
            if mentioned:
                mentioned_n += 1
            row["results"].append(
                {
                    "query": query,
                    "cited_0509": cited,
                    "mentioned_0509": mentioned,
                    "competitors_cited": competitor_hits(text, competitors),
                    "raw_snippet": text[:SNIPPET_CHARS],
                    "error": "",
                }
            )
        row["cited"] = cited_n
        row["mentioned"] = mentioned_n
        if errors == len(queries):
            row["status"] = "error"
            row["reason"] = row["results"][0].get("error") if row["results"] else "all queries failed"
        else:
            row["status"] = "ok"
            row["reason"] = ""
        run["engines"][eid] = row
    return run


def load_config(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"aeo-probe: cannot read config {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"aeo-probe: config is not JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit("aeo-probe: config root must be an object")
    return data


def load_fixture(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit("aeo-probe: fixture root must be an object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Weekly 0509 AEO visibility probe")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--prom", default=str(DEFAULT_PROM))
    parser.add_argument("--log", default=str(DEFAULT_LOG))
    parser.add_argument("--fixture", default="")
    parser.add_argument("--now", type=int, default=0)
    args = parser.parse_args(argv)

    config = load_config(Path(args.config))
    fixture = load_fixture(Path(args.fixture)) if args.fixture else None
    now = args.now or int(time.time())
    allow_metered = os.environ.get("AEO_ALLOW_METERED", "") == "1"
    run = run_probe(
        config,
        fixture=fixture,
        environ=dict(os.environ),
        now=now,
        allow_metered=allow_metered,
    )
    _atomic_write(Path(args.log), json.dumps(run, indent=2, sort_keys=True) + "\n")
    _atomic_write(Path(args.prom), render_prom(run))
    ok = sum(1 for row in run["engines"].values() if row.get("status") == "ok")
    skipped = sum(
        1 for row in run["engines"].values() if row.get("status") == "unavailable"
    )
    print(
        f"aeo-probe: engines_ok={ok} unavailable={skipped} "
        f"query_class={run['query_class']} log={args.log}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
