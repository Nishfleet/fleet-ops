"""A unit file with an unknown directive must fail CI: systemd skips it with a warning and exit 0 (fleet-ops#9967)."""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALLED = ROOT / "rootfs/etc/systemd/system"
DASH_PREFIXED_KEY = re.compile(r"^-[A-Za-z]+=")


def unit_files() -> list[Path]:
    found = []
    for pattern in ("systemd/*.service", "systemd/*.timer", "systemd/*.path", "systemd/*.slice"):
        found += sorted(ROOT.glob(pattern))
    found += sorted(INSTALLED.glob("*.slice"))
    found += sorted(INSTALLED.glob("fleet-host-config.*"))
    found += sorted(INSTALLED.glob("fleet-update.*"))
    found += sorted(INSTALLED.glob("tether-*"))
    return [path for path in found if path.is_file()]


@pytest.mark.parametrize("unit", unit_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_no_directive_starts_with_the_ignore_failure_dash(unit: Path) -> None:
    offenders = [line for line in unit.read_text().splitlines() if DASH_PREFIXED_KEY.match(line)]
    assert offenders == [], (
        f"{unit.relative_to(ROOT)}: {offenders}. The ignore-failure prefix goes after the '=' "
        "as ExecStart=-command, not in front of the key."
    )


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_reports_no_unknown_directive() -> None:
    files = [str(path) for path in unit_files()]
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", *files],
        cwd=ROOT,
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


TETHER = INSTALLED / "tether-agent.service"


def _tether_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in TETHER.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    return keys


def test_tether_restart_is_capped_and_pages() -> None:
    keys = _tether_keys()
    assert keys["Restart"] == ["on-failure"]
    assert keys["Requires"] == ["nftables.service"] and "nftables.service" in keys["After"]
    interval = int(keys["StartLimitIntervalSec"][0])
    burst = int(keys["StartLimitBurst"][0])
    restart = int(keys["RestartSec"][0])
    assert interval > 0 and burst > 0, "a zero interval disables the start limit"
    assert burst * restart < interval, "the limit must be reachable inside its interval"
    assert interval >= 3600, "a slow crash loop must still reach the limit"
    assert keys["OnFailure"] == ["fleet-unit-failed@%N.service"]


def test_tether_cannot_reach_loopback_or_rewrite_its_code() -> None:
    keys = _tether_keys()
    assert keys["IPAddressDeny"] == ["localhost"]
    assert keys["IPAddressAllow"] == ["127.0.0.1/32 127.0.0.53/32"]
    assert "ReadWritePaths" not in keys
    assert keys["ConditionPathExists"][0].startswith("/opt/tether/")
    assert keys["ExecStart"][0].split()[-1].startswith("/opt/tether/")
    assert not keys["WorkingDirectory"][0].startswith("/opt/")


def _tether_tasks(marker: Path) -> dict[str, dict]:
    env = {**os.environ, "ANSIBLE_STDOUT_CALLBACK": "json", "ANSIBLE_LOCALHOST_WARNING": "False"}
    proc = subprocess.run(
        [
            "ansible-playbook", "--check", "-c", "local", "-i", "localhost,", "--tags", "tether",
            "-e", f"tether_off_marker={marker}", "ansible/host.yml",
        ],
        cwd=ROOT, env=env, capture_output=True, text=True, check=False,
    )
    out = proc.stdout
    plays = json.loads(out[out.index("{"):])["plays"]
    assert plays, proc.stderr
    return {task["task"]["name"]: task["hosts"]["localhost"] for task in plays[0]["tasks"]}


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_off_marker_survives_the_host_run(tmp_path: Path) -> None:
    marker = tmp_path / "tether-off"
    on = _tether_tasks(marker)
    marker.touch()
    off = _tether_tasks(marker)
    for name in (
        "Create the tether group",
        "Create the tether service user",
        "Create the tether config directory",
        "Create the tether app directory, root-owned",
        "Download the pinned Node tarball for tether",
        "Create the versioned Node directory, root-owned",
        "Unpack the pinned Node for tether",
        "Let the tether group read the Photon credentials file",
    ):
        assert not on[name].get("skipped"), name
        assert off[name].get("skipped"), name
    assert not off["Keep tether disabled and stopped while the marker exists"].get("skipped")
    assert not off["Remove the tether egress rule while the marker exists"].get("skipped")
    assert on["Remove the tether egress rule while the marker exists"].get("skipped")
    assert on["Keep tether disabled and stopped while the marker exists"].get("skipped"), "no marker: the run never touches the unit"


def _host_play() -> dict:
    return yaml.safe_load((ROOT / "ansible/host.yml").read_text())[0]


def _tether_module_tasks(module: str) -> list[dict]:
    return [
        task
        for task in _host_play()["tasks"]
        if "tether" in (task.get("tags") or []) and f"ansible.builtin.{module}" in task
    ]


def _node_dir() -> str:
    variables = _host_play()["vars"]
    version = variables["tether_node_version"]
    return variables["tether_node_dir"].replace("{{ tether_node_version }}", version)


def test_tether_has_no_apt_nodejs_pin() -> None:
    for task in _tether_module_tasks("apt"):
        assert "nodejs" not in str(task["ansible.builtin.apt"].get("name")), task["name"]
    assert "nodejs=" not in (ROOT / "ansible/host.yml").read_text()


def test_tether_node_download_is_pinned_by_sha256() -> None:
    variables = _host_play()["vars"]
    assert re.fullmatch(r"22\.\d+\.\d+", str(variables["tether_node_version"]))
    assert re.fullmatch(r"[0-9a-f]{64}", variables["tether_node_sha256"])
    downloads = _tether_module_tasks("get_url")
    assert len(downloads) == 1
    args = downloads[0]["ansible.builtin.get_url"]
    assert args["url"].startswith("https://nodejs.org/dist/v{{ tether_node_version }}/")
    assert args["url"].endswith("-linux-x64.tar.xz")
    assert args["checksum"] == "sha256:{{ tether_node_sha256 }}"
    unpack = _tether_module_tasks("unarchive")
    assert len(unpack) == 1
    assert unpack[0]["ansible.builtin.unarchive"]["dest"] == "{{ tether_node_dir }}"
    assert re.fullmatch(r"/opt/node-v\d+\.\d+\.\d+", _node_dir())


def test_tether_execstart_uses_the_pinned_node() -> None:
    command = _tether_keys()["ExecStart"][0].split()
    assert command[0] == f"{_node_dir()}/bin/node"
    assert command[-1].startswith("/opt/tether/")


def test_tether_loads_both_environment_files() -> None:
    assert _tether_keys()["EnvironmentFile"] == ["-/etc/tether/tether.env", "-/etc/tether/photon.env"]


def test_tether_photon_env_is_only_chowned_never_created() -> None:
    tasks = [
        task
        for task in _tether_module_tasks("file")
        if task["ansible.builtin.file"]["path"] == "/etc/tether/photon.env"
    ]
    assert len(tasks) == 1
    args = tasks[0]["ansible.builtin.file"]
    assert args["state"] == "file"
    assert (args["owner"], args["group"], args["mode"]) == ("root", "tether", "0640")
    text = (ROOT / "ansible/host.yml").read_text()
    assert text.count("photon.env") == 1, "no copy or template task may name it"


def test_host_run_never_enables_or_starts_tether() -> None:
    blocks = re.split(r"\n    - name: ", (ROOT / "ansible/host.yml").read_text())
    tether = [block for block in blocks if "name: tether-agent.service" in block]
    assert tether, "the marker task is gone"
    for block in tether:
        assert "enabled: true" not in block and "state: started" not in block, block
        assert "when: tether_off.stat.exists" in block, block


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_nft_template_renders_and_loads(tmp_path: Path) -> None:
    out = tmp_path / "tether.nft"
    facts = {
        "all_ipv4_addresses": ["192.0.2.5", "127.0.0.1"],
        "all_ipv6_addresses": ["2001:db8::5"],
        "interfaces": ["br-ab12", "br-new", "eth0"],
        "br_ab12": {"ipv4": {"network": "198.51.100.0", "prefix": "24"}},
    }
    task = {
        "ansible.builtin.template": {"src": str(ROOT / "ansible/templates/tether.nft.j2"), "dest": str(out)},
        "vars": {"tether_uid": 995, "ansible_facts": facts},
    }
    play = tmp_path / "play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "tasks": [task]}]))
    proc = subprocess.run(
        ["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    text = out.read_text()
    assert "meta skuid != 995 return" in text
    assert "ip daddr 127.0.0.1 tcp dport 4000 accept" in text
    assert "ip daddr 198.51.100.0/24 drop" in text, "a bridge subnet is dropped"
    assert text.rstrip().endswith("}\n}"), "an interface with no fact does not break the render"
    if shutil.which("sudo") and shutil.which("nft"):
        check = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(out)], capture_output=True, text=True, check=False)
        assert check.returncode == 0, check.stderr
