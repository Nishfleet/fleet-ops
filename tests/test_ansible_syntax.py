"""The two root playbooks must parse. Relocated from ci.yml's unit job, same checks:
fleet-host-config.service runs ansible/host.yml as root on every merge, and
fleet-update.service runs ansible/update.yml as root every day; a parse error
would stop every root config change at deploy time (fleet-ops#10075, #10079).
"""

import pathlib
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAYBOOKS = ["ansible/host.yml", "ansible/update.yml"]

pytestmark = pytest.mark.skipif(
    shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed"
)


@pytest.mark.parametrize("playbook", PLAYBOOKS)
def test_playbook_parses(playbook):
    run = subprocess.run(
        [
            "ansible-playbook",
            "--syntax-check",
            "-i",
            "localhost,",
            str(ROOT / playbook),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert run.returncode == 0, run.stderr
