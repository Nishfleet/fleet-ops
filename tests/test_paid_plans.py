import json
import pathlib
import re
import shutil
import subprocess
import urllib.parse

import yaml

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
    pi = json.loads((ROOT / "config/pi-models.json").read_text())
    pi_bases = [p.get("baseUrl", "") for p in pi["providers"].values()]
    gone = [
        p["name"] for p in _plans()
        if not p.get("rows_pending")
        and not any(b.startswith(p["api_base"]) for b in (bases if p.get("via") != "pi-provider" else pi_bases))
    ]
    assert not gone, f"paid plans with no router row: {gone}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"


def test_every_prepaid_row_is_a_listed_plan():
    plans = [p["api_base"] for p in _plans()]
    unlisted = sorted({b for b in _bases(_router_rows(), prepaid_only=True) if not any(b.startswith(p) for p in plans)})
    assert not unlisted, f"prepaid rows not in config/paid-plans.json: {unlisted}. Changing config/paid-plans.json needs Nish (CODEOWNERS)"


SINGLE_ROW_TIERS = {"tether", "assistant", "review-claude", "review-qwen"}


def test_every_router_tier_keeps_two_deployments_and_every_fallback_target_exists():
    assert YQ, "yq must be on PATH to read the router config"
    cfg_out = subprocess.run([YQ, "-o=json", ".router_settings.fallbacks", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    tiers = {}
    for row in _model_list():
        tiers[row["model_name"]] = tiers.get(row["model_name"], 0) + 1
    thin = {t: n for t, n in tiers.items() if n < (1 if t in SINGLE_ROW_TIERS else 2)}
    assert not thin, f"router tiers below their floor (2 rows, tether and assistant 1): {thin}. Only tether, assistant, review-claude and review-qwen (review-claude falls back to review-qwen, and review-qwen to nothing, owner 2026-11-04) may hold one row (fleet-ops#9980; assistant since OpenCode Go key 2 left on 2026-10-26, and it falls to worker-capable)"
    groups = {row["model_name"] for row in _model_list()}
    missing = [(src, dst) for entry in json.loads(cfg_out) for src, dsts in entry.items() for dst in dsts if dst not in groups]
    assert not missing, f"fallbacks naming a group with no row: {missing}"


def test_paid_plan_idle_alert_covers_every_paid_router_endpoint():
    """PaidPlanIdle (rootfs/etc/prometheus/fleet_rules.yml) watches the router-facing plans by hardcoding
    their api_base values in a regex, because Prometheus cannot read config/paid-plans.json; this test is
    the pair's guard, like test_every_live_paid_plan_keeps_a_router_row (fleet-ops#11845).
    """
    alerts = [r for g in yaml.safe_load((ROOT / "rootfs/etc/prometheus/fleet_rules.yml").read_text())["groups"] for r in g["rules"] if r.get("alert") == "PaidPlanIdle"]
    assert len(alerts) == 1, "PaidPlanIdle is missing from fleet_rules.yml"
    match = re.search(r'api_base=~"([^"]+)"', alerts[0]["expr"])
    assert match, "PaidPlanIdle must select endpoints by the router's api_base label"
    # The expr is a PromQL string: "\\." there is the regex "\\.".
    pattern = match.group(1).replace("\\\\", "\\")
    uncovered = [
        p["name"] for p in _plans()
        if p.get("via") != "pi-provider" and not re.fullmatch(pattern, p["api_base"] + "/v1/messages")
    ]
    assert not uncovered, f"paid plans PaidPlanIdle does not watch: {uncovered}. Add the plan's api_base to its regex in rootfs/etc/prometheus/fleet_rules.yml; plans marked `via` are out of scope"


REMOVED_PROVIDER_HOSTS = frozenset({"api.cline.bot", "ollama.com"})


def _removed_provider_host(base):
    return (urllib.parse.urlparse(base).hostname or "").rstrip(".")


def _removed_provider_rows(bases):
    return sorted({b for b in bases if _removed_provider_host(b) in REMOVED_PROVIDER_HOSTS})


def test_no_row_serves_a_removed_provider_again():
    back = _removed_provider_rows(_bases(_router_rows()))
    assert not back, f"rows for removed providers are back: {back}. Re-adding them needs Nish (fleet-ops#10068)"


def test_removed_provider_match_is_exact_on_hostname():
    bases = [
        "https://api.cline.bot/v1",
        "https://ollama.com/v1",
        "https://ollama.com./v1",
        "https://api.cline.bot.evil.example/v1",
        "https://ollama.com.evil.example/v1",
        "https://api.openai.com/v1",
    ]
    back = _removed_provider_rows(bases)
    assert back == ["https://api.cline.bot/v1", "https://ollama.com./v1", "https://ollama.com/v1"], f"removed provider match is not exact on the parsed hostname: {back}"


def test_every_thinking_budget_row_drops_caller_reasoning_effort():
    # DashScope answers 400 when a request carries reasoning_effort next to a row's thinking_budget (fleet-ops#10109).
    rows = [r for r in _model_list() if "thinking_budget" in (r["litellm_params"].get("extra_body") or {})]
    assert rows, "no row sets thinking_budget"
    bad = [r["model_info"]["id"] for r in rows if "reasoning_effort" not in r["litellm_params"].get("additional_drop_params", [])]
    assert not bad, f"rows with thinking_budget that keep a caller's reasoning_effort: {bad}"
