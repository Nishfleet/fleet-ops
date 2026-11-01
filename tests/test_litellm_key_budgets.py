import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUDGETS = json.loads((ROOT / "config/litellm-key-budgets.json").read_text())
PI = json.loads((ROOT / "config/pi-models.json").read_text())


def test_every_standing_router_key_carries_a_daily_cap():
    assert set(BUDGETS) == {"jev-eval", "fleet-agent"}
    for alias, entry in BUDGETS.items():
        assert entry["max_budget"] > 0, alias
        assert entry["budget_duration"] == "1d", alias


def test_the_pi_lane_key_is_scoped_to_the_worker_and_judge_groups():
    assert BUDGETS["fleet-agent"]["models"] == ["worker-capable", "worker-cheap", "judge"]
    assert BUDGETS["fleet-agent"]["duration"] == "30d"


def test_no_pi_provider_reads_the_master_key():
    keys = [str(p.get("apiKey", "")) for p in PI["providers"].values()]
    assert not [k for k in keys if "litellm-master-key" in k]
    assert PI["providers"]["litellm"]["apiKey"].endswith("seats/litellm-agent.env")
