import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PI = json.loads((ROOT / "config/pi-models.json").read_text())


def test_no_pi_provider_reads_the_master_key():
    keys = [str(p.get("apiKey", "")) for p in PI["providers"].values()]
    assert not [k for k in keys if "litellm-master-key" in k]
    assert PI["providers"]["litellm"]["apiKey"].endswith("seats/litellm-agent.env")
