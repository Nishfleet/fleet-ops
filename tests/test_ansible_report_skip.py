"""The report block must survive a skipped registration. Relocated from ci.yml's
unit job, same replay: ansible/tests/report-after-skipped-block.yml holds the
shape fleet-ops#9340 fixed — a non-looped task whose registration is skipped,
then a report task reading the register — and the play's exit code is the check
(the old `(x | default({'results': []})).results` pattern had no 'results' key to
render and killed the run's last task).
"""

import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = ROOT / "ansible/tests/report-after-skipped-block.yml"


def test_the_report_survives_a_skipped_registration():
    run = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(PLAY)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert run.returncode == 0, run.stderr
