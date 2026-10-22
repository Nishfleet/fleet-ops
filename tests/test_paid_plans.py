import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _router_rows():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return [row["litellm_params"] for row in json.loads(out)]


def _plans():
    return json.loads((ROOT / "config/paid-plans.json").read_text())


def _bases(rows, prepaid_only=False):
    return [r.get("api_base", "") for r in rows if not prepaid_only or "prepaid" in (r.get("tags") or [])]


def test_every_live_paid_plan_keeps_a_router_row():
    bases = _bases(_router_rows())
    gone = [p["name"] for p in _plans() if not p.get("rows_pending") and not any(b.startswith(p["api_base"]) for b in bases)]
    assert not gone, f"paid plans with no router row: {gone}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"


def test_every_prepaid_row_is_a_listed_plan():
    plans = [p["api_base"] for p in _plans()]
    unlisted = sorted({b for b in _bases(_router_rows(), prepaid_only=True) if not any(b.startswith(p) for p in plans)})
    assert not unlisted, f"prepaid rows not in config/paid-plans.json: {unlisted}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"


# W10c: no router tier may be left with a single row. senior-backup is the same GLM-5.3-Flash as senior on another
# provider (the router falls senior back to it, config/litellm-proxy.schema.json pins that), so the two count as one tier.
SAME_TIER = {"senior-backup": "senior"}


def test_every_router_tier_keeps_two_deployments_and_every_fallback_target_exists():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    cfg = json.loads(out)
    groups = {}
    for row in cfg["model_list"]:
        groups.setdefault(row["model_name"], []).append(row["model_info"]["id"])
    tiers = {}
    for name, ids in groups.items():
        tiers.setdefault(SAME_TIER.get(name, name), []).extend(ids)
    thin = {t: len(ids) for t, ids in tiers.items() if len(ids) < 2}
    assert not thin, f"router tiers with fewer than 2 deployments: {thin}. A tier needs a second row or a same-tier fallback group"
    missing = [(src, dst) for entry in cfg["router_settings"]["fallbacks"] for src, dsts in entry.items() for dst in dsts if dst not in groups]
    assert not missing, f"fallbacks naming a group with no row: {missing}"
