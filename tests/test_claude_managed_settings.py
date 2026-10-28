"""Every Claude Code managed-settings file parses, ships from the repo and is installed.

A drop-in that does not parse stops Claude Code from starting on the whole box,
so each file must be a JSON object, and the same file must be installed by a
host.yml task that runs that same check before the file reaches /etc. A plugin id
is `name@marketplace`: the
marketplace half must be one the box knows, either because a drop-in declares it
in `extraKnownMarketplaces` or because the box already registered it. When the
marketplace's directory is on disk (this box, or a runner with the checkout) the
plugin name is read out of that marketplace's own manifest, so an id no
marketplace lists fails here instead of at Claude Code start-up.
"""
import json
import pathlib

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANAGED_TREE = ROOT / "rootfs/etc/claude-code"
DROPINS = ROOT / "rootfs/etc/claude-code/managed-settings.d"
JSON_OBJECT_GATE = "import json,sys; sys.exit(0 if isinstance(json.load(open(sys.argv[1])), dict) else 1)"
HOST_MARKETPLACES = pathlib.Path.home() / ".claude/plugins/known_marketplaces.json"


def _dropins():
    return sorted(DROPINS.glob("*.json"))


def _load(path):
    data = json.loads(path.read_text())
    assert isinstance(data, dict), f"{path.name} is not a JSON object"
    return data


def _known_marketplaces():
    known = {}
    for path in _dropins():
        known.update(_load(path).get("extraKnownMarketplaces", {}))
    if HOST_MARKETPLACES.is_file():
        known.update(json.loads(HOST_MARKETPLACES.read_text()))
    return known


def _enabled():
    enabled = {}
    for path in _dropins():
        for plugin_id in _load(path).get("enabledPlugins", {}):
            enabled[plugin_id] = path.name
    return enabled


def test_the_repo_ships_at_least_one_drop_in():
    assert _dropins(), f"no drop-in under {DROPINS}"


@pytest.mark.parametrize("path", _dropins(), ids=lambda p: p.name)
def test_every_drop_in_is_a_json_object(path):
    _load(path)


def test_every_enabled_plugin_names_a_known_marketplace():
    known = _known_marketplaces()
    bad = {f"{p} (in {f})": sorted(known) for p, f in _enabled().items() if p.split("@")[-1] not in known}
    assert not bad, f"enabled plugins from an unknown marketplace: {bad}"


def test_the_nish_mods_drop_in_declares_its_marketplace():
    declared = {name for path in _dropins() for name in _load(path).get("extraKnownMarketplaces", {})}
    for plugin_id in _enabled():
        if plugin_id.endswith("@nish-mods"):
            assert "nish-mods" in declared, "a nish-mods plugin is enabled but no drop-in declares the marketplace"


def test_every_enabled_plugin_is_listed_in_its_marketplace_manifest():
    known = _known_marketplaces()
    for plugin_id in _enabled():
        name, _, marketplace = plugin_id.rpartition("@")
        source = known.get(marketplace, {}).get("source", {})
        if source.get("source") != "directory":
            continue
        manifest = pathlib.Path(source["path"]) / ".claude-plugin/marketplace.json"
        if not manifest.is_file():
            continue
        listed = {p["name"] for p in json.loads(manifest.read_text())["plugins"]}
        assert name in listed, f"{plugin_id} is enabled but {manifest} lists {sorted(listed)}"


def _managed_copies():
    plays = yaml.safe_load((ROOT / "ansible/host.yml").read_text())
    tasks = [task for play in plays for task in play.get("tasks", [])]
    copies = [t["ansible.builtin.copy"] for t in tasks if "ansible.builtin.copy" in t and t["ansible.builtin.copy"].get("dest", "").startswith("/etc/claude-code/")]
    return tasks, copies


def test_every_managed_settings_file_is_shipped_and_installed_by_a_gated_task():
    _, copies = _managed_copies()
    assert copies, "no host.yml copy task installs anything under /etc/claude-code/"
    for copy in copies:
        assert JSON_OBJECT_GATE in copy["validate"], f"{copy['dest']} is installed without the JSON-object gate"
        assert copy["owner"] == "root" and copy["group"] == "root", copy["dest"]
        assert copy["mode"] == "preserve", copy["dest"]

    def installed(path):
        src = "{{ rootfs }}/" + path.relative_to(ROOT / "rootfs").as_posix()
        return any(copy.get("src") == src or (copy.get("src", "").endswith("/") and src.startswith(copy["src"])) for copy in copies)

    files = sorted(p for p in MANAGED_TREE.rglob("*") if p.is_file())
    assert files, f"no files under {MANAGED_TREE}"
    for path in files:
        assert isinstance(json.loads(path.read_text()), dict), f"{path.relative_to(ROOT)} is not a JSON object"
        assert installed(path), f"{path.relative_to(ROOT)} is installed by no /etc/claude-code copy task"


def test_the_box_wide_defaults_file_is_installed_as_itself():
    tasks, _ = _managed_copies()
    task = next((t for t in tasks if t.get("name") == "Install the Claude Code managed-settings defaults file"), None)
    assert task, "no task installs the box-wide managed-settings.json"
    assert task["ansible.builtin.copy"]["src"] == "{{ rootfs }}/etc/claude-code/managed-settings.json"
    assert task["ansible.builtin.copy"]["dest"] == "/etc/claude-code/managed-settings.json"
