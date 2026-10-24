from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

UNITS = (
    "rootfs/etc/systemd/system/fleet-host-config.service",
    "rootfs/etc/systemd/system/fleet-update.service",
)


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
