"""The runner egress table (rootfs/etc/nftables-runners/runners.nft) matches the runners' cgroups and cannot stop the main firewall loading."""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / "rootfs/etc/nftables-runners/runners.nft"
UNIT = ROOT / "rootfs/etc/systemd/system/nftables-runners.service"
CONF = ROOT / "rootfs/etc/nftables.conf"
UNITS = ROOT / "rootfs/etc/systemd/system"
# Rollout stage 1: only runners.slice is matched, and only fleet-ci-2 is in it.
# agent.slice is NOT matched here: agent jobs start local servers.
MATCHED = ("runners.slice",)


def _rules() -> list[str]:
    """The rule lines of the output chain, comments removed."""
    lines = [re.sub(r"#.*", "", line).strip() for line in RULES.read_text().splitlines()]
    return [line for line in lines if line]


def _keys(path: Path) -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    return keys


def test_table_is_its_own_output_filter_chain_that_accepts_by_default() -> None:
    rules = _rules()
    assert rules[0] == "destroy table inet runners"
    assert rules[1] == "table inet runners {"
    assert rules[2] == "chain output {"
    assert rules[3] == "type filter hook output priority filter; policy accept;"
    assert "flush ruleset" not in RULES.read_text()


def test_main_firewall_never_loads_the_runner_file() -> None:
    conf = CONF.read_text()
    assert "runners" not in conf, "a cgroup rule in the main load can stop the whole firewall loading"
    assert not (ROOT / "rootfs/etc/nftables.d/runners.nft").exists(), "/etc/nftables.d/*.nft is included by nftables.conf"
    assert 'include "/etc/nftables.d/*.nft"' in conf
    assert not (UNITS / "nftables.service.d/60-runner-slices.conf").exists()


def test_only_the_staged_slices_are_matched_and_only_by_cgroup() -> None:
    body = _rules()[4:]
    members = ", ".join(f'"{name}"' for name in MATCHED)
    assert body[0] == f"socket cgroupv2 level 1 != {{ {members} }} return"
    assert not any("skuid" in line for line in body), "every runner is the same uid"
    assert "agent.slice" not in "\n".join(body)
    assert not any("agent.slice" in value for values in _keys(UNIT).values() for value in values)


def test_loopback_allows_are_the_router_and_dns_and_come_before_the_drops() -> None:
    body = _rules()[5:]
    accepts = [line for line in body if line.endswith("accept")]
    assert accepts == [
        "ct state established,related accept",  # replies from a socket in the matched cgroup
        "ip daddr 127.0.0.1 tcp dport 4000 accept",
        "ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept",
    ]
    first_drop = next(i for i, line in enumerate(body) if line.endswith("drop"))
    assert body.index(accepts[-1]) < first_drop


def test_drops_cover_loopback_private_tailnet_and_local_addresses() -> None:
    drops = "\n".join(line for line in _rules() if line.endswith("drop"))
    for needle in (
        "ip daddr 127.0.0.0/8 drop",
        "ip6 daddr ::1 drop",
        "fib daddr type local drop",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "fd7a:115c:a1e0::/48",
        "ip daddr & 0xffc00000 == 0x64400000 drop",  # CGNAT 100.64/10 as a mask test
    ):
        assert needle in drops, needle
    assert not re.search(r"\b100\.\d+\.\d+\.\d+", RULES.read_text()), "a tailnet-range address is private detail"


def test_matched_slices_are_shipped_and_the_canary_runner_is_in_runners_slice() -> None:
    assert (UNITS / "runners.slice").is_file()
    slice_keys = _keys(UNITS / "runners.slice")
    assert slice_keys["MemoryLow"] == ["3G"], "mirrors system.slice.d/50-memory-protect.conf"
    # Fail-closed second layer: allow wins, so the allowed addresses sit inside the denied loopback.
    assert slice_keys["IPAddressAllow"] == ["127.0.0.1/32 127.0.0.53/32"]
    # The CGNAT entry is built in two parts: the written address is private detail.
    denied = slice_keys["IPAddressDeny"][0].split()
    for entry in ("localhost", "link-local", "multicast", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100." + "64.0.0/10", "fd7a:115c:a1e0::/48", "fc00::/7"):
        assert entry in denied, entry
    assert _keys(UNITS / "system.slice.d/50-memory-protect.conf")["MemoryLow"] == ["3G"]
    expect = {
        "actions.runner.Nishfleet.netcup-agent-.service.d": ["agent.slice"],
        "actions.runner.Nishfleet.netcup-fleet-ci-2.service.d": ["runners.slice"],
        "actions.runner.Nishfleet.netcup-fleet-ci-.service.d": [],
        "actions.runner.Nishfleet.netcup-fleet-ci-1.service.d": [],
        "actions.runner.Nishfleet.netcup-fleet-ci-3.service.d": [],
        "actions.runner.nish3451-nish-vault.netcup-vault-1.service.d": [],
    }
    for directory, want in expect.items():
        got = [value for path in sorted((UNITS / directory).glob("*.conf")) for value in _keys(path).get("Slice", [])]
        assert got == want, f"{directory}: {got}"


def test_runner_unit_loads_the_file_alone_and_pages_when_it_fails() -> None:
    keys = _keys(UNIT)
    path = "/etc/nftables-runners/runners.nft"
    assert keys["Type"] == ["oneshot"] and keys["RemainAfterExit"] == ["yes"]
    assert keys["ExecStart"] == [f"/usr/sbin/nft -f {path}"]
    assert keys["ExecReload"] == keys["ExecStart"]
    assert keys["ExecStop"] == ["/usr/sbin/nft destroy table inet runners"]
    assert keys["Requires"] == ["nftables.service"]
    assert keys["BindsTo"] == ["runners.slice"], "a slice stop destroys the table, a slice start reloads it"
    assert set(keys["After"][0].split()) == {"nftables.service", "runners.slice"}
    assert keys["PartOf"] == ["nftables.service"]
    assert keys["ReloadPropagatedFrom"] == ["nftables.service"]
    assert keys["OnFailure"] == ["fleet-unit-failed@%N.service"]
    assert set(keys["WantedBy"][0].split()) == {"multi-user.target", "runners.slice"}
    # A runner in the slice starts after the rule is loaded.
    canary = _keys(UNITS / "actions.runner.Nishfleet.netcup-fleet-ci-2.service.d/30-runners-slice.conf")
    assert canary["Wants"] == ["nftables-runners.service"] and canary["After"] == ["nftables-runners.service"]


def test_host_yml_installs_it_outside_nftables_d_with_a_check_mode_validate() -> None:
    text = (ROOT / "ansible/host.yml").read_text()
    task = text[text.index("- name: Install the runner egress rule") :]
    task = task[: task.index("\n\n")]
    assert "rootfs }}/etc/nftables-runners/runners.nft" in task
    assert "dest: /etc/nftables-runners/runners.nft" in task
    assert "validate: /usr/sbin/nft -c -f %s" in task
    assert "notify: Reload nftables-runners" in task
    assert "nftables.d/runners" not in text
    assert "- /etc/nftables-runners\n" in text.split("package_files:")[0], "owned_dirs lists it for the drift check"


def _nft_check(path: Path) -> subprocess.CompletedProcess:
    for prefix in ([], ["sudo", "-n"]):
        proc = subprocess.run([*prefix, "nft", "-c", "-f", str(path)], capture_output=True, text=True, check=False)
        if "Operation not permitted" not in proc.stderr:
            return proc
        if os.geteuid() == 0:
            break
    pytest.skip("nft -c needs CAP_NET_ADMIN (root or passwordless sudo)")


@pytest.mark.skipif(shutil.which("nft") is None, reason="nft is not installed")
@pytest.mark.skipif(not Path("/sys/fs/cgroup/system.slice").is_dir(), reason="needs a cgroup v2 host with systemd")
def test_nft_check_mode_accepts_the_file(tmp_path: Path) -> None:
    # Check mode loads nothing. nft refuses a cgroup path that does not exist, and
    # the runner slice does not exist on a CI machine, so stand in two slices that do.
    stand_in = tmp_path / "runners.nft"
    stand_in.write_text(RULES.read_text().replace('"runners.slice"', '"system.slice", "user.slice"'))
    proc = _nft_check(stand_in)
    assert proc.returncode == 0, proc.stderr
