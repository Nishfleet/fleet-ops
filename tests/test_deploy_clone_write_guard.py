from pathlib import Path

import re

import yaml

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
CLONE_SUFFIX = "workspaces/tooling/fleet-ops-deploy-clone"
SYNC = (ROOT / "systemd/fleet-sync.service").read_text()
PULL = (ROOT / "rootfs/etc/systemd/system/fleet-deploy-sync.service").read_text()
CHAIN = (ROOT / "rootfs/etc/systemd/system/fleet-deploy.service").read_text()
BOX = yaml.safe_load((ROOT / ".github/workflows/deploy-box.yml").read_text())
POLKIT = (ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-host-config.rules").read_text()
QUADLET = (ROOT / "containers/quadlet/fleet-grafana.container").read_text()
HOST = ansible_host.play()


def _deploy_clone_task() -> dict:
    found = [
        t["ansible.builtin.file"]
        for t in HOST["tasks"]
        if "ansible.builtin.file" in t and "/workspaces/tooling/fleet-ops-deploy-clone" in t.get("ansible.builtin.file", {}).get("path", "")
    ]
    assert len(found) == 1, "exactly one host.yml task must set the mode of the user-scope deploy clone"
    return found[0]


def test_host_yml_makes_the_deploy_clone_root_owned_and_read_only_for_others() -> None:
    task = _deploy_clone_task()
    assert (task["owner"], task["group"]) == ("root", "root")
    assert task["recurse"] is True
    assert task["mode"] == "u=rwX,go=rX"


def test_fleet_sync_runs_no_git_against_the_deploy_clone() -> None:
    writers = [
        line
        for line in SYNC.splitlines()
        if line.startswith("ExecStart=") and "fleet-ops-deploy-clone" in line and re.search(r"\bgit\s+(-C\s+\S+\s+)?(fetch|pull|merge|commit|push|switch|checkout)\b", line)
    ]
    assert writers == [], (
        f"{writers}. fleet-sync runs as nish; the deploy clone is root-owned, "
        "so its fetch/merge/dirty-tree steps live in fleet-deploy-sync.service and nothing here may write to the clone"
    )


def test_fleet_deploy_sync_pulls_the_clone_as_root() -> None:
    for token in ("--no-tags origin refs/heads/main:refs/remotes/origin/main", "merge --ff-only refs/remotes/origin/main", "echo DEPLOY-BLOCKED"):
        assert token in PULL
    paths = re.findall(r"git -C (\S+?) (?:diff|fetch|merge)", PULL)
    assert paths, "the unit drives git against the deploy clone"
    assert all(p.endswith(CLONE_SUFFIX) for p in paths), f"{paths} must all point at the user-scope deploy clone"
    assert "User=" not in PULL.split("[Service]")[1], (
        "fleet-deploy-sync.service must run as root: it is the only writer the deploy clone accepts"
    )


def test_deploy_box_runs_host_config_then_pull_then_user_sync() -> None:
    steps = [s for s in BOX["jobs"]["apply"]["steps"] if s.get("run")]
    assert [s["name"] for s in steps] == [
        "Start the root deploy units in order (Ansible rootfs/, then the deploy-clone pull)",
        "Start fleet-sync.service (user-scope deploy steps)",
    ], "host config first, so every pull and link runs with the units and ownership the merge installs"
    root = steps[0]["run"]
    assert root.index("fleet-host-config.service") < root.index("fleet-deploy-sync.service")


def test_fleet_deploy_chain_matches_deploy_box_order() -> None:
    starts = [line for line in CHAIN.splitlines() if line.startswith("ExecStart=")]
    assert len(starts) == 3
    assert "fleet-host-config.service" in starts[0]
    assert "fleet-deploy-sync.service" in starts[1]
    assert "fleet-sync.service" in starts[2]


def test_polkit_lets_the_runner_start_the_pull_but_nothing_wider() -> None:
    assert '"fleet-deploy-sync.service"' in POLKIT
    assert 'indexOf(action.lookup("unit"))' in POLKIT
    assert 'action.lookup("verb") == "start"' in POLKIT
    assert 'subject.user == "nish"' in POLKIT


def test_every_grafana_mount_from_the_deploy_clone_is_read_only() -> None:
    mounts = [line for line in QUADLET.splitlines() if line.startswith("Volume=") and "fleet-ops-deploy-clone" in line]
    assert mounts, "the quadlet mounts the clone's provisioning dirs"
    assert all(line.rstrip().endswith(":ro") for line in mounts), (
        f"{[line for line in mounts if not line.rstrip().endswith(':ro')]}. "
        "the grafana container reads the root-owned clone and must not write to it"
    )
