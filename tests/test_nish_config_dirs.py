"""The config-dir tmpfiles lines keep /home/nish/.config and its Cloudflare dir nish-owned (fleet-ops#11120)."""

from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "rootfs/etc/tmpfiles.d/nish-config-dirs.conf"
PATHS = ["/home/nish/.config", "/home/nish/.config/cloudflare"]


def lines() -> list[list[str]]:
    rows = [line for line in CONF.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [row.split() for row in rows]


def test_dirs_get_owner_only_repairs() -> None:
    assert lines() == [
        ["d", "/home/nish/.config", "-", "nish", "nish", "-"],
        ["d", "/home/nish/.config/cloudflare", "0700", "nish", "nish", "-"],
    ]


def test_the_apply_reads_the_dirs_before_it_applies_tmpfiles() -> None:
    play = ansible_host.text()
    found = play.index("- name: Read the config dirs' owner as the apply found it")
    stat_text = play[found:play.index("- name: Apply tmpfiles on every run")]
    for tail in (".config", ".config/cloudflare"):
        assert f"- {tail}\n" in stat_text, tail
    assert "follow: false" in stat_text
    applied = play.index("- name: Apply tmpfiles on every run")
    check = play.index("- name: Fail when a config dir was not nish-owned when the apply started")
    assert found < applied < check


def test_the_ownership_check_reads_the_pre_apply_stat() -> None:
    play = ansible_host.text()
    check = play.index("- name: Fail when a config dir was not nish-owned when the apply started")
    end = play.index("- name: Work out which Grafana credentials could not be read")
    check_text = play[check:end]
    assert "config_dirs_found.results" in check_text
    assert "pw_name == 'nish'" in check_text and "gr_name == 'nish'" in check_text
    assert "wusr" not in check_text and "xusr" not in check_text
    assert "systemd-tmpfiles --create" in check_text
