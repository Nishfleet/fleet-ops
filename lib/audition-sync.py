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

Only WIRED candidates are injected: provider must be a key in models.json and
the model must be in that provider's models/modelOverrides. The WFR
model-discovery pre-pass (fleet-ops#3321) emits ~3800 catalog entries keyed on
models.dev display names; none are pi provider slugs, so without this gate the
lane would flood the live caps file with seats that can never be enumerated
or served. An unwired candidate is not a seat.

Retirement state lives in a sidecar (~/.local/state/pi-packet/
audition-verdicts.json), NOT inside seat-caps.json: install.sh overwrites the
live caps copy on every deploy, so an in-file drop ledger would be wiped and a
failed candidate would silently re-audition.

Verdict line format (one per line on stdout):
  PROMOTE <provider>/<model> yield=<y> sessions=<n> cost_usd=<c>
  DROP <provider>/<model> audition-failed: yield=<y> sessions=<n> cost_usd=<c>

Exit 0 always (best-effort; a missing/unparseable input is a no-op, never a
tick failure). The tick owns the GitHub write.
"""

import fcntl
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
# A retired candidate is not re-injected for 30 days (dated verdict sidecar;
# a promote waiting on its PR must not re-audition in the gap either).
AUDITION_VERDICT_TTL_DAYS = int(os.environ.get("AUDITION_VERDICT_TTL_DAYS", "30"))
# A promote verdict needs real sessions, not the provisional 0.5: a seat that
# never served (unwired catalog slug, or starved to the 7-day age ceiling)
# has no measured yield and must not promote on a default.
AUDITION_MIN_SESSIONS_TO_PROMOTE = int(
    os.environ.get("AUDITION_MIN_SESSIONS_TO_PROMOTE", "5")
)

# Prepaid-quota providers are NEVER auditioned (standing rule: the 2026-08
# Ollama audition burned 65% of a weekly quota). Defence in depth: even if a
# candidate file lists one, it is skipped at read time. Class equivalents
# (prepaid-quota / subscription) are refused the same way.
PREPAID_PROVIDERS = {
    "devin", "ollama", "cline", "cursor", "xai", "xai-oauth",
}
PREPAID_CLASSES = {"prepaid-quota", "subscription"}


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


def _wired_seats(models_json_path):
    """Return {provider: {model_ids}} for providers wired in models.json.

    enumerate_seats (lib/seat-lib.sh) emits exactly these pairs, so a
    candidate outside this set can never be picked — injecting it would only
    bloat the live caps file until the 7-day age ceiling retires it.
    """
    data = _load_json(models_json_path)
    wired = {}
    if not isinstance(data, dict):
        return wired
    for slug, prov in (data.get("providers") or {}).items():
        if not isinstance(prov, dict):
            continue
        ids = {
            m.get("id")
            for m in (prov.get("models") or [])
            if isinstance(m, dict) and m.get("id")
        }
        ids |= set((prov.get("modelOverrides") or {}).keys())
        wired[slug] = ids
    return wired


def _seat_in_caps(caps, provider, model):
    prov = (caps.get("providers") or {}).get(provider)
    if not isinstance(prov, dict):
        return False
    return model in (prov.get("models") or {})


def _inject_candidate(caps, c, now_iso):
    """Inject a candidate into the LIVE caps as a cap-1 audition seat.

    The audition flag is MODEL-level so a candidate added under an existing
    provider never marks that provider's other (non-audition) seats
    light-only. A provider created purely for the audition also gets the
    provider-level flag (matches the xkiro shape landed by fleet-ops#3505).
    """
    provider = c.get("provider")
    model = c.get("model")
    klass = c.get("class", "free")
    if not provider or not model:
        return False
    if klass in PREPAID_CLASSES or provider in PREPAID_PROVIDERS:
        return False
    providers = caps["providers"]
    new_provider = not isinstance(providers.get(provider), dict)
    prov = providers.setdefault(provider, {})
    if not isinstance(prov.get("models"), dict):
        prov["models"] = {}
    models = prov["models"]
    if model in models:
        return False  # already in caps
    models[model] = {
        "cap": 1,
        "audition": True,
        "audition_started": now_iso,
    }
    prov.setdefault("cap", 1)
    prov.setdefault("class", klass)
    if new_provider:
        prov["audition"] = True
        prov["audition_started"] = now_iso
    return True


def _model_audition_started(prov, mval):
    if isinstance(mval, dict) and mval.get("audition_started"):
        return mval.get("audition_started")
    return prov.get("audition_started")


def _model_is_audition(prov, mval):
    if prov.get("audition") is True:
        return True
    return isinstance(mval, dict) and mval.get("audition") is True


def _retire_seat(caps, provider, model):
    """Remove an audition seat from the LIVE caps."""
    prov = (caps.get("providers") or {}).get(provider)
    if not isinstance(prov, dict):
        return
    models = prov.get("models") or {}
    models.pop(model, None)
    # Drop the provider block only when it was created for the audition and
    # has no models left — a pre-existing provider with other seats stays.
    if not models and prov.get("audition") is True:
        (caps.get("providers") or {}).pop(provider, None)


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


def _load_verdicts(path):
    data = _load_json(path)
    return data if isinstance(data, dict) else {}


def _save_verdicts(path, verdicts):
    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        Path(tmp).write_text(json.dumps(verdicts, indent=2, sort_keys=True))
        os.replace(tmp, path)
    except OSError:
        pass


def _recently_retired(verdicts, key, now_epoch):
    rec = verdicts.get(key)
    if not isinstance(rec, dict):
        return False
    at = _parse_iso(rec.get("at"))
    if at is None:
        return False
    return (now_epoch - at) < AUDITION_VERDICT_TTL_DAYS * 86400


def _sync(cand_json, caps_json, yield_json, models_json, verdicts_json,
          seed_json=""):
    cand_list = _load_candidates(cand_json)
    # The tracked seed (config/model-candidates-seed.json) rides alongside the
    # generated roster: the WFR pre-pass overwrites model-candidates.json
    # weekly and gitignores it, so curated picks live in the seed file.
    # Deduped by provider/model; the generated file wins on conflict.
    seen = {_candidate_key(c) for c in cand_list}
    for c in _load_candidates(seed_json):
        key = _candidate_key(c)
        if key not in seen:
            seen.add(key)
            cand_list.append(c)
    caps = _load_json(caps_json)
    if caps is None:
        return []
    if not isinstance(caps.get("providers"), dict):
        caps["providers"] = {}
    wired = _wired_seats(models_json)
    retired = _load_verdicts(verdicts_json)

    now_iso = _now_iso()
    now_epoch = datetime.now(timezone.utc).timestamp()

    # 1. Inject wired candidates not yet in the LIVE caps.
    injected = 0
    skipped_unwired = 0
    for c in cand_list:
        provider = c.get("provider")
        model = c.get("model")
        if not provider or not model:
            continue
        key = _candidate_key(c)
        if _recently_retired(retired, key, now_epoch):
            continue
        if model not in wired.get(provider, set()):
            skipped_unwired += 1
            continue
        if _seat_in_caps(caps, provider, model):
            continue
        if _inject_candidate(caps, c, now_iso):
            injected += 1

    # 2. Retire audition seats that hit a ceiling.
    seat_yield = _load_json(yield_json) or {}
    median = _fleet_median_yield(seat_yield)
    verdicts = []
    for provider, prov in list((caps.get("providers") or {}).items()):
        if not isinstance(prov, dict):
            continue
        for model, mval in list((prov.get("models") or {}).items()):
            if not _model_is_audition(prov, mval):
                continue
            seat = f"{provider}/{model}"
            started = _model_audition_started(prov, mval)
            started_epoch = _parse_iso(started)
            age_days = (
                (now_epoch - started_epoch) / 86400.0
                if started_epoch is not None
                else 0.0
            )
            sy = seat_yield.get(seat) or {}
            sessions = sy.get("sessions", 0)
            cost_usd = sy.get(
                "cost_usd",
                sy.get("cost_per_session", 0.0) * sessions,
            )
            retired_now = (
                sessions >= AUDITION_MAX_SESSIONS
                or cost_usd >= AUDITION_MAX_COST_USD
                or age_days >= AUDITION_MAX_AGE_DAYS
            )
            if not retired_now:
                continue
            y = sy.get("yield", 0.5)
            if sessions >= AUDITION_MIN_SESSIONS_TO_PROMOTE and y >= median:
                verdicts.append(
                    f"PROMOTE {seat} yield={y:.3f} sessions={sessions} "
                    f"cost_usd={cost_usd:.3f}"
                )
                retired[seat] = {"verdict": "promote", "at": now_iso}
            else:
                verdicts.append(
                    f"DROP {seat} audition-failed: yield={y:.3f} "
                    f"sessions={sessions} cost_usd={cost_usd:.3f}"
                )
                retired[seat] = {"verdict": "drop", "at": now_iso}
            _retire_seat(caps, provider, model)

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
        return []

    # 4. Persist the verdict sidecar (survives seat-caps deploys).
    if verdicts:
        _save_verdicts(verdicts_json, retired)

    print(
        f"audition-sync: injected={injected} skipped-unwired={skipped_unwired} "
        f"retired={len(verdicts)}",
        file=sys.stderr,
    )
    return verdicts


def main():
    cand_json = os.environ.get("MODEL_CANDIDATES_JSON", "")
    caps_json = os.environ.get("SEAT_CAPS_JSON", "")
    yield_json = os.environ.get(
        "SEAT_YIELD_JSON",
        os.path.expanduser("~/.local/state/pi-packet/seat-yield.json"),
    )
    models_json = os.environ.get(
        "PI_MODELS_JSON", os.path.expanduser("~/.pi/agent/models.json")
    )
    verdicts_json = os.environ.get(
        "AUDITION_VERDICTS_JSON",
        os.path.expanduser("~/.local/state/pi-packet/audition-verdicts.json"),
    )
    seed_json = os.environ.get("MODEL_CANDIDATES_SEED_JSON", "")
    if not seed_json and cand_json:
        sibling = Path(cand_json).parent / "model-candidates-seed.json"
        seed_json = str(sibling) if sibling.is_file() else ""
    # Run off whichever roster exists: the generated file OR the tracked seed
    # (a seed-only lane works before the first WFR pre-pass ever writes the
    # generated file).
    cand_ok = bool(cand_json) and Path(cand_json).is_file()
    seed_ok = bool(seed_json) and Path(seed_json).is_file()
    if not cand_ok and not seed_ok:
        return 0
    if not cand_ok:
        cand_json = ""
    if not caps_json or not Path(caps_json).is_file():
        return 0

    # Per-repo intake ticks overlap; serialize the caps read-modify-write so
    # a fleet-ops tick and a product tick cannot clobber each other's
    # injection/retirement. Non-blocking: a busy lane defers to the next tick.
    lock_path = f"{caps_json}.audition.lock"
    try:
        lock_fd = open(lock_path, "w")
    except OSError:
        return 0
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock_fd.close()
        print("audition-sync: another tick holds the lock (skip)", file=sys.stderr)
        return 0
    try:
        for v in _sync(cand_json, caps_json, yield_json, models_json, verdicts_json):
            print(v)
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
