import json
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _model_list():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def _budgets():
    return json.loads((ROOT / "config/litellm-key-budgets.json").read_text())


def _agent_yml():
    return (ROOT / ".github/workflows/agent.yml").read_text()


def _dispatch_yml():
    return (ROOT / ".github/workflows/agent-dispatch.yml").read_text()


def test_budgets_entry_shape():
    budgets = _budgets()
    assert budgets, "config/litellm-key-budgets.json must carry at least the jev-eval cap"
    for alias, entry in budgets.items():
        assert re.fullmatch(r"[a-z0-9][a-z0-9-]*", alias), alias
        assert isinstance(entry["max_budget"], (int, float)) and entry["max_budget"] > 0, alias
        assert re.fullmatch(r"\d+[dhmo]", entry["budget_duration"]), alias
        assert entry["source"], alias


def test_jev_eval_cap_is_the_owner_value():
    jev = _budgets()["jev-eval"]
    assert jev["max_budget"] == 2.0 and jev["budget_duration"] == "1d"
    assert "owner" in jev["source"], "changing the jev-eval cap needs an owner decision"


def test_live_budget_probe_guards_the_review_job():
    run = _agent_yml()
    assert "litellm-key-budgets.json" in run, "the review job must compare the live key against the reviewed budgets"
    assert "budget-drift on jev-eval" in run, "a drifted live key must fail the review loudly"
    assert "/key/info" in run, "the probe must be a GET that holds no spend"
    assert run.index("budget-drift on jev-eval") < run.index("scan() { local r"), "the probe must run before any model spend"


def test_pi_lane_resolves_the_seat_key_not_the_master_key():
    pi = json.loads((ROOT / "config/pi-models.json").read_text())
    key = pi["providers"]["litellm"]["apiKey"]
    assert "seats/litellm-agent.env" in key, f"the pi lane must read the scoped seat key, got: {key}"
    assert "litellm-master-key" not in key, "the pi lane must never resolve the master key"
    assert not any("litellm-master-key" in str(model) for model in pi["providers"]["litellm"]["models"])


def test_orchestrator_jail_hides_fleet_ops_and_binds_only_seats():
    dispatch = _dispatch_yml()
    step = dispatch.split("- name: Run the orchestrator session", 1)[1]
    assert '--tmpfs "$HOME/.config/fleet-worker"' in step, "the orchestrator jail keeps its existing hides"
    assert '--tmpfs "$HOME/.config/fleet-ops"' in step, "the #11272 hole: the jail left ~/.config/fleet-ops readable"
    assert 'seats/litellm-agent.env' in step, "exactly the litellm-agent seat reaches the session"
    assert step.count("litellm-master-key.env") >= 1, "the mint step itself must read the master key from the host, outside the jail"
    master_in_jail = re.search(r'jail=\(bwrap[^\n]*litellm-master-key', step)
    assert not master_in_jail, "the master key must never be bound into the session jail"


def test_worker_lane_binds_the_run_key_at_the_seat_path():
    run = _agent_yml()
    assert "LITELLM_AGENT_KEY=" in run, "the minted inish-daily key installs the LITELLM_AGENT_KEY the seat path serves"
    assert '--ro-bind "$router_key" "$HOME/.config/fleet-ops/seats/litellm-agent.env"' in run, "the worker jail binds the run key at the seat path"
    assert '--ro-bind "$router_key" "$HOME/.config/fleet-ops/litellm-master-key.env"' not in run, "no lane binds the master key file into a jail"


def test_prepaid_assistant_rows_never_carry_list_price():
    rows = [row["litellm_params"] for row in _model_list() if row.get("model_name") == "assistant"]
    prepaid = [r for r in rows if "prepaid" in (r.get("tags") or [])]
    assert prepaid, "the assistant fallback must still carry its prepaid MiniMax row"
    for r in prepaid:
        assert float(r.get("input_cost_per_token", 0)) == 0, r
        assert float(r.get("output_cost_per_token", 0)) == 0, r
        assert float(r.get("cache_read_input_token_cost", 0)) == 0, r
        assert float(r.get("cache_creation_input_token_cost", 0)) == 0, r


def test_prepaid_assistant_row_is_only_the_flat_provider():
    watch = json.loads((ROOT / "config/provider-watch.json").read_text()).get("minimax", {})
    assert watch.get("billing") == "flat", "the flat-billing provider decides which prepaid row may record zero cost"
    rows = [row["litellm_params"] for row in _model_list() if row.get("model_name") == "assistant"]
    for r in rows:
        if "minimax.io" in r.get("api_base", ""):
            assert "prepaid" in (r.get("tags") or []), r
            assert float(r.get("input_cost_per_token", 0)) == 0 and float(r.get("output_cost_per_token", 0)) == 0, r
