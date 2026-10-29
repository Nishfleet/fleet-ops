import json
import pathlib
import re
import shutil
import subprocess
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")

IDLE_WINDOW = {
    "ppi-commandcode": ("24h", "24h"),
    "ppi-minimax": ("72h", "72h"),
    "ppi-stepfun": ("24h", "24h"),
    "ppi-zai": ("24h", "24h"),
    "ppi-opencode-go": ("24h", "24h"),
    "ppi-alibaba": ("7d", "24h"),
}


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


SINGLE_ROW_TIERS = {"tether", "assistant"}


def test_every_router_tier_keeps_two_deployments_and_every_fallback_target_exists():
    assert YQ, "yq must be on PATH to read the router config"
    cfg_out = subprocess.run([YQ, "-o=json", ".router_settings.fallbacks", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    tiers = {}
    for row in _model_list():
        tiers[row["model_name"]] = tiers.get(row["model_name"], 0) + 1
    thin = {t: n for t, n in tiers.items() if n < (1 if t in SINGLE_ROW_TIERS else 2)}
    assert not thin, f"router tiers below their floor (2 rows, tether and assistant 1): {thin}. Only tether and assistant may hold one row (fleet-ops#9980; assistant since OpenCode Go key 2 left on 2026-10-26, and it falls to worker-capable)"
    groups = {row["model_name"] for row in _model_list()}
    missing = [(src, dst) for entry in json.loads(cfg_out) for src, dsts in entry.items() for dst in dsts if dst not in groups]
    assert not missing, f"fallbacks naming a group with no row: {missing}"


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


def _idle_rules():
    assert YQ, "yq must be on PATH to read the alert rule config"
    out = subprocess.run([YQ, "-o=json", ".groups[].rules", str(ROOT / "config/grafana/provisioning/alerting/paid-plan-idle.yaml")], capture_output=True, text=True, check=True).stdout
    return {rule["uid"]: rule for rule in json.loads(out)}


def _window_seconds(window):
    number, unit = re.fullmatch(r"(\d+)([hd])", window).groups()
    return int(number) * (86400 if unit == "d" else 3600)


def _named_windows(summary):
    return [number + ("d" if unit == "day" else "h") for number, unit in re.findall(r"for (\d+) (hour|day)s?", summary)]


def test_every_paid_plan_idle_rule_reads_the_window_its_message_names():
    rules = _idle_rules()
    assert sorted(rules) == sorted(IDLE_WINDOW), f"paid-plan idle rules changed: {sorted(set(rules) ^ set(IDLE_WINDOW))}"
    bases = {plan["api_base"] for plan in _plans()}
    wrong = {}
    for uid, (idle, absent) in IDLE_WINDOW.items():
        rule = rules[uid]
        expr = rule["data"][0]["model"]["expr"]
        base = re.search(r'api_base=~"([^"]+)"', expr)
        shape = {
            "plan": (base.group(1).removesuffix(".*") if base else "") in bases,
            "summary says": _named_windows(rule["annotations"]["summary"]),
            "increase": sorted(re.findall(r"increase\([^\[]*\[([^\]]+)\]", expr)),
            "absence": sorted(re.findall(r"absent_over_time\([^\[]*\[([^\]]+)\]", expr)),
            "offset": sorted(re.findall(r"\boffset\s+(\w+)", expr)),
            "range": rule["data"][0]["relativeTimeRange"]["from"],
        }
        wanted = {
            "plan": True,
            "summary says": [idle] if idle == absent else [idle, absent],
            "increase": [idle],
            "absence": [absent],
            "offset": [idle],
            "range": 2 * _window_seconds(idle),
        }
        if shape != wanted:
            wrong[uid] = (shape, wanted)
    assert not wrong, f"an idle rule and the alert message it sends disagree (MiniMax 72h is fleet-ops#10431, Alibaba 7d idle is fleet-ops#9865): {wrong}"


def test_every_thinking_budget_row_drops_caller_reasoning_effort():
    # DashScope answers 400 when a request carries reasoning_effort next to a row's thinking_budget (fleet-ops#10109).
    rows = [r for r in _model_list() if "thinking_budget" in (r["litellm_params"].get("extra_body") or {})]
    assert rows, "no row sets thinking_budget"
    bad = [r["model_info"]["id"] for r in rows if "reasoning_effort" not in r["litellm_params"].get("additional_drop_params", [])]
    assert not bad, f"rows with thinking_budget that keep a caller's reasoning_effort: {bad}"
