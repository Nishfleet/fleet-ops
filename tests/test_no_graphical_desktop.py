"""The box has no graphical desktop: the play purges it and installs none of it (fleet-ops#10935)."""
import json
import subprocess
import shutil

import pytest
import ansible_host

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

PLAY = json.loads(subprocess.run(["yq", "-o=json", "."], input=ansible_host.text(), capture_output=True, text=True, check=True).stdout)[0]
APT = [t for t in PLAY["tasks"] if "ansible.builtin.apt" in t and t["ansible.builtin.apt"].get("name")]
DESKTOP = {"plasma-desktop", "plasma-workspace", "kwin-x11", "xfce4-panel", "xfwm4", "tigervnc-standalone-server", "xrdp", "xorg", "dbus-x11"}


def test_the_desktop_is_purged():
    task = next(t for t in APT if t["name"] == "Remove the graphical desktop")["ansible.builtin.apt"]
    assert task["state"] == "absent" and task["purge"] and task["autoremove"]
    assert DESKTOP <= set(task["name"])


def test_no_task_installs_a_desktop_package():
    for t in APT:
        if t["ansible.builtin.apt"].get("state", "present") != "absent":
            assert not DESKTOP & set(t["ansible.builtin.apt"]["name"]), t["name"]
