#!/usr/bin/env python3
"""Model discovery pre-pass for fleet-weekly-fleet-review.

Runs before the WFR pi conference (fleet-ops#3321):
1. Runs the last30days skill in non-interactive mode.
2. Fetches the models.dev and OpenRouter machine-readable catalogs.
3. Writes config/model-candidates.json with tool-capable models that are
   free or cheaper than the current metered median.

No model is auditioned or routed here. The service ExecStartPre invokes this
script; its only side effect is the JSON list.
"""

import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

LAST30DAYS = Path("/home/nish/.pi/agent/skills/last30days/scripts/last30days.py")
MODELS_DEV_URL = "https://models.dev/api.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/models"
CURL_TIMEOUT = 120
USER_AGENT = "fleet-weekly-review/1.0 (model-discovery; fleet-ops#3321)"

WORKDIR = Path(os.environ.get("WORKDIR", "/home/nish/workspaces/tooling/fleet-ops-deploy-clone"))
OUT = WORKDIR / "config" / "model-candidates.json"
TMP_DIR = Path("/tmp/weekly-fleet-review-model-discovery")


def log(msg: str) -> None:
    print(f"model-discovery: {msg}", flush=True)


def run_last30days() -> None:
    """Run the last30days skill (best-effort; not a blocker for the catalogs)."""
    save_dir = Path.home() / "Documents" / "Last30Days"
    save_dir.mkdir(parents=True, exist_ok=True)
    topic = (
        "best value open-weight models for autonomous coding agents: "
        "free tiers, rate limits, provider routing"
    )
    cmd = [
        sys.executable,
        str(LAST30DAYS),
        "--agent",
        topic,
        "--emit=compact",
        f"--save-dir={save_dir}",
    ]
    log(f"running last30days: {' '.join(cmd)}")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            log(f"last30days exited {result.returncode}; stderr: {result.stderr[:500]}")
        else:
            log(f"last30days completed; stdout tail: {result.stdout[-400:]}")
    except Exception as exc:
        log(f"last30days failed to run: {exc}")


def curl_json(url: str, dest: Path) -> None:
    result = subprocess.run(
        [
            "curl",
            "-sL",
            "--fail",
            "--max-time",
            str(CURL_TIMEOUT),
            "-A",
            USER_AGENT,
            url,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"curl failed for {url} (rc={result.returncode}): {result.stderr[:500]}")
    if not result.stdout:
        raise RuntimeError(f"empty response from {url}")
    dest.write_text(result.stdout)


def load_json(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def parse_models_dev(data: dict) -> list[dict]:
    models = []
    for provider_id, provider in data.items():
        if not isinstance(provider, dict):
            continue
        provider_name = provider.get("name") or provider.get("id") or provider_id
        provider_models = provider.get("models", {})
        if not isinstance(provider_models, dict):
            continue
        for model_id, m in provider_models.items():
            if not isinstance(m, dict):
                continue
            cost = m.get("cost") or {}
            limit = m.get("limit") or {}
            pricing = m.get("pricing") or {}
            models.append(
                {
                    "provider": provider_name,
                    "model": m.get("name") or model_id,
                    "price_in": float(cost.get("input") or pricing.get("input") or 0.0),
                    "price_out": float(cost.get("output") or pricing.get("output") or 0.0),
                    "ctx": int(limit.get("context") or 0),
                    "tools": bool(m.get("tool_call") or m.get("supports_tools")),
                    "source": "models.dev",
                }
            )
    return models


def parse_openrouter(data: dict) -> list[dict]:
    models = []
    for m in data.get("data", []):
        if not isinstance(m, dict):
            continue
        model_id = m.get("id", "")
        provider = "openrouter"
        if "/" in model_id:
            provider, _, model = model_id.partition("/")
        else:
            model = model_id
        pricing = m.get("pricing") or {}
        params = m.get("supported_parameters") or []
        models.append(
            {
                "provider": provider,
                "model": model or model_id,
                "price_in": float(pricing.get("prompt") or 0.0),
                "price_out": float(pricing.get("completion") or 0.0),
                "ctx": int(m.get("context_length") or 0),
                "tools": "tools" in params,
                "source": "openrouter",
            }
        )
    return models


def build_candidates(models: list[dict]) -> list[dict]:
    tool_models = [m for m in models if m["tools"]]

    metered_prices = sorted(m["price_in"] for m in tool_models if m["price_in"] > 0)
    median = statistics.median(metered_prices) if metered_prices else float("inf")

    candidates = [
        m
        for m in tool_models
        if m["price_in"] == 0 or (0 < m["price_in"] < median)
    ]

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for c in candidates:
        c["class"] = "free" if c["price_in"] == 0 else "metered"
        c["seen_at"] = now

    return candidates


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(TMP_DIR, ignore_errors=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)

    # Step 1: last30days (best-effort community research, not the JSON source).
    run_last30days()

    # Step 2: fetch machine-readable catalogs.
    models_dev_file = TMP_DIR / "models_dev.json"
    openrouter_file = TMP_DIR / "openrouter_models.json"
    curl_json(MODELS_DEV_URL, models_dev_file)
    curl_json(OPENROUTER_URL, openrouter_file)

    # Step 3: parse, filter, write.
    md = load_json(models_dev_file)
    or_data = load_json(openrouter_file)
    models = parse_models_dev(md) + parse_openrouter(or_data)
    candidates = build_candidates(models)

    with open(OUT, "w") as f:
        json.dump(candidates, f, indent=2)

    log(
        f"wrote {OUT}: {len(candidates)} candidates "
        f"({sum(1 for c in candidates if c['class'] == 'free')} free, "
        f"{sum(1 for c in candidates if c['class'] == 'metered')} metered)"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"model-discovery: FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
