import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _model_list():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def _router_rows():
    return [row["litellm_params"] for row in _model_list()]


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


SINGLE_ROW_TIERS = {"senior", "tether"}


def test_every_router_tier_keeps_two_deployments_and_every_fallback_target_exists():
    assert YQ, "yq must be on PATH to read the router config"
    cfg_out = subprocess.run([YQ, "-o=json", ".router_settings.fallbacks", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    tiers = {}
    for row in _model_list():
        tiers[row["model_name"]] = tiers.get(row["model_name"], 0) + 1
    thin = {t: n for t, n in tiers.items() if n < (1 if t in SINGLE_ROW_TIERS else 2)}
    assert not thin, f"router tiers below their floor (2 rows, senior and tether 1): {thin}. Only senior and tether may hold one row (fleet-ops#10040, fleet-ops#9980)"
    groups = {row["model_name"] for row in _model_list()}
    missing = [(src, dst) for entry in json.loads(cfg_out) for src, dsts in entry.items() for dst in dsts if dst not in groups]
    assert not missing, f"fallbacks naming a group with no row: {missing}"


def test_no_row_serves_a_removed_provider_again():
    # Cline and Ollama Cloud rows were removed with the owner's yes of 2026-10-23 (fleet-ops#10068). Re-adding one is the owner's call.
    bases = _bases(_router_rows())
    back = sorted({b for b in bases if b.startswith("https://api.cline.bot") or b.startswith("https://ollama.com")})
    assert not back, f"rows for removed providers are back: {back}. Re-adding them needs Nish (fleet-ops#10068)"


def test_every_thinking_budget_row_drops_caller_reasoning_effort():
    # DashScope answers 400 when a request carries reasoning_effort next to a row's thinking_budget (fleet-ops#10109).
    rows = [r for r in _model_list() if "thinking_budget" in (r["litellm_params"].get("extra_body") or {})]
    assert rows, "no row sets thinking_budget"
    bad = [r["model_info"]["id"] for r in rows if "reasoning_effort" not in r["litellm_params"].get("additional_drop_params", [])]
    assert not bad, f"rows with thinking_budget that keep a caller's reasoning_effort: {bad}"
