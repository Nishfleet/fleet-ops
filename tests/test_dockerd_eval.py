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
def test_every_other_pool_hides_the_engine_directory(path: Path) -> None:
    assert "-/run/dockerd-eval" in hidden(path)
    assert "-/run/podman-eval" in hidden(path)


def test_the_eval_runner_does_not_hide_the_engine_directory() -> None:
    base = SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-.service.d/20-lockdown.conf"
    for path in (base, CI3):
        assert "-/run/dockerd-eval" not in hidden(path)
        assert "-/run/dockerd-eval/rt" not in hidden(path)


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
