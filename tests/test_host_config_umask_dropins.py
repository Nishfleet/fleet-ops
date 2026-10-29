from pathlib import Path

import pytest

import ansible_host

ROOT = Path(__file__).resolve().parents[1]

UNITS = (
    "rootfs/etc/systemd/system/fleet-host-config.service",
    "rootfs/etc/systemd/system/fleet-update.service",
)

# GitHub's svc.sh writes the netcup-agent unit files, so the repo holds only
# their prefix drop-in directory.
RUNNER_PREFIX_DROPINS = "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-.service.d"

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


def test_agent_runner_prefix_dropin_sets_owner_only() -> None:
    dropin = ROOT / RUNNER_PREFIX_DROPINS / "20-umask.conf"
    assert dropin.is_file(), f"{dropin} is missing"
    lines = [line.strip() for line in dropin.read_text().splitlines()]
    assert "[Service]" in lines
    assert [line for line in lines if line.startswith("UMask=")] == ["UMask=0077"]


def test_only_the_umask_dropin_sets_umask_on_the_runners() -> None:
    setting = sorted(
        dropin.name
        for dropin in (ROOT / RUNNER_PREFIX_DROPINS).glob("*.conf")
        if any(line.startswith("UMask=") for line in dropin.read_text().splitlines())
    )
    assert setting == ["20-umask.conf"], "keep UMask in 20-umask.conf only"


def test_login_profile_sets_owner_only_umask() -> None:
    profile = ROOT / LOGIN_PROFILE
    assert profile.is_file(), f"{profile} is missing"
    lines = [line.strip() for line in profile.read_text().splitlines() if line.strip() and not line.startswith("#")]
    assert lines == ["umask 077"]


def test_host_yml_installs_the_login_profile() -> None:
    play = ansible_host.text()
    start = play.index("Install the owner-only umask for nish's login shells")
    task = play[start:play.index("- name:", start)]
    assert 'src: "{{ rootfs }}/etc/zsh/zprofile"' in task
    assert "dest: /etc/zsh/zprofile" in task
    assert "mode: preserve" in task
