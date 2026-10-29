"""The control-plane package's vitest suite: the jobs moved out of workflow YAML (fleet-ops#10456).

Stock `npm ci` + `npm test` in control-plane/, never a bespoke runner and never a skip: on an old
node, or without npm, this fails instead of passing quietly.
"""
import pathlib
import re
import shutil
import subprocess

PACKAGE = pathlib.Path(__file__).resolve().parents[1] / "control-plane"
NODE_MIN = (22, 12)


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def node_version() -> tuple[int, int] | None:
    node = shutil.which("node")
    if node is None:
        return None
    out = subprocess.run([node, "--version"], capture_output=True, text=True, check=False).stdout.strip()
    match = re.match(r"v(\d+)\.(\d+)", out)
    return None if match is None else (int(match.group(1)), int(match.group(2)))


def test_the_suite_runs_on_a_node_new_enough_for_vitest() -> None:
    version = node_version()
    assert version is not None, "node is not installed; vitest 5 cannot run"
    assert version >= NODE_MIN, (
        f"node {'.'.join(map(str, version))} is older than vitest 5's floor "
        f"{'.'.join(map(str, NODE_MIN))}; run the suite on a newer node, never skip it"
    )


def test_the_lockfile_is_committed() -> None:
    assert (PACKAGE / "package-lock.json").exists(), "npm ci needs the committed lockfile"


def test_the_sweep_tests_pass() -> None:
    install = subprocess.run(["npm", "ci", "--no-audit", "--no-fund"], cwd=PACKAGE, capture_output=True, text=True, check=False, timeout=600)
    assert install.returncode == 0, install.stderr
    tests = subprocess.run(["npm", "test"], cwd=PACKAGE, capture_output=True, text=True, check=False, timeout=900)
    assert tests.returncode == 0, tests.stdout + tests.stderr
    clean = strip_ansi(tests.stdout)

    def passed(label: str) -> int:
        match = re.search(rf"^\s*{label}\s+(\d+) passed\b.*\((\d+)\)$", clean, re.MULTILINE)
        assert match is not None, clean
        count, total = (int(value) for value in match.groups())
        assert count == total > 0, f"{count} of {total} {label.lower()} passed\n{clean}"
        return count

    assert passed("Test Files") == 1, clean
    assert passed("Tests") >= 40, clean


MOCK_GH = """#!/usr/bin/env bash
case "$1 $2" in
  "issue list"|"pr list") echo '[]' ;;
  *) echo "mock gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def test_the_entry_point_boots_under_plain_node(tmp_path) -> None:
    """`node control-plane/src/sweep.ts` is the workflow's whole run block: it must start, sweep,
    and write the two step outputs, with no bundler and no vitest in the path."""
    node = pathlib.Path(shutil.which("node") or "")
    assert node.is_file(), "node is not installed"
    fake = tmp_path / "bin"
    fake.mkdir()
    gh = fake / "gh"
    gh.write_text(MOCK_GH)
    gh.chmod(0o755)
    out = tmp_path / "github-output"
    out.write_text("")
    env = {
        "PATH": f"{fake}:{node.parent}:/usr/bin:/bin",
        "GH_TOKEN": "x",
        "GITHUB_REPOSITORY": "o/r",
        "GITHUB_OUTPUT": str(out),
        "GITHUB_EVENT_NAME": "schedule",
    }
    run = subprocess.run(
        ["node", "control-plane/src/sweep.ts"],
        cwd=PACKAGE.parent,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "unexpected call" not in run.stderr, run.stderr
    assert out.read_text() == 'refs=[]\nstalled_refs=[]\n', out.read_text()
