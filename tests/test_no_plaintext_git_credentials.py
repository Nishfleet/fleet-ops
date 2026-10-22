"""The tmpfiles file keeps a read-only, non-empty directory at each plaintext git credential store path (fleet-ops#9983)."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "rootfs/etc/tmpfiles.d/no-plaintext-git-credentials.conf"
HOST = ROOT / "ansible/host.yml"
PATHS = ["/home/nish/.git-credentials", "/home/nish/.config/git/credentials"]


def lines() -> list[list[str]]:
    rows = [line for line in CONF.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [row.split(None, 6) for row in rows]


@pytest.mark.parametrize("path", PATHS)
def test_path_is_a_root_owned_unreadable_directory(path: str) -> None:
    assert ["d", path, "0000", "root", "root", "-"] in lines()


@pytest.mark.parametrize("path", PATHS)
def test_directory_is_non_empty(path: str) -> None:
    readme = [row for row in lines() if row[:6] == ["f", f"{path}/README", "0444", "root", "root", "-"]]
    assert len(readme) == 1 and len(readme[0]) == 7 and readme[0][6].strip()


def test_nothing_else_is_configured() -> None:
    assert len(lines()) == 2 * len(PATHS)


def test_header_states_the_rename_limit() -> None:
    header = CONF.read_text().split("\nd ")[0]
    assert "deliberate rename" in header and "R3" in header


def test_host_yml_fails_before_tmpfiles_on_a_regular_file() -> None:
    host = HOST.read_text()
    check = host.index("Fail the run when a plaintext git credential file is in the way")
    install = host.index("- name: Install tmpfiles.d entries")
    assert check < install
    block = host[check:install]
    assert "ansible.builtin.assert" in block and "/root/quarantine" in block
    assert re.search(r"item\.stat\.exists and not item\.stat\.isdir", block)
    assert all(path in host[host.index("Look for a plaintext git credential file"):check] for path in PATHS)
    assert "state: absent" not in block
