"""The tmpfiles file keeps an unreadable, non-empty directory at the plaintext git credential store path (fleet-ops#9983)."""

import re
from pathlib import Path
import ansible_host

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "rootfs/etc/tmpfiles.d/no-plaintext-git-credentials.conf"
HOST = ROOT / "ansible/host.yml"
PATH = "/home/nish/.git-credentials"


def lines() -> list[list[str]]:
    rows = [line for line in CONF.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [row.split(None, 6) for row in rows]


def test_path_is_an_unreadable_directory_owned_by_nish() -> None:
    assert ["d", PATH, "0000", "nish", "nish", "-"] in lines()


def test_directory_is_non_empty() -> None:
    readme = [row for row in lines() if row[:6] == ["f", f"{PATH}/README", "0444", "nish", "nish", "-"]]
    assert len(readme) == 1 and len(readme[0]) == 7 and readme[0][6].strip()


def test_nothing_else_is_configured() -> None:
    assert len(lines()) == 2


def test_host_yml_fails_before_tmpfiles_on_a_regular_file() -> None:
    host = ansible_host.text()
    check = host.index("Fail the run when a plaintext git credential file is in the way")
    install = host.index("- name: Install tmpfiles.d entries")
    assert check < install
    block = host[host.index("Look for a plaintext git credential file"):install]
    assert "ansible.builtin.assert" in block and "mkdir -p /root/quarantine" in block
    assert re.search(r"git_credential_stat\.stat\.exists and not git_credential_stat\.stat\.isdir", block)
    assert "state: absent" not in block and "ansible.builtin.file" not in block
