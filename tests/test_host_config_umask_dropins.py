from pathlib import Path

import ansible_host
import pytest

ROOT = Path(__file__).resolve().parents[1]

UNITS = (
    "rootfs/etc/systemd/system/fleet-host-config.service",
    "rootfs/etc/systemd/system/fleet-update.service",
)

LOGIN_PROFILE = "rootfs/etc/zsh/zprofile"


def _dropin(unit: str) -> Path:
    return ROOT / (unit + ".d") / "20-umask.conf"


@pytest.mark.parametrize("unit", UNITS)
def test_rootfs_unit_umask_dropin_sets_owner_only(unit: str) -> None:
    dropin = _dropin(unit)
    assert dropin.is_file(), f"{dropin} is missing"
    lines = [line.strip() for line in dropin.read_text().splitlines()]
    assert "[Service]" in lines
    assert [line for line in lines if line.startswith("UMask=")] == ["UMask=0077"]


@pytest.mark.parametrize("unit", UNITS)
def test_rootfs_unit_does_not_set_umask_itself(unit: str) -> None:
    unit_file = ROOT / unit
    assert unit_file.is_file(), f"{unit_file} is missing"
    assert not [line for line in unit_file.read_text().splitlines() if line.startswith("UMask=")], (
        f"{unit_file.name} sets UMask itself; keep it in the drop-in only"
    )


def test_login_profile_sets_owner_only_umask() -> None:
    profile = ROOT / LOGIN_PROFILE
    assert profile.is_file(), f"{profile} is missing"
    top_level = [line for line in profile.read_text().splitlines()
                 if line and not line[0].isspace() and not line.startswith("#")]
    assert top_level == ["umask 077", "claude() {", "}"], (
        "the login profile holds only the umask line and the claude seats-sandbox wrapper"
    )


def test_host_yml_installs_the_login_profile() -> None:
    play = ansible_host.text()
    start = play.index("Install the owner-only umask for nish's login shells")
    task = play[start:play.index("- name:", start)]
    assert 'src: "{{ rootfs }}/etc/zsh/zprofile"' in task
    assert "dest: /etc/zsh/zprofile" in task
    assert "mode: preserve" in task


def test_host_play_makes_the_resolved_dropin_dir_readable_by_the_service() -> None:
    """systemd-resolved runs as systemd-resolve, and the unit's UMask=0077 makes
    copy create a missing dest directory owner-only, so a 0700
    /etc/systemd/resolved.conf.d hides the DNS drop-in from the service
    (fleet-ops#12154). The play must name the directory's mode itself."""
    play = ansible_host.text()
    start = play.index("Make the resolved drop-in directory readable by the service")
    task = play[start:play.index("- name:", start)]
    assert "path: /etc/systemd/resolved.conf.d" in task
    assert 'mode: "0755"' in task
    # A repair must reach the service: the drop-in file can be unchanged when only
    # the directory's mode was wrong, and resolved reads drop-ins only at start.
    assert "notify: Restart systemd-resolved" in task
