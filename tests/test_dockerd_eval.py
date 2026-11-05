"""dockerd-eval.service and its runtime directory must agree (fleet-ops#9983)."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import ansible_host
import pytest

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
UNIT = SYSTEM / "dockerd-eval.service"
NFT = ROOT / "rootfs/etc/nftables.d/evalnet.nft"
TMPFILES = ROOT / "rootfs/etc/tmpfiles.d/dockerd-eval.conf"
CONFIG = ROOT / "rootfs/etc/fleet-ops/dockerd-eval.json"
HOST_YML = ROOT / "ansible/host.yml"
SOCKET = "/run/dockerd-eval/rt/docker.sock"
MASK_TASK = "Mask the unused root podman API socket"


def keys(path: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        if line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        found.setdefault(key, []).append(value)
    return found


def hidden(path: Path) -> set[str]:
    return {word for value in keys(path).get("InaccessiblePaths", []) for word in value.split()}


def test_the_socket_path_is_the_per_start_runtime_subdirectory() -> None:
    unit = keys(UNIT)
    assert unit["RuntimeDirectory"] == ["dockerd-eval/rt"]
    assert unit["RuntimeDirectoryMode"] == ["0700"]
    (exec_start,) = unit["ExecStart"]
    assert f"--host=unix://{SOCKET}" in exec_start
    for flag in ("--state-dir", "--exec-root", "--pidfile"):
        assert re.search(rf"{flag}=/run/dockerd-eval/rt/", exec_start), flag
    assert unit["Environment"].count("XDG_RUNTIME_DIR=/run/dockerd-eval/rt") == 1


def test_the_unit_keeps_the_prototype_flags_and_limits() -> None:
    unit = keys(UNIT)
    (exec_start,) = unit["ExecStart"]
    assert exec_start.startswith("/usr/bin/rootlesskit ")
    for flag in (
        "--net=slirp4netns",
        "--copy-up=/etc",
        "--copy-up=/run",
        "--propagation=rslave",
        "--exec-opt native.cgroupdriver=cgroupfs",
        "--host-gateway-ip=10.0.2.2",
        "--config-file=/etc/fleet-ops/dockerd-eval.json",
        "--userland-proxy-path=/usr/bin/rootlesskit-docker-proxy",
    ):
        assert flag in exec_start, flag
    assert "--disable-host-loopback" not in exec_start
    assert "$$@" in exec_start
    assert unit["Delegate"] == ["yes"]
    assert unit["MemoryMax"] == ["6G"]
    assert unit["TasksMax"] == ["4096"]
    assert unit["Restart"] == ["on-failure"]
    assert unit["StartLimitBurst"] == ["5"]
    assert unit["WantedBy"] == ["multi-user.target"]
    assert "NoNewPrivileges" not in unit


def test_the_unit_hides_the_host_sockets() -> None:
    paths = hidden(UNIT)
    for path in ("-/run/docker.sock", "-/var/run/docker.sock", "-/run/user/1000", "-/etc/restic"):
        assert path in paths, path


def test_the_engine_sees_only_its_data_root_and_rclone_under_home() -> None:
    unit = keys(UNIT)
    (tmpfs,) = unit["TemporaryFileSystem"]
    assert tmpfs.startswith("/home/nish:mode=0700,")
    assert unit["BindPaths"] == ["/home/nish/.local/share/dockerd-eval"]
    assert unit["BindReadOnlyPaths"] == ["-/home/nish/.local/bin/rclone"]


def test_tmpfiles_creates_the_runtime_parent_private_to_nish() -> None:
    lines = [line for line in TMPFILES.read_text().splitlines() if line and not line.startswith("#")]
    assert lines == [
        "d /run/dockerd-eval 0700 nish nish -",
        "d /home/nish/.local/share/dockerd-eval 0700 nish nish -",
    ]


def test_the_engine_config_is_an_empty_object() -> None:
    assert json.loads(CONFIG.read_text()) == {}


def nft_rules() -> list[str]:
    return [
        line
        for line in NFT.read_text().splitlines()
        if line.startswith("add rule inet evalnet engine_egress ")
    ]


def test_the_nft_table_matches_the_engine_cgroup_and_drops_host_local_destinations() -> None:
    text = NFT.read_text()
    assert "add table inet evalnet\n" in text
    assert "add set inet evalnet engine_cgroups { type cgroupsv2; }" in text
    assert "socket cgroupv2 level 2 @engine_cgroups jump engine_egress" in text
    rules = nft_rules()
    assert rules[0].endswith("ct state established,related return")
    assert rules[-1].endswith("engine_egress return")
    assert rules.index(next(r for r in rules if "tcp dport" in r)) < rules.index(
        next(r for r in rules if r.endswith("ip daddr 127.0.0.0/8 drop"))
    )
    joined = "\n".join(rules)
    for needle in (
        "ip daddr 127.0.0.0/8 drop",
        "ip6 daddr ::1 drop",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "ip daddr & 0xffc00000 == 0x64400000 drop",
        "fd7a:115c:a1e0::/48",
        "fc00::/7",
        "fe80::/10",
        "fib daddr type local drop",
    ):
        assert needle in joined, needle


def test_the_nft_file_is_idempotent_so_a_reload_keeps_the_set() -> None:
    text = NFT.read_text()
    assert not re.search(r"^(destroy|flush ruleset)", text, re.MULTILINE)
    assert not re.search(r"^table ", text, re.MULTILINE)
    assert "flush chain inet evalnet output" in text
    assert "flush chain inet evalnet engine_egress" in text
    conf = (ROOT / "rootfs/etc/nftables.conf").read_text()
    assert 'include "/etc/nftables.d/*.nft"' in conf
    assert "destroy table inet evalnet" not in conf


def test_the_unit_feeds_the_set_and_keeps_an_address_only_layer() -> None:
    unit = keys(UNIT)
    assert unit["NFTSet"] == ["cgroup:inet:evalnet:engine_cgroups"]
    assert "nftables.service" in unit["After"][0].split()
    assert unit["PartOf"] == ["nftables.service"]
    deny = set(unit["IPAddressDeny"][0].split())
    assert {
        "localhost",
        "link-local",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
        "fd7a:115c:a1e0::/48",
        "fc00::/7",
    } <= deny
    allow = set(unit["IPAddressAllow"][0].split())
    assert "127.0.0.1/32" in allow
    assert allow == {"127.0.0.1/32", "127.0.0.53/32", "10.0.2.0/24"}


def test_the_nft_conf_loads_the_drop_in_without_flushing_the_ruleset() -> None:
    conf = (ROOT / "rootfs/etc/nftables.conf").read_text()
    assert not re.search(r"^flush ruleset", conf, re.MULTILINE)
    assert 'include "/etc/nftables.d/*.nft"' in conf


def test_the_engine_cgroup_is_level_two() -> None:
    unit = keys(UNIT)
    assert "Slice" not in unit
    assert "DynamicUser" not in unit


def test_no_vendor_launcher_runs_the_engine() -> None:
    assert "dockerd-rootless" not in keys(UNIT)["ExecStart"][0]


def test_the_host_playbook_installs_the_nft_file_with_a_syntax_check() -> None:
    host = ansible_host.text()
    task = re.search(r"- name: Install the eval engine's egress rule\n(.*?)\n\n", host, re.DOTALL)
    assert task, "no install task"
    assert "dest: /etc/nftables.d/evalnet.nft" in task.group(1)
    assert "validate: /usr/sbin/nft -c -f %s" in task.group(1)
    assert "notify: Reload nftables" in task.group(1)


def test_podman_eval_is_retired() -> None:
    assert not (SYSTEM / "podman-eval.service").exists()
    host = ansible_host.text()
    off = re.search(r"- name: Stop and disable the retired rootless podman socket\n(.*?)\n\n", host, re.DOTALL)
    assert off, "no stop-and-disable task"
    assert "enabled: false" in off.group(1)
    assert "state: stopped" in off.group(1)
    assert "name: dockerd-eval.service" in host
    assert "- rootlesskit\n" in host
    assert "- slirp4netns\n" in host


def _mask() -> dict:
    found = [t for t in ansible_host.play()["tasks"] if t.get("name") == MASK_TASK]
    assert len(found) == 1, "one task must mask the unused root podman API socket"
    return found[0]["ansible.builtin.systemd_service"]


def test_the_unused_root_podman_api_socket_is_masked() -> None:
    assert _mask() == {"name": "podman.socket", "state": "stopped", "masked": True}


def test_no_other_play_task_touches_the_root_podman_api_socket() -> None:
    others = [t.get("name") for t in ansible_host.play()["tasks"] if t.get("name") != MASK_TASK and "podman.socket" in str(t)]
    assert not others, others


def test_the_host_playbook_keeps_the_tasks_this_change_must_not_drop() -> None:
    host = ansible_host.text()
    assert host.count("alertmanager_credentials is defined and (") == 4


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_reports_no_unknown_directive(tmp_path: Path) -> None:
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", str(UNIT)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    unknown = [
        line
        for line in (proc.stdout + proc.stderr).splitlines()
        if "Unknown key" in line or "Unknown section" in line
    ]
    assert unknown == [], "\n".join(unknown)
