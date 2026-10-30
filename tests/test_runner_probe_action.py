"""The runner-probe action's own check (fleet-ops#10886): the script the action runs is read out of
the action file and executed in this job's place against a stub systemctl and mountpoint, so a
masked path that reads fails, a mount that is no mount point fails, and a mount that covers a host
mount point passes."""
import os
import pathlib
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github/actions/runner-probe/action.yml"
UNIT = "actions.runner.Nishfleet.netcup-agent-26.service"


def _script():
    action = yaml.safe_load(ACTION.read_text())
    step = next(step for step in action["runs"]["steps"] if "run" in step)
    assert step["shell"] == "bash"
    return step["run"]


@pytest.fixture
def paths(tmp_path):
    """A readable host directory, a directory a mask leaves unreadable, and two mount candidates."""
    made = {}
    for name, mode in (("host", 0o755), ("hidden", 0o000), ("covered", 0o755), ("bare", 0o755)):
        path = tmp_path / name
        path.mkdir()
        path.chmod(mode)
        made[name] = str(path)
    yield made
    for path in made.values():
        pathlib.Path(path).chmod(0o755)


def _stub(bindir: pathlib.Path, name: str, body: str) -> None:
    stub = bindir / name
    stub.write_text(body)
    stub.chmod(0o755)


def _probe(tmp_path, masks=(), mounts=(), mount_points=(), require=False):
    """The probe's script here: `masks` is the unit's InaccessiblePaths, `mounts` its
    TemporaryFileSystem (an entry keeps its own `:options`), and `mount_points` is what the
    mountpoint command answers yes for.

    The systemctl stub answers each property on its own call, which is the contract
    `systemctl show -p <key> --value` holds, so a mount with no options is read as a mount.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    _stub(bindir, "grep", f"#!/bin/sh\nprintf '%s\\n' '{UNIT}'\n")
    _stub(
        bindir,
        "systemctl",
        "#!/bin/sh\ncase \"$*\" in\n*TemporaryFileSystem*) printf '%s\\n' '"
        + " ".join(mounts)
        + "' ;;\n*InaccessiblePaths*) printf '%s\\n' '"
        + " ".join(masks)
        + "' ;;\nesac\n",
    )
    answers = " ".join(mount_points)
    _stub(bindir, "mountpoint", f"#!/bin/sh\ncase ' {answers} ' in *\" $2 \"*) exit 0 ;; esac\nexit 1\n")
    script = tmp_path / "probe.sh"
    script.write_text(_script())
    done = subprocess.run(
        ["bash", str(script)],
        env={**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}", "REQUIRE": "true" if require else "false"},
        capture_output=True,
        text=True,
    )
    return done.returncode, done.stdout + done.stderr


def test_the_probe_reads_both_lists_of_the_unit(tmp_path, paths) -> None:
    code, out = _probe(tmp_path, masks=[f"-{paths['hidden']}"], mounts=[f"{paths['covered']}:ro"], mount_points=[paths["covered"]])
    assert code == 0, out
    assert "checked=2 readable=0" in out
    assert UNIT in out


def test_a_masked_path_that_reads_fails(tmp_path, paths) -> None:
    """The regression the second reviewer named: a masked path that is a readable host mount point is
    not covered, so the probe must fail it (fleet-ops#10886)."""
    code, out = _probe(tmp_path, masks=[f"-{paths['covered']}"], mount_points=[paths["covered"]])
    assert code != 0
    assert f"::error::{paths['covered']} is a host path in this job, so nothing hides it" in out
    assert "readable=1" in out


def test_a_masked_path_that_does_not_read_passes(tmp_path, paths) -> None:
    code, out = _probe(tmp_path, masks=[f"-{paths['hidden']}"])
    assert code == 0, out


def test_a_mount_that_is_no_mount_point_fails(tmp_path, paths) -> None:
    code, out = _probe(tmp_path, mounts=[f"{paths['bare']}:ro"])
    assert code != 0
    assert f"::error::{paths['bare']} is a host path in this job, so nothing hides it" in out


def test_a_mount_with_no_options_is_read_as_a_mount(tmp_path, paths) -> None:
    """systemd prints TemporaryFileSystem= without a colon when the entry has no options, so a
    probe that reads the colon as the mark of a mount would test it as a masked path and pass an
    unmounted host directory (fleet-ops#10886)."""
    code, out = _probe(tmp_path, mounts=[paths["bare"]])
    assert code != 0
    assert f"::error::{paths['bare']} is a host path in this job, so nothing hides it" in out
    code, out = _probe(tmp_path, mounts=[paths["bare"]], mount_points=[paths["bare"]])
    assert code == 0, out


def test_a_mount_that_covers_the_path_passes(tmp_path, paths) -> None:
    code, out = _probe(tmp_path, mounts=[f"{paths['covered']}:ro"], mount_points=[paths["covered"]])
    assert code == 0, out


def test_a_mount_over_a_readable_host_mount_point_passes_when_it_is_mounted(tmp_path, paths) -> None:
    """An empty tmpfs reads, so the mount itself is the hide: this is why a mount is tested by its
    mount point and a masked path by what reads."""
    assert os.access(paths["covered"], os.R_OK)
    code, out = _probe(tmp_path, mounts=[f"{paths['covered']}:ro"], mount_points=[paths["covered"]])
    assert code == 0, out


def test_a_unit_that_hides_no_path_fails_only_when_it_must(tmp_path) -> None:
    assert _probe(tmp_path, require=True)[0] != 0
    code, out = _probe(tmp_path)
    assert code == 0, out
    assert "::warning::" in out
