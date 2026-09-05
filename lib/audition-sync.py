#!/usr/bin/env python3
"""fleet-ops#3322 audition-lane sync helper.

Reads config/model-candidates.json and the LIVE caps
(~/.local/state/pi-packet/seat-caps.json), injects candidates not yet in the
LIVE caps as cap-1 audition seats (light-only), retires audition seats that hit
the 10-session / 7-day / $1-cost ceiling, and prints one verdict line per
retired seat for the intake tick to file via fleet-issue-file.

This is NOT a new organ: it is a helper invoked by the intake tick
(lib/pi-intake-tick.sh), the named existing organ. No systemd unit, no timer,
no auto-PR filer. The verdict issues are filed by the tick (reusing
fleet-issue-file, orchestrator Q2(c) answer).

Verdict line format (one per line on stdout):
  PROMOTE <provider>/<model> yield=<y> sessions=<n> cost_usd=<c>
  DROP <provider>/<model> audition-failed: yield=<y> sessions=<n> cost_usd=<c>

Exit 0 always (best-effort; a missing/unparseable input is a no-op, never a
tick failure). The tick owns the GitHub write.
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Audition ceilings (fleet-ops#3322). A candidate is retired once ANY of these
# is reached: 10 sessions, 7 days since audition_started, or $1 total cost.
AUDITION_MAX_SESSIONS = int(os.environ.get("AUDITION_MAX_SESSIONS", "10"))
AUDITION_MAX_AGE_DAYS = int(os.environ.get("AUDITION_MAX_AGE_DAYS", "7"))
AUDITION_MAX_COST_USD = float(os.environ.get("AUDITION_MAX_COST_USD", "1.00"))
# A dropped candidate is not re-injected for 30 days (dated audition-failed).
AUDITION_DROP_TTL_DAYS = int(os.environ.get("AUDITION_DROP_TTL_DAYS", "30"))

# Prepaid-quota providers are NEVER auditioned (standing rule: the 2026-08
# Ollama audition burned 65% of a weekly quota). Defence in depth: even if a
# candidate file lists one, it is skipped at read time.
PREPAID_PROVIDERS = {
    "devin", "ollama", "cline", "cursor", "xai", "xai-oauth",
}


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s):
    """Parse an ISO timestamp to epoch seconds, or None."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, TypeError):
        return None


def _load_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _candidate_key(c):
    return f"{c.get('provider')}/{c.get('model')}"


def _load_candidates(path):
    """Load the candidate list from model-candidates.json.

    The WFR model-discovery pre-pass (lib/weekly-fleet-review-model-
    discovery.py, fleet-ops#3321) writes a BARE JSON list ``[...]`` of
    candidates (provider, model, price_in, class, ...). A hand-curated
    file may wrap them under a ``{"candidates": [...]}`` key. Accept
    both so the audition lane reads whatever the pre-pass emits at
    runtime (the canonical source) and a curated seed alike.
    """
    data = _load_json(path)
    if data is None:
        return []
    if isinstance(data, list):
        return [c for c in data if isinstance(c, dict)]
    if isinstance(data, dict):
        inner = data.get("candidates") or []
        return [c for c in inner if isinstance(c, dict)]
    return []


def _seat_in_caps(caps, provider, model):
    prov = (caps.get("providers") or {}).get(provider)
    if not prov:
        return False
    models = prov.get("models") or {}
    return model in models


def _inject_candidate(caps, c, now_iso):
    """Inject a candidate into the LIVE caps as a cap-1 audition seat."""
    provider = c.get("provider")
    model = c.get("model")
    klass = c.get("class", "free")
    if not provider or not model:
        return False
    if klass == "prepaid-quota" or provider in PREPAID_PROVIDERS:
        return False
    # main() guarantees caps["providers"] is a dict; use it directly (a
    # `or {}` here would silently create a NEW dict when providers is empty
    # and the mutation would be lost).
    prov = caps["providers"].setdefault(provider, {})
    models = prov.setdefault("models", {})
    if model in models:
        return False  # already in caps
    # A provider may already exist as a non-audition provider (e.g. a
    # metered lane). Add the model and mark the provider auditioning.
    models[model] = 1
    prov.setdefault("cap", 1)
    prov.setdefault("class", klass)
    prov["audition"] = True
    prov.setdefault("audition_started", now_iso)
    prov.setdefault("audition_sessions", 0)
    prov.setdefault("audition_cost_usd", 0)
    return True


def _retire_seat(caps, provider, model, verdict):
    """Remove an audition seat from the LIVE caps and record the verdict."""
    prov = caps.get("providers") or {}
    prov = prov.get(provider)
    if not prov:
        return
    models = prov.get("models") or {}
    models.pop(model, None)
    # If the provider has no other models, drop the provider block too.
    if not models:
        (caps.get("providers") or {}).pop(provider, None)
    # Record the drop so the candidate is not re-injected for the TTL.
    if verdict.startswith("DROP"):
        drops = caps.setdefault("_audition_drops", {})
        drops[f"{provider}/{model}"] = _now_iso()


def _fleet_median_yield(seat_yield):
    """Median yield across all seats in the ledger (0.5 if empty)."""
    vals = [v.get("yield", 0.5) for v in seat_yield.values()]
    if not vals:
        return 0.5
    vals.sort()
    n = len(vals)
    mid = n // 2
    if n % 2 == 1:
        return vals[mid]
    return (vals[mid - 1] + vals[mid]) / 2.0


def main():
    cand_json = os.environ.get("MODEL_CANDIDATES_JSON", "")
    caps_json = os.environ.get("SEAT_CAPS_JSON", "")
    yield_json = os.environ.get("SEAT_YIELD_JSON", "")
    if not cand_json or not Path(cand_json).is_file():
        return 0
    if not caps_json or not Path(caps_json).is_file():
        return 0

    cand_list = _load_candidates(cand_json)
    caps = _load_json(caps_json)
    if caps is None:
        return 0
    caps.setdefault("providers", {})

    now_iso = _now_iso()
    now_epoch = datetime.now(timezone.utc).timestamp()

    # 1. Inject candidates not yet in the LIVE caps.
    injected = 0
    drops = caps.get("_audition_drops") or {}
    for c in cand_list:
        key = _candidate_key(c)
        # Skip a candidate dropped within the TTL (dated audition-failed).
        dropped_at = drops.get(key)
        if dropped_at:
            d_epoch = _parse_iso(dropped_at)
            if d_epoch is not None and (now_epoch - d_epoch) < (
                AUDITION_DROP_TTL_DAYS * 86400
            ):
                continue
        if _inject_candidate(caps, c, now_iso):
            injected += 1

    # 2. Retire audition seats that hit a ceiling.
    seat_yield = _load_json(yield_json) or {}
    median = _fleet_median_yield(seat_yield)
    verdicts = []
    for provider, prov in list((caps.get("providers") or {}).items()):
        if not isinstance(prov, dict) or prov.get("audition") is not True:
            continue
        started = prov.get("audition_started")
        started_epoch = _parse_iso(started)
        age_days = (
            (now_epoch - started_epoch) / 86400.0
            if started_epoch is not None
            else 0.0
        )
        for model in list((prov.get("models") or {}).keys()):
            seat = f"{provider}/{model}"
            sy = seat_yield.get(seat) or {}
            sessions = sy.get("sessions", 0)
            cost_usd = sy.get("cost_usd", 0.0)
            retired = (
                sessions >= AUDITION_MAX_SESSIONS
                or cost_usd >= AUDITION_MAX_COST_USD
                or age_days >= AUDITION_MAX_AGE_DAYS
            )
            if not retired:
                continue
            y = sy.get("yield", 0.5)
            if y >= median:
                verdicts.append(
                    f"PROMOTE {seat} yield={y:.3f} sessions={sessions} "
                    f"cost_usd={cost_usd:.3f}"
                )
                _retire_seat(caps, provider, model, "PROMOTE")
            else:
                verdicts.append(
                    f"DROP {seat} audition-failed: yield={y:.3f} "
                    f"sessions={sessions} cost_usd={cost_usd:.3f}"
                )
                _retire_seat(caps, provider, model, "DROP")

    # 3. Write the updated LIVE caps atomically.
    tmp = f"{caps_json}.tmp.{os.getpid()}"
    try:
        Path(tmp).write_text(json.dumps(caps, indent=2))
        os.replace(tmp, caps_json)
    except OSError:
        try:
            Path(tmp).unlink(missing_ok=True)
        except OSError:
            pass
        return 0

    # 4. Print verdicts for the tick to file.
    for v in verdicts:
        print(v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
