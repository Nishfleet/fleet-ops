import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _router_groups():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return {row["model_name"] for row in json.loads(out)}


def test_every_group_pi_offers_on_the_router_has_a_row():
    pi = json.loads((ROOT / "config/pi-models.json").read_text())
    offered = {m["id"] for m in pi["providers"]["litellm"]["models"]}
    missing = sorted(offered - _router_groups())
    assert not missing, f"config/pi-models.json offers router groups with no row in config/litellm-proxy.yaml: {missing}"
