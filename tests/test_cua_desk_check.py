import json
import pathlib
import shlex
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-cua-desk-check.service"

READY = [{"id": "local:desk", "kind": "container", "location": "local", "status": "ready"}]
OK_ROUTINE = [{"botID": "desk", "title": "0509 daily walk", "lastOutcome": "ok"}]


def _exec_start():
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$"))


def _env(tmp_path, sandboxes, routines):
    cua = tmp_path / "cua"
    out = tmp_path / "ls.json"
    out.write_text(json.dumps(sandboxes))
    cua.write_text(f'#!/bin/sh\ntest "$*" = "sandbox ls --local --json --no-size" || exit 2\ncat {shlex.quote(str(out))}\n')
    cua.chmod(0o755)
    path = tmp_path / "routines.json"
    if routines is not None:
        path.write_text(routines if isinstance(routines, str) else json.dumps(routines))
    return {"CUA": str(cua), "ROUTINES": str(path), "DESK": "local:desk", "FAILED": "failed", "PATH": "/usr/bin:/bin"}


def _run(env):
    return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=30)


def test_unit_env_defaults_match_the_test():
    text = UNIT.read_text()
    assert 'Environment="CUA=/opt/Cua Spaces/resources/native/cua"' in text
    assert "Environment=ROUTINES=%h/.cua/persistent/routines.json" in text
    assert "Environment=DESK=local:desk" in text
    assert "Environment=FAILED=failed" in text
    assert "OnFailure=fleet-unit-failed@%N.service" in text


@pytest.mark.parametrize(
    "routines",
    [
        OK_ROUTINE,
        [{"botID": "desk", "title": "never run"}],
        [{"botID": "desk", "title": "null outcome", "lastOutcome": None}],
        [],
    ],
)
def test_ready_desk_and_no_failed_routine_passes(tmp_path, routines):
    r = _run(_env(tmp_path, READY, routines))
    assert r.returncode == 0, r.stdout
    assert "cua desk ok: local:desk ready" in r.stdout


@pytest.mark.parametrize(
    "sandboxes, shown",
    [
        ([], "missing"),
        ([{"id": "local:other", "status": "ready"}], "missing"),
        ([{"id": "local:desk", "status": "stopped"}], "stopped"),
        ([{"id": "local:desk", "status": "starting"}], "starting"),
    ],
)
def test_desk_not_ready_fails_loud(tmp_path, sandboxes, shown):
    r = _run(_env(tmp_path, sandboxes, OK_ROUTINE))
    assert r.returncode == 1
    assert f"cua desk BROKEN: local:desk is {shown} (want ready)" in r.stdout
    assert "failed routine" not in r.stdout


def test_cua_that_cannot_run_fails_loud(tmp_path):
    env = _env(tmp_path, READY, OK_ROUTINE)
    env["CUA"] = str(tmp_path / "nope")
    r = _run(env)
    assert r.returncode == 1 and "local:desk is missing" in r.stdout


def test_failed_routine_fails_loud_and_names_it(tmp_path):
    routines = [
        {"botID": "desk", "title": "0509 daily walk", "lastFiredAt": "2026-10-20T07:30:00Z", "lastOutcome": "failed: instance desk not found"},
        {"botID": "desk", "title": "other", "lastOutcome": "ok"},
    ]
    r = _run(_env(tmp_path, READY, routines))
    assert r.returncode == 1
    assert "cua desk BROKEN: failed routine:" in r.stdout
    assert "0509 daily walk" in r.stdout and "failed: instance desk not found" in r.stdout
    assert '"other"' not in r.stdout
    assert "want ready" not in r.stdout


def test_desk_down_and_failed_routine_names_both(tmp_path):
    routines = [{"botID": "desk", "title": "0509 daily walk", "lastOutcome": "failed: instance desk not found"}]
    r = _run(_env(tmp_path, [], routines))
    assert r.returncode == 1
    assert "local:desk is missing (want ready)" in r.stdout
    assert "failed routine:" in r.stdout and "0509 daily walk" in r.stdout


@pytest.mark.parametrize("routines", [None, "not json"])
def test_missing_or_broken_routines_file_fails_loud(tmp_path, routines):
    r = _run(_env(tmp_path, READY, routines))
    assert r.returncode == 1
    assert "cua desk BROKEN" in r.stdout and "cannot read" in r.stdout
