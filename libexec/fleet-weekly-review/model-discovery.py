#!/usr/bin/env python3
"""Weekly model-candidate discovery for fleet-weekly-fleet-review.

Runs the last30days research engine, fetches the models.dev and OpenRouter
catalogs, and writes a candidate list to the live fleet config state."""

from __future__ import annotations

import json
import os
import socket
import statistics
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

LAST30DAYS_ENGINE = Path.home() / ".pi" / "agent" / "skills" / "last30days" / "scripts" / "last30days.py"
DEFAULT_SAVE_DIR = Path.home() / "Documents" / "Last30Days"
DEFAULT_OUTPUT = Path.home() / ".local" / "state" / "pi-packet" / "model-candidates.json"
MODELS_JSON = Path.home() / ".pi" / "agent" / "models.json"
SEAT_CAPS = Path.home() / ".local" / "state" / "pi-packet" / "seat-caps.json"

TOPIC = "best value open-weight models for autonomous coding agents: free tiers, rate limits, provider routing"
MODELS_DEV_URL = "https://models.dev/api.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/models"


def eprint(msg: str) -> None:
    print(f"model-discovery: {msg}", file=sys.stderr)


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def fetch_json(url: str, timeout: int = 60) -> Any:
    # Guard against file:// or other local-scheme reads: only https catalog
    # endpoints are ever fetched (module-level constants), but make the
    # scheme bound explicit so the urlopen target is provably remote.
    if not url.startswith("https://"):
        raise SystemExit(f"refusing non-https url: {url}")
    last_err: Exception | None = None
    headers = {
        "User-Agent": "fleet-weekly-review/1.0 (model discovery; contact fleet-ops)",
        "Accept": "application/json",
    }
    req = urllib.request.Request(url, headers=headers)
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.load(resp)
        except (urllib.error.URLError, socket.timeout, TimeoutError) as exc:
            last_err = exc
            eprint(f"fetch {url} attempt {attempt + 1} failed: {exc}")
    raise SystemExit(f"could not fetch {url}: {last_err}")


def run_last30days(save_dir: Path, extra_args: list[str]) -> None:
    save_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable,
        str(LAST30DAYS_ENGINE),
        "--emit=compact",
        f"--save-dir={save_dir}",
        "--save-suffix=v3",
        *extra_args,
        TOPIC,
    ]
    eprint(f"running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        eprint(f"last30days failed (rc={result.returncode}):")
        eprint(result.stderr or result.stdout)
        raise SystemExit(1)
    for line in result.stdout.splitlines():
        if "Raw results saved" in line:
            eprint(line)


def get_model_class(model: dict[str, Any], provider_id: str, seat_caps: dict[str, Any]) -> str | None:
    """Return 'free', 'prepaid', 'metered', or None for an entitled model."""
    providers = seat_caps.get("providers") or {}
    p = providers.get(provider_id)
    if not isinstance(p, dict):
        return None
    provider_class = p.get("class", "")

    # Per-model class override (e.g., cline z-ai/glm-5.3-flash is free on a prepaid provider)
    models = p.get("models") or {}
    mcfg = models.get(model.get("id"))
    if isinstance(mcfg, dict) and "class" in mcfg:
        model_class = mcfg["class"]
    else:
        model_class = provider_class

    if model_class == "free" or provider_class == "free":
        return "free"
    if model_class in ("prepaid-quota", "prepaid", "subscription"):
        return "prepaid"
    if model_class == "metered":
        return "metered"
    return None


def current_metered_median_price(
    models_json: dict[str, Any],
    openrouter: dict[str, Any],
    models_dev: dict[str, Any],
    seat_caps: dict[str, Any],
) -> float:
    """Median price_in of the currently wired, usable metered fleet models."""
    or_prices: dict[str, tuple[float, float]] = {}
    for m in openrouter.get("data", []):
        pricing = m.get("pricing") or {}
        try:
            pin = float(pricing["prompt"]) * 1_000_000
            pout = float(pricing.get("completion", 0)) * 1_000_000
        except (KeyError, TypeError, ValueError):
            continue
        or_prices[m["id"]] = (pin, pout)

    md_prices: dict[str, tuple[float, float]] = {}
    for pdata in models_dev.values():
        if not isinstance(pdata, dict):
            continue
        for m in pdata.get("models", {}).values():
            cost = m.get("cost") or {}
            if cost.get("input") is not None:
                md_prices[m.get("id", "")] = (float(cost["input"]), float(cost.get("output", 0)))

    prices: list[float] = []
    providers = seat_caps.get("providers") or {}
    for provider_id, pdata in (models_json.get("providers") or {}).items():
        if not isinstance(pdata, dict):
            continue
        p = providers.get(provider_id)
        if not isinstance(p, dict) or p.get("cap") == 0:
            # Cap 0 = not currently usable for median (grok decoy, opencode-anthropic money-only)
            continue
        cls = get_model_class({}, provider_id, seat_caps)
        if cls != "metered":
            continue

        # openrouter uses modelOverrides instead of a models list
        if "modelOverrides" in pdata and isinstance(pdata["modelOverrides"], dict):
            override_models = [dict(m, id=mid) for mid, m in pdata["modelOverrides"].items()]
        else:
            override_models = []

        for m in list(pdata.get("models", [])) + override_models:
            if not isinstance(m, dict):
                continue
            model_id = m.get("id", "")
            mcls = get_model_class(m, provider_id, seat_caps)
            if mcls != "metered":
                continue
            cost = m.get("cost") or {}
            pin = cost.get("input")
            if pin is None:
                if model_id in or_prices:
                    pin = or_prices[model_id][0]
                elif model_id in md_prices:
                    pin = md_prices[model_id][0]
            if pin is None:
                continue
            pin = float(pin)
            if pin > 0:
                prices.append(pin)

    if not prices:
        eprint("warning: no current metered prices; using fallback 1.0")
        return 1.0

    median = statistics.median(prices)
    details = ", ".join(f"{p:.4f}" for p in sorted(prices))
    eprint(f"current metered median price_in: {median:.6f} (from {len(prices)} models: {details})")
    return median


def price_from_models_dev(m: dict[str, Any]) -> tuple[float, float] | None:
    cost = m.get("cost") or {}
    if cost.get("input") is None:
        return None
    return (float(cost["input"]), float(cost.get("output", 0)))


def price_from_openrouter(m: dict[str, Any]) -> tuple[float, float] | None:
    pricing = m.get("pricing") or {}
    prompt = pricing.get("prompt")
    completion = pricing.get("completion")
    if prompt is None:
        return None
    try:
        pin = float(prompt) * 1_000_000
        pout = float(completion) * 1_000_000 if completion is not None else 0.0
    except (TypeError, ValueError):
        return None
    return (pin, pout)


def ctx_from_models_dev(m: dict[str, Any]) -> int:
    limit = m.get("limit") or {}
    return limit.get("context") or limit.get("input") or 0


def ctx_from_openrouter(m: dict[str, Any]) -> int:
    return (
        m.get("context_length")
        or (m.get("top_provider") or {}).get("context_length")
        or 0
    )


def collect_candidates(
    models_dev: dict[str, Any],
    openrouter: dict[str, Any],
    median: float,
    require_open_weights: bool,
) -> list[dict[str, Any]]:
    seen: set[tuple[str, str]] = set()
    candidates: list[dict[str, Any]] = []
    seen_at = datetime.now(timezone.utc).isoformat()

    def add(provider: str, model: str, class_: str, pin: float, pout: float, ctx: int, source: str) -> None:
        key = (provider, model)
        if key in seen:
            return
        seen.add(key)
        candidates.append({
            "provider": provider,
            "model": model,
            "class": class_,
            "price_in": round(pin, 6),
            "price_out": round(pout, 6),
            "tools": True,
            "ctx": ctx,
            "source": source,
            "seen_at": seen_at,
        })

    for provider_id, pdata in models_dev.items():
        if not isinstance(pdata, dict):
            continue
        for m in pdata.get("models", {}).values():
            if not m.get("tool_call"):
                continue
            if require_open_weights and not m.get("open_weights"):
                continue
            price = price_from_models_dev(m)
            if price is None:
                continue
            pin, pout = price
            if pin != 0 and pin >= median:
                continue
            class_ = "free" if pin == 0 else "metered"
            add(provider_id, m.get("id", ""), class_, pin, pout, ctx_from_models_dev(m), "models.dev")

    for m in openrouter.get("data", []):
        supported = set(m.get("supported_parameters") or [])
        if not ({"tools", "tool_choice"} & supported):
            continue
        price = price_from_openrouter(m)
        if price is None:
            continue
        pin, pout = price
        if pin != 0 and pin >= median:
            continue
        class_ = "free" if pin == 0 else "metered"
        add("openrouter", m.get("id", ""), class_, pin, pout, ctx_from_openrouter(m), "openrouter")

    return candidates


def main() -> None:
    output = Path(os.environ.get("MODEL_CANDIDATES_JSON", DEFAULT_OUTPUT))
    save_dir = Path(os.environ.get("LAST30DAYS_SAVE_DIR", DEFAULT_SAVE_DIR))
    extra = os.environ.get("LAST30DAYS_EXTRA_ARGS", "")
    extra_args = extra.split() if extra else []
    skip_last30days = os.environ.get("SKIP_LAST30DAYS", "0") == "1"
    require_open_weights = os.environ.get("REQUIRE_OPEN_WEIGHTS", "1") != "0"

    if not LAST30DAYS_ENGINE.exists():
        raise SystemExit(f"last30days engine not found: {LAST30DAYS_ENGINE}")

    eprint(f"output path: {output}")

    if not skip_last30days:
        run_last30days(save_dir, extra_args)
    else:
        eprint("SKIP_LAST30DAYS=1; skipping last30days run")

    eprint(f"fetching {MODELS_DEV_URL}")
    models_dev = fetch_json(MODELS_DEV_URL, timeout=90)
    eprint(f"fetching {OPENROUTER_URL}")
    openrouter = fetch_json(OPENROUTER_URL, timeout=90)

    seat_caps = load_json(SEAT_CAPS) if SEAT_CAPS.exists() else {}
    models_json = load_json(MODELS_JSON) if MODELS_JSON.exists() else {}

    median = current_metered_median_price(models_json, openrouter, models_dev, seat_caps)
    candidates = collect_candidates(models_dev, openrouter, median, require_open_weights)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "metered_median_price_in": round(median, 6),
        "candidates": candidates,
    }
    write_json(output, payload)

    eprint(f"wrote {len(candidates)} candidates to {output}")
    for c in candidates[:10]:
        eprint(f"  - {c['provider']}/{c['model']} class={c['class']} in={c['price_in']} out={c['price_out']} ctx={c['ctx']}")


if __name__ == "__main__":
    main()
