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
    assert lines() == [["d", path, "-", "nish", "nish", "-"] for path in PATHS]


def test_the_apply_runs_the_lines_before_the_ownership_check() -> None:
    play = ansible_host.text()
    run = play.index("- name: Run the config-dir tmpfiles lines on every apply")
    command = play.index("/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/nish-config-dirs.conf")
    flush = play.index("Apply pending handlers before the Grafana credential check")
    check = play.index("- name: Fail when nish's config dir is not owned by nish")
    assert run < command and flush < check


def test_the_ownership_check_names_the_owner_and_the_repair() -> None:
    play = ansible_host.text()
    check = play.index("- name: Look up nish's config dir ownership")
    end = play.index("- name: Work out which Grafana credentials could not be read")
    check_text = play[check:end]
    for tail in ("/.config", "/.config/cloudflare"):
        assert f"{{{{ nish_home }}}}{tail}" in check_text, tail
    assert "pw_name == 'nish'" in check_text and "gr_name == 'nish'" in check_text
    assert "wusr" in check_text and "xusr" in check_text
    assert "nish-config-dirs.conf" in check_text
