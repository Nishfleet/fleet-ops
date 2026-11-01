import json
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")


def _router_groups():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return {row["model_name"] for row in json.loads(out)}


def _router_aliases():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".router_settings.model_group_alias // {}", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def test_every_group_pi_offers_on_the_router_has_a_row():
    pi = json.loads((ROOT / "config/pi-models.json").read_text())
    offered = {m["id"] for m in pi["providers"]["litellm"]["models"]}
    missing = sorted(offered - _router_groups() - set(_router_aliases()))
    assert not missing, f"config/pi-models.json offers router groups with no row in config/litellm-proxy.yaml: {missing}"


def test_every_alias_renames_a_real_group():
    aliases = _router_aliases()
    assert aliases, "the desk arm reads config/litellm-proxy.yaml model_group_alias; keep the map in that file"
    groups = _router_groups()
    dangling = sorted(f"{alias} -> {target}" for alias, target in aliases.items() if target not in groups)
    assert not dangling, f"model_group_alias renames a group that has no row: {dangling}"
    shadowing = sorted(set(aliases) & groups)
    assert not shadowing, f"an alias name is also a model_name, so the alias is dead config: {shadowing}"


NO_ROW = {
    "litellm": "the passthrough provider: pi calls the router itself, so no row can serve it",
    "xai-oauth": "Nish's own SuperGrok login, billed to his subscription and not to a router row",
}


def _router_providers():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    providers = set()
    for row in json.loads(out):
        key = str(row["litellm_params"].get("api_key", ""))
        if key.startswith("os.environ/"):
            providers.add(re.sub(r"-api-key", "", key.split("/", 1)[1].lower().replace("_", "-")))
    return providers


def test_every_provider_pi_offers_has_a_live_router_row():
    pi = json.loads((ROOT / "config/pi-models.json").read_text())
    dead = sorted(p for p in pi["providers"] if p not in _router_providers() and p not in NO_ROW)
    assert not dead, (
        f"config/pi-models.json lists providers that no row in config/litellm-proxy.yaml serves: {dead}. "
        "Delete the provider, add it to NO_ROW above with the reason it needs no row, or make a row's key "
        "derive this name (PARETO_API_KEY derives pareto)."
    )
    assert set(NO_ROW) <= set(pi["providers"]), sorted(set(NO_ROW) - set(pi["providers"]))
