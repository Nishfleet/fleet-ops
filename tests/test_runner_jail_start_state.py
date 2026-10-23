"""Runner jail: every hidden path must exist when the runner starts (fleet-ops#10081).

InaccessiblePaths= hides a path only if it exists at the moment the unit starts. A path that
user services create later stays visible to jobs until the runner restarts. The agent runner
drop-in therefore starts after the user manager and creates the runtime dirs that user
services would otherwise make later.
"""

import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DROPIN_DIR = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-.service.d"
AGENT = DROPIN_DIR / "10-agent.conf"
LOCKDOWN = DROPIN_DIR / "20-lockdown.conf"
USER_UNITS = ROOT / "systemd"
USER_RUN = "/run/user/1000/"


def values(text: str, key: str) -> list[str]:
    """Every `key=value` line of a drop-in, in file order (comments skipped)."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            out.append(line.removeprefix(key + "="))
    return out


def masked_user_run_names(lockdown_text: str) -> set[str]:
    names = set()
    for value in values(lockdown_text, "InaccessiblePaths"):
        for token in shlex.split(value):
            path = token.lstrip("-+")
            if path.startswith(USER_RUN):
                names.add(path.removeprefix(USER_RUN).split("/")[0])
    return names


def runtime_dirs_of_user_units(unit_dir: Path) -> dict[str, str]:
    """RuntimeDirectory= name -> RuntimeDirectoryMode= of every repo user unit that sets one."""
    found = {}
    for unit in sorted(unit_dir.glob("*.service")):
        text = unit.read_text()
        modes = values(text, "RuntimeDirectoryMode")
        for names in values(text, "RuntimeDirectory"):
            for name in names.split():
                found[name] = modes[0] if modes else "0755"
    return found


def pre_created(agent_text: str) -> dict[str, str]:
    """Path -> mode of every directory a privileged ExecStartPre= `install -d` makes."""
    made = {}
    for value in values(agent_text, "ExecStartPre"):
        if not value.startswith("+"):
            continue
        argv = shlex.split(value.removeprefix("+"))
        if len(argv) < 3 or Path(argv[0]).name != "install" or "-d" not in argv:
            continue
        mode = argv[argv.index("-m") + 1] if "-m" in argv else "0755"
        for path in argv[1:]:
            if path.startswith("/"):
                made[path] = mode
    return made


def uncovered(lockdown_text: str, agent_text: str, unit_dir: Path) -> list[str]:
    """Hidden user-runtime paths that a user service creates later and the runner does not pre-create."""
    later = runtime_dirs_of_user_units(unit_dir)
    made = pre_created(agent_text)
    bad = []
    for name in sorted(masked_user_run_names(lockdown_text) & set(later)):
        mode = made.get(USER_RUN + name)
        if mode is None:
            bad.append(f"{name}: not created before start")
        elif int(mode, 8) != int(later[name], 8):
            bad.append(f"{name}: mode {mode} differs from the service's {later[name]}")
    return bad


def test_runner_starts_after_the_user_manager() -> None:
    text = AGENT.read_text()
    assert "user@1000.service" in " ".join(values(text, "After")).split()
    assert "user@1000.service" in " ".join(values(text, "Wants")).split()


def test_late_runtime_dirs_exist_before_the_runner_starts() -> None:
    names = masked_user_run_names(LOCKDOWN.read_text()) & set(runtime_dirs_of_user_units(USER_UNITS))
    assert len(names) >= 2, "the hidden runtime dirs made by user services were not found"
    assert uncovered(LOCKDOWN.read_text(), AGENT.read_text(), USER_UNITS) == []


def test_the_pre_create_line_is_not_confined_by_the_sandbox() -> None:
    lines = values(AGENT.read_text(), "ExecStartPre")
    assert lines and all(line.startswith("+") for line in lines), lines


def _fixture(tmp_path: Path, runtime_dir: str, mode: str = "0700") -> Path:
    units = tmp_path / "systemd"
    units.mkdir()
    (units / "x.service").write_text(f"[Service]\nRuntimeDirectory={runtime_dir}\nRuntimeDirectoryMode={mode}\n")
    return units


LOCK = "[Service]\nInaccessiblePaths=-/run/user/1000/bus -/run/user/1000/late-dir\n"


def test_gate_fails_when_a_late_dir_is_not_pre_created(tmp_path: Path) -> None:
    units = _fixture(tmp_path, "late-dir")
    assert uncovered(LOCK, "[Service]\n", units) == ["late-dir: not created before start"]


def test_gate_fails_on_a_mode_mismatch_and_on_an_unprivileged_line(tmp_path: Path) -> None:
    units = _fixture(tmp_path, "late-dir")
    wrong = "[Service]\nExecStartPre=+/usr/bin/install -d -m 0755 /run/user/1000/late-dir\n"
    assert uncovered(LOCK, wrong, units) == ["late-dir: mode 0755 differs from the service's 0700"]
    plain = "[Service]\nExecStartPre=/usr/bin/install -d -m 0700 /run/user/1000/late-dir\n"
    assert uncovered(LOCK, plain, units) == ["late-dir: not created before start"]


def test_gate_accepts_a_pre_created_dir(tmp_path: Path) -> None:
    units = _fixture(tmp_path, "late-dir")
    good = "[Service]\nExecStartPre=+/usr/bin/install -d -m 0700 -o nish -g nish /run/user/1000/late-dir\n"
    assert uncovered(LOCK, good, units) == []


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_accepts_the_agent_dropin_on_a_stand_in(tmp_path: Path) -> None:
    (tmp_path / "standin.service").write_text("[Service]\nExecStart=/usr/bin/true\n")
    (tmp_path / "standin.service.d").mkdir()
    for conf in (AGENT, LOCKDOWN):
        (tmp_path / "standin.service.d" / conf.name).write_text(conf.read_text())
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", "./standin.service"], cwd=tmp_path, capture_output=True, text=True, check=False
    )
    out = proc.stdout + proc.stderr
    assert not re.search(r"Unknown key|Unknown section|Failed to parse|Invalid|Executable", out), out
