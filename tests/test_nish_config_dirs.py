"""The tmpfiles file keeps /home/nish/.config and its Cloudflare dir owned by nish (fleet-ops#11120)."""

from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "rootfs/etc/tmpfiles.d/nish-config-dirs.conf"
PATHS = ["/home/nish/.config", "/home/nish/.config/cloudflare"]


def lines() -> list[list[str]]:
    rows = [line for line in CONF.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [row.split() for row in rows]


def test_dirs_are_created_nish_owned() -> None:
    assert lines() == [["d", path, "0755", "nish", "nish", "-"] for path in PATHS]


def test_the_apply_repairs_ownership_and_the_check_fails_on_a_wrong_owner() -> None:
    play = ansible_host.text()
    start = play.index("- name: Keep the config dir and its Cloudflare dir owned by nish")
    end = play.index("# The rootless Docker engine")
    repair = play[start:end]
    for path in ["{{ nish_home }}/.config", "{{ nish_home }}/.config/cloudflare"]:
        assert path in repair, path
    assert "state: directory" in repair and "owner: nish" in repair and "group: nish" in repair
    check = play.index("- name: Fail when a jailed-job config dir is not owned by nish")
    assert play.index("Apply pending handlers before the Grafana credential check") < check
    assert "pw_name == 'nish'" in play[check:check + 900]
