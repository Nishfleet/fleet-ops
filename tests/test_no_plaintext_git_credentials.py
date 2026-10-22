"""The tmpfiles file keeps a read-only, non-empty directory at the plaintext git credential store path (fleet-ops#9983)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "rootfs/etc/tmpfiles.d/no-plaintext-git-credentials.conf"
PATH = "/home/nish/.git-credentials"


def lines() -> list[list[str]]:
    rows = [line for line in CONF.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [row.split(None, 6) for row in rows]


def test_path_is_a_root_owned_read_only_directory() -> None:
    assert ["d", PATH, "0555", "root", "root", "-"] in lines()


def test_directory_is_non_empty() -> None:
    readme = [row for row in lines() if row[:6] == ["f", f"{PATH}/README", "0444", "root", "root", "-"]]
    assert len(readme) == 1 and len(readme[0]) == 7 and readme[0][6].strip()


def test_nothing_else_is_configured() -> None:
    assert len(lines()) == 2
