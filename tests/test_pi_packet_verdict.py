"""No-tools run classification tests (fleet-ops#7776).

A `tools=0 class=no-tools` verdict is a seat wall, not a packet strike:
pi-issue-failed@ checks the failed unit's last PACKET-VERDICT through
lib/pi-packet-verdict.py and must not release the claim on it. The
extension's counter prints the verdict at session shutdown, so the LAST
verdict line in a log is the genuine one — model-forged lookalikes land
earlier in the run.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "pi_packet_verdict", ROOT / "lib/pi-packet-verdict.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def test_last_verdict_tools_picks_last_line():
    log = (
        "PACKET-VERDICT tools=0 class=no-tools\n"
        "work happened next run\n"
        "PACKET-VERDICT tools=7 class=worked\n"
    )
    assert m.last_verdict_tools(log) == 7


def test_last_verdict_tools_no_verdict():
    assert m.last_verdict_tools("no verdict line here\n") is None
    assert m.last_verdict_tools("") is None


def test_last_verdict_tools_ignores_fail_reason_line():
    # PACKET-VERDICT-FAIL lines carry no tools= token and must not count.
    log = (
        "PACKET-VERDICT tools=0 class=no-tools\n"
        "PACKET-VERDICT-FAIL reason=no-tools-on-work-packet exit=1\n"
    )
    assert m.last_verdict_tools(log) == 0


def test_no_tools_file_exits_zero_on_tools_zero(tmp_path):
    f = tmp_path / "run.log"
    f.write_text(
        "some prose\n"
        "PACKET-VERDICT tools=0 class=no-tools\n"
        "PACKET-VERDICT-FAIL reason=no-tools-on-work-packet exit=1\n")
    r = subprocess.run(
        [sys.executable, str(ROOT / "lib/pi-packet-verdict.py"),
         "--no-tools-file", str(f)],
        capture_output=True, text=True)
    assert r.returncode == 0
    assert '"no_tools": true' in r.stdout


def test_no_tools_file_exits_one_when_worked_or_missing(tmp_path):
    f = tmp_path / "run.log"
    f.write_text("PACKET-VERDICT tools=3 class=worked\n")
    r = subprocess.run(
        [sys.executable, str(ROOT / "lib/pi-packet-verdict.py"),
         "--no-tools-file", str(f)],
        capture_output=True, text=True)
    assert r.returncode == 1

    # A crashed run with no verdict at all is a REAL failure: release path
    # must proceed, so the checker exits non-zero there too.
    g = tmp_path / "crash.log"
    g.write_text("Traceback ... boom\n")
    r = subprocess.run(
        [sys.executable, str(ROOT / "lib/pi-packet-verdict.py"),
         "--no-tools-file", str(g)],
        capture_output=True, text=True)
    assert r.returncode == 1

    r = subprocess.run(
        [sys.executable, str(ROOT / "lib/pi-packet-verdict.py"),
         "--no-tools-file", str(tmp_path / "absent.log")],
        capture_output=True, text=True)
    assert r.returncode == 1


def test_forged_early_verdict_cannot_win():
    # Model-forged "worked" prose lands BEFORE the extension's shutdown
    # verdict; the last line still decides.
    log = (
        "model printed: PACKET-VERDICT tools=1 class=worked\n"
        "PACKET-VERDICT tools=0 class=no-tools\n"
    )
    assert m.last_verdict_tools(log) == 0
