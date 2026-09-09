#!/usr/bin/env python3
"""fleet-usd.py — rate-card × session-usage spend computation (fleet-ops#4459).

Shared by bin's measure.sh output and libexec/fleet-metrics-export.py's
fleet_usd_24h metric. Two independent rails must not drift, so the USD math
lives here and each consumer imports it.

Models:
  - rate card: config/seat-caps.json providers.*.usd_per_1m_{input,output,cached}
    (per-1M-token USD) and providers.*.flat_usd_per_month (a flat prepaid plan
    whose marginal metered spend is 0 but whose cost is a prorated flat share).
  - per-session usage: pi session jsonl carries message.usage.{input,output,
    cacheRead} token counts (live shape, fleet-ops#3283). We attribute each
    message's tokens to its provider (tracked on model_change lines) and
    multiply by the rate card to get marginal USD.

A seat that cannot be priced (no rate card and no flat plan) is reported
UNAVAILABLE:<why> — never fabricated as $0 (fleet-ops#4459 required).
"""
from __future__ import annotations

import json
import os
from pathlib import Path

RATE_KEY_IN = "usd_per_1m_input"
RATE_KEY_OUT = "usd_per_1m_output"
RATE_KEY_CACHE = "usd_per_1m_cached"
RATE_KEY_FLAT = "flat_usd_per_month"
RATE_KEY_SRC = "_rate_card"


def load_rate_card(seat_caps_path):
    """Return {provider: _Rate} from config/seat-caps.json providers.

    _Rate is a dict with keys 'input','output','cached','flat' (USD per 1M and
    flat USD per month) plus the raw row 'raw' (for source citation). Providers
    with neither metered nor flat pricing are returned with rate=None.
    """
    with open(seat_caps_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    providers = doc.get("providers", {})
    out = {}
    for name, p in providers.items():
        if not isinstance(p, dict):
            continue
        has_any = any(
            p.get(k) is not None for k in (RATE_KEY_IN, RATE_KEY_OUT, RATE_KEY_CACHE, RATE_KEY_FLAT)
        )
        out[name] = {
            "input": p.get(RATE_KEY_IN),
            "output": p.get(RATE_KEY_OUT),
            "cached": p.get(RATE_KEY_CACHE),
            "flat": p.get(RATE_KEY_FLAT),
            "class": p.get("class"),
            "raw": p,
            "priced": has_any,
        }
    return out


def _parse_iso_utc(s):
    """Best-effort UTC parse of an ISO-8601 timestamp to a unix epoch."""
    import datetime as dt
    if not s:
        return None
    t = s
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(t).timestamp()
    except (ValueError, TypeError):
        return 0


def session_marginal_usd(path, rate_card, today_epoch=None, day_seconds=86400.0):
    """Return {provider: usd} marginal metered spend for one session jsonl.

    Only messages whose UTC day fall in the trailing `day_seconds` window (up
    to `today_epoch`) are counted, so the caller can ask for exactly the last
    24h. When today_epoch is None, ALL messages count (full-session spend).
    A provider with no price in the rate card does not accumulate; it is
    returned with a zero entry so the caller can flag it UNAVAILABLE.
    """
    spend = {}
    missing = set()
    provider = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict):
                    continue
                t = data.get("type")
                if t == "model_change":
                    provider = data.get("provider")
                    continue
                if t != "message":
                    continue
                msg = data.get("message") or {}
                if not isinstance(msg, dict):
                    continue
                if provider is None:
                    provider = msg.get("provider")
                if provider is None:
                    continue
                if today_epoch is not None:
                    ts = data.get("timestamp") or ""
                    ep = _parse_iso_utc(ts)
                    if ep is not None and (today_epoch - ep) > day_seconds:
                        continue
                usage = msg.get("usage") or {}
                if not isinstance(usage, dict):
                    continue
                in_tok = usage.get("input") or 0
                out_tok = usage.get("output") or 0
                cache_tok = usage.get("cacheRead") or 0
                rate = rate_card.get(provider)
                if not rate or not rate.get("priced"):
                    missing.add(provider)
                    continue
                # cacheRead tokens also consume input budget on cache-miss;
                # count cacheRead at the cached rate (provider convention).
                usd = (
                    float(in_tok) * float(rate["input"] or 0) / 1_000_000.0
                    + float(out_tok) * float(rate["output"] or 0) / 1_000_000.0
                    + float(cache_tok) * float(rate["cached"] or 0) / 1_000_000.0
                )
                spend[provider] = spend.get(provider, 0.0) + usd
    except OSError:
        return None
    return {"spend": spend, "missing": missing}


# Per-file mtime-keyed cache so the exporter's 5-min tick does not re-parse
# every session jsonl each run (12k+ files, ~30s cold). Keyed on (path, mtime,
# day_seconds): a session jsonl is append-only, and the trailing-24h window only
# slides forward (messages older than the window never re-enter it), so a cached
# windowed result stays valid for an unchanged file across ticks.
#   key -> {"spend": {prov: usd}, "missing": {prov}, "mtime": float}
_USD_FILE_CACHE = {}
_USD_CACHE_MAX = 4096


def _cached_session_marginal(cache_key, rate_card, today_epoch, day_seconds):
    """session_marginal_usd with an in-process mtime cache (see header)."""
    path = cache_key
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None
    hit = _USD_FILE_CACHE.get(cache_key)
    if hit and hit.get("mtime") == mtime and hit.get("day") == day_seconds:
        return hit
    res = session_marginal_usd(path, rate_card, today_epoch=today_epoch, day_seconds=day_seconds)
    if res is None:
        return None
    entry = {"spend": res.get("spend") or {}, "missing": res.get("missing") or set(),
             "mtime": mtime, "day": day_seconds}
    if len(_USD_FILE_CACHE) >= _USD_CACHE_MAX:
        _USD_FILE_CACHE.clear()
    _USD_FILE_CACHE[cache_key] = entry
    return entry


def compute_usd_24h(sessions_dir, rate_card, now_epoch=None, day_seconds=86400.0):
    """Aggregate marginal USD over all session jsonl for the trailing 24h.

    Returns {provider: usd}, plus the set of providers seen in sessions that
    carry no rate card (UNAVAILABLE) and a flat_share estimate for flat seats.
    """
    import time as _time
    sessions = Path(sessions_dir)
    if not sessions.is_dir():
        return {}, set(), {}
    today = now_epoch if now_epoch is not None else _time.time()
    agg = {}
    seen_missing = set()
    flat = {}
    for path in sessions.rglob("*.jsonl"):
        if not path.is_file():
            continue
        res = _cached_session_marginal(str(path), rate_card, today, day_seconds)
        if res is None:
            continue
        for prov, usd in (res.get("spend") or {}).items():
            agg[prov] = agg.get(prov, 0.0) + usd
        seen_missing |= res.get("missing") or set()
    # Flat-share estimate: prorate each flat plan's monthly cost to one day.
    for prov, rate in rate_card.items():
        flat_month = rate.get("flat")
        if flat_month:
            flat[prov] = float(flat_month) / 30.0
    return agg, seen_missing, flat


def merged_pr_count_24h(pr_sources):
    """Sum the per-repo merged-PR counts from whatever the caller passes.

    pr_sources is a dict {repo: count}; returns the total. Wired so measure.sh
    and the exporter can both report usd_per_merged_pr without duplicating the
    gh query (each owns its own gh call; this just normalizes the shape).
    """
    return sum(int(v or 0) for v in pr_sources.values())
