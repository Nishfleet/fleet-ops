"""dockerd-eval.service, its runtime directory and the fleet-ci-3 drop-in must agree (fleet-ops#9983)."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
UNIT = SYSTEM / "dockerd-eval.service"
CI3 = SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-3.service.d/30-eval.conf"
OTHER_POOLS = [
    SYSTEM / "actions.runner.Nishfleet.netcup-agent-.service.d/20-lockdown.conf",
    SYSTEM / "actions.runner.nish3451-nish-vault.netcup-vault-1.service.d/20-lockdown.conf",
    SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-1.service.d/25-no-eval.conf",
    SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-2.service.d/25-no-eval.conf",
]
NFT = ROOT / "rootfs/etc/nftables.d/evalnet.nft"
TMPFILES = ROOT / "rootfs/etc/tmpfiles.d/dockerd-eval.conf"
CONFIG = ROOT / "rootfs/etc/fleet-ops/dockerd-eval.json"
HOST_YML = ROOT / "ansible/host.yml"
SOCKET = "/run/dockerd-eval/rt/docker.sock"


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


def test_docker_host_in_the_ci3_drop_in_matches_the_socket() -> None:
    drop_in = keys(CI3)
    assert f"DOCKER_HOST=unix://{SOCKET}" in drop_in["Environment"]
    assert "DRIVE_EVAL_SANDBOX_HOST=10.0.2.2" in drop_in["Environment"]


def test_ci3_orders_after_dockerd_eval_and_no_longer_names_podman() -> None:
    text = CI3.read_text()
    assert "After=dockerd-eval.service" in text
    assert "Wants=dockerd-eval.service" in text
    assert not re.search(r"^(After|Wants|Environment)=.*podman", text, re.M)


def test_ci3_binds_promptfoo_writable_and_rclone_read_only() -> None:
    drop_in = keys(CI3)
    assert "-/home/nish/.promptfoo" in drop_in["BindPaths"][0].split()
    assert "-/home/nish/.local/bin/rclone" in drop_in["BindReadOnlyPaths"][0].split()


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


def test_the_unit_hides_credentials_sockets_and_the_old_stores() -> None:
    paths = hidden(UNIT)
    for path in (
        "-/run/docker.sock",
        "-/var/run/docker.sock",
        "-/run/user/1000",
        "-/etc/restic",
        "-/home/nish/.local/share/containers/storage",
        "-/home/nish/.local/share/podman-eval",
        "-/home/nish/.ssh",
    ):
        assert path in paths, path
    visible = ("/home/nish/.local/share/dockerd-eval", "/home/nish/.local/bin/rclone", "_work")
    assert not [p for p in paths if any(v in p for v in visible)]


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


@pytest.mark.parametrize("path", OTHER_POOLS, ids=lambda p: p.parent.name)
def test_other_pools_hide_the_retired_and_engine_sockets(path: Path) -> None:
    assert "-/run/dockerd-eval" in hidden(path)
    assert "-/run/podman-eval" in hidden(path)


def test_the_eval_runner_does_not_hide_the_engine_directory() -> None:
    base = SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-.service.d/20-lockdown.conf"
    for path in (base, CI3):
        assert "-/run/dockerd-eval" not in hidden(path)
        assert "-/run/dockerd-eval/rt" not in hidden(path)


def nft_rules() -> list[str]:
    return [
        line
        for line in NFT.read_text().splitlines()
        if line.startswith("add rule inet evalnet engine_egress ")
    ]


def test_the_stand_in_port_is_the_same_in_the_drop_in_and_the_nft_rule() -> None:
    (port,) = [v for v in keys(CI3)["Environment"] if v.startswith("DRIVE_EVAL_STANDIN_PORT=")]
    number = port.split("=", 1)[1]
    assert number.isdigit() and 1024 <= int(number) <= 65535
    assert f"add rule inet evalnet engine_egress ip daddr 127.0.0.1 tcp dport {number} return" in nft_rules()
    assert [r for r in nft_rules() if "dport" in r and "th dport 53" not in r] == [
        f"add rule inet evalnet engine_egress ip daddr 127.0.0.1 tcp dport {number} return"
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
    assert not re.search(r"^(destroy|flush ruleset)", text, re.M)
    assert not re.search(r"^table ", text, re.M)
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


def test_the_comment_does_not_claim_a_bridge_range_is_allowed() -> None:
    text = UNIT.read_text()
    assert "the Docker bridge networks, which are not host addresses" not in text
    assert "network_mode: host" in text


def test_the_nft_comment_matches_how_nftables_conf_loads_it() -> None:
    conf = (ROOT / "rootfs/etc/nftables.conf").read_text()
    assert not re.search(r"^flush ruleset", conf, re.M)
    assert 'include "/etc/nftables.d/*.nft"' in conf
    assert "fleet-ops#8258" in NFT.read_text()


def test_the_engine_cgroup_is_level_two() -> None:
    unit = keys(UNIT)
    assert "Slice" not in unit
    assert "DynamicUser" not in unit


def test_the_unit_comment_explains_why_there_is_no_vendor_launcher() -> None:
    text = UNIT.read_text()
    assert "dockerd-rootless.sh" in text
    assert "docker-ce-rootless-extras" in text
    assert "docs.docker.com/engine/security/rootless" in text
    assert "dockerd-rootless" not in keys(UNIT)["ExecStart"][0]


def test_the_host_playbook_installs_the_nft_file_with_a_syntax_check() -> None:
    host = HOST_YML.read_text()
    task = re.search(r"- name: Install the eval engine's egress rule\n(.*?)\n\n", host, re.S)
    assert task, "no install task"
    assert "dest: /etc/nftables.d/evalnet.nft" in task.group(1)
    assert "validate: /usr/sbin/nft -c -f %s" in task.group(1)
    assert "notify: Reload nftables" in task.group(1)


def test_podman_eval_is_retired() -> None:
    assert not (SYSTEM / "podman-eval.service").exists()
    host = HOST_YML.read_text()
    assert "- /etc/systemd/system/podman-eval.service" in host
    off = re.search(r"- name: Stop and disable the retired rootless podman socket\n(.*?)\n\n", host, re.S)
    assert off, "no stop-and-disable task"
    assert "enabled: false" in off.group(1)
    assert "state: stopped" in off.group(1)
    assert "name: dockerd-eval.service" in host
    assert "- rootlesskit\n" in host
    assert "- slirp4netns\n" in host


def test_the_host_playbook_keeps_the_tasks_this_change_must_not_drop() -> None:
    host = HOST_YML.read_text()
    assert host.count("alertmanager_credentials is defined and (") == 4
    watcher = re.search(r"- name: Enable the deploy request watcher\n(.*?)\n\n", host, re.S)
    assert watcher, "no deploy request watcher task"
    assert "name: fleet-deploy.path" in watcher.group(1)
    assert "enabled: true" in watcher.group(1)
    assert "state: started" in watcher.group(1)


def test_a_failed_engine_start_is_reported_in_the_run_output() -> None:
    host = HOST_YML.read_text()
    task = re.search(r"- name: Enable the rootless Docker engine for the drive eval\n(.*?)\n\n", host, re.S)
    assert task, "no engine enable task"
    assert "register: dockerd_eval_up" in task.group(1)
    report = re.search(r"- name: Report a rootless Docker engine that did not start\n(.*?)\n\n", host, re.S)
    assert report, "no report task"
    assert "ansible.builtin.debug" in report.group(1)
    assert "when: dockerd_eval_up is failed" in report.group(1)
    assert "dockerd_eval_up.msg" in report.group(1)


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
