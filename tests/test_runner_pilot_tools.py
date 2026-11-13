"""The pilot runner's PATH holds only root-owned folders, readable by every user (fleet-ops#11959, #11990).

Every runner shares one user and home, so a job could leave a tool in the home's bin folder
that every later job ran. The pilot's pi and check tools are installed by the play into one
root-owned folder outside the home, and runner 22's .path points at it.
Design: docs/design/ephemeral-runners.md, "Where the reset happens".
"""
import pathlib

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOME = "/var/lib/fleet-runner"


def _vars():
    return ansible_host.play()["vars"]


def _render(value):
    """Expand {{ name }} against the play's vars, until no reference is left."""
    for _ in range(10):
        start = value.find("{{")
        if start == -1:
            return value
        end = value.find("}}", start)
        name = value[start + 2:end].strip()
        value = value[:start] + _vars()[name] + value[end + 2:]
    raise AssertionError("the render does not end")


def test_every_folder_on_path_is_root_owned_and_outside_the_home():
    path = _render(_vars()["fleet_pilot_path"]).split(":")
    tools = _vars()["fleet_pilot_tools"]
    assert not any(folder.startswith(HOME + "/") for folder in path), "no folder in the home may go on PATH"
    assert f"{tools}/venv/bin" in path and f"{tools}/bin" in path, path
    assert _render(_vars()["tether_node_dir"]) + "/bin" in path, "npm and npx come from the pinned Node"
    assert all(folder in {"/usr/local/bin", "/usr/bin", "/bin"} or folder.startswith("/opt/")
               for folder in path), path


def test_the_play_installs_the_pinned_tools_into_the_root_owned_folder():
    tasks = ansible_host.text()
    pins = ["ansible-lint==26.11.0", "black==26.10.1", "pytest==8.3.5", "ruff==0.17.3",
            "semgrep==1.183.0", "yamllint==1.38.0", "zizmor==1.32.0", "uv==0.13.7"]
    for pin in pins:
        assert pin in tasks, pin
    assert 'virtualenv: "{{ fleet_pilot_tools }}/venv"' in tasks, "the pip tools go into the folder's venv"
    for vendor in ["actionlint_1.7.12_linux_amd64.tar.gz",
                   "sha256:8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
                   "mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64",
                   "sha256:a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"]:
        assert vendor in tasks, vendor
    assert '--prefix, "{{ fleet_pilot_tools }}"' in tasks, "pi is installed into the folder, not the home"
    assert 'content: "{{ fleet_pilot_path if item == 22 else' in tasks, (
        "runner 22's .path is the pilot PATH")


def test_the_shared_template_is_not_changed_by_the_pilot():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    assert "TemporaryFileSystem" not in unit


def test_the_pilot_drop_in_is_gone_and_retired():
    assert not (ROOT / "rootfs/etc/systemd/system/fleet-runner@22.service.d").exists()
    assert "/etc/systemd/system/fleet-runner@22.service.d" in _vars()["retired"]


def test_the_tools_folder_is_listable_by_all_and_writable_by_root_only():
    tasks = ansible_host.text()
    start = tasks.index("- name: Make the pilot tools folder readable by every user")
    block = tasks[start:tasks.index("\n\n", start)]
    for line in ['path: "{{ fleet_pilot_tools }}"', "recurse: true", "owner: root",
                 "group: root", 'mode: "u=rwX,g=rX,o=rX"']:
        assert line in block, line
