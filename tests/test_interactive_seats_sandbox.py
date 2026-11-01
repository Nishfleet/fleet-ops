"""The interactive-session sandbox binds the same-uid seat boundary.

fleet-ops#11114: deny rules bind the command text, so a same-uid reader reaches
a seat file with a relative path the rules cannot spell, and the file mode binds
only readers of other uids. The control for interactive sessions is the worker
jail's mount primitive: bubblewrap with an empty tmpfs over the seats directory,
so inside the sandbox every path spelling resolves to a namespace with nothing
in it. docs/managed-settings-defaults.md holds the launch line; this test holds
both halves: the doc must state it, and (where bubblewrap exists) the executed
sandbox must hide the probe seat while the bare shell reaches it.
The box enforces the launch through the login-shell wrapper in
rootfs/etc/zsh/zprofile (fleet-ops#11320), so this test also holds the
wrapper: its function carries the same flags, and a shell with the repo's
zprofile sourced starts a stub session inside the sandbox while the same
shell without it reads the probe.

The probe runs against a synthetic home, so the test never opens a real seat
file and runs unchanged on a host without the seats directory. On a host
without bubblewrap only the sandboxed half skips; the bare half and the doc
check still run.
"""

import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "managed-settings-defaults.md"
LAUNCH_ANCHOR = "bwrap --dev-bind / / --tmpfs"
ZPROFILE = ROOT / "rootfs" / "etc" / "zsh" / "zprofile"
TIOCSTI_SYSCTL = ROOT / "rootfs" / "etc" / "sysctl.d" / "62-fleet-tty-tiocsti.conf"
LOGIN_SHELL = shutil.which("zsh") or shutil.which("sh")
SEATS_REL = ".config/fleet-ops/seats"  # gitleaks:allow
SEAT_NAME = "claude-seat-a.env"
PROBE = "SEATPROBE"
WRAPPED_STUB = """#!/bin/sh
echo STUB-RAN
echo LISTING-BEGIN
ls -A "$SEATS_DIR"
echo LISTING-END
grep -F "$SEATS_DIR" /proc/mounts || true
"""


def doc_text() -> str:
    return DOC.read_text()


def launch_line(home: Path) -> list[str]:
    for line in doc_text().splitlines():
        if line.strip().startswith(LAUNCH_ANCHOR):
            tokens = [token.replace("~/", str(home) + "/") for token in shlex.split(line)]
            for flag in ("--dev-bind", "--tmpfs", "--proc", "--unshare-pid", "--die-with-parent"):
                assert flag in tokens, flag
            assert "--new-session" not in tokens, "setsid would take the interactive TUI's controlling terminal away"
            assert tokens[-1] == "claude", "the sandbox must launch the session program as its last token"
            return tokens[:-1]
    pytest.fail("no sandbox launch line under docs/managed-settings-defaults.md")




@pytest.fixture()
def fake_home(tmp_path_factory) -> Path:
    home = tmp_path_factory.mktemp("seat-sandbox-home")
    seats = home / SEATS_REL
    seats.mkdir(parents=True)
    (seats / SEAT_NAME).write_text(PROBE + "\n")
    return home


def run_case(command: str, home: Path, jailed: bool) -> subprocess.CompletedProcess:
    env = dict(os.environ, HOME=str(home))
    command_argv = ["bash", "-c", command]
    argv = launch_line(home) + command_argv if jailed else command_argv
    return subprocess.run(argv, env=env, cwd=home, capture_output=True, text=True)


def reached(result: subprocess.CompletedProcess) -> bool:
    return result.returncode == 0 and PROBE in result.stdout


def test_doc_states_the_launch_line() -> None:
    text = doc_text()
    assert LAUNCH_ANCHOR in text
    assert SEATS_REL in text
    for flag in ("--proc", "--unshare-pid", "--die-with-parent"):
        assert flag in text, flag


def test_bare_shell_reaches_the_probe_seat(fake_home: Path) -> None:
    result = run_case(f"cat {SEATS_REL}/{SEAT_NAME}", fake_home, jailed=False)
    assert reached(result), f"{result.stdout!r} {result.stderr!r}"


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_sandbox_blocks_the_relative_path_bypass(fake_home: Path) -> None:
    control = run_case("cat /etc/os-release", fake_home, jailed=True)
    assert control.returncode == 0 and control.stdout != "", (
        "the sandboxed control itself failed, so a blocked case below could be a dead harness"
    )
    jailed = run_case(f"cat {SEATS_REL}/{SEAT_NAME}", fake_home, jailed=True)
    assert not reached(jailed), f"the probe reached inside the sandbox: {jailed.stdout!r}"


@pytest.mark.skipif(subprocess.run(["sh", "-c", "command -v bwrap"], capture_output=True).returncode != 0,
                    reason="bubblewrap is not installed")
def test_the_zprofile_wrapper_carries_the_doc_sandbox() -> None:
    body = ZPROFILE.read_text()
    if "claude()" not in body:
        pytest.fail("rootfs/etc/zsh/zprofile defines no claude wrapper")
    fn = body[body.index("claude()"):]
    for flag in ("--dev-bind", "--tmpfs", "--proc", "--unshare-pid", "--die-with-parent"):
        assert flag in fn, flag
    assert "--new-session" not in fn, "setsid would take the interactive TUI's controlling terminal away"
    assert "command bwrap" in fn
    assert "command claude" in fn


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_a_login_shell_starts_claude_inside_the_sandbox(fake_home: Path, tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "claude"
    stub.write_text(WRAPPED_STUB)
    stub.chmod(0o755)
    env = dict(os.environ, HOME=str(fake_home), PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
               SEATS_DIR=str(fake_home / SEATS_REL))
    inside = subprocess.run([LOGIN_SHELL, "-c", f". {shlex.quote(str(ZPROFILE))}; claude"],
                            env=env, capture_output=True, text=True)
    assert inside.returncode == 0, inside.stderr
    lines = inside.stdout.splitlines()
    assert lines[0] == "STUB-RAN", inside.stdout
    listing = lines[lines.index("LISTING-BEGIN") + 1:lines.index("LISTING-END")]
    assert listing == [], f"the seats listing is not empty inside the sandbox: {inside.stdout!r}"
    assert any("tmpfs" in line and str(fake_home / SEATS_REL) in line for line in lines), inside.stdout
    bare = subprocess.run([LOGIN_SHELL, "-c", "claude"], env=env, capture_output=True, text=True)
    assert bare.returncode == 0, bare.stderr
    bare_lines = bare.stdout.splitlines()
    assert bare_lines[0] == "STUB-RAN", bare.stdout
    bare_listing = bare_lines[bare_lines.index("LISTING-BEGIN") + 1:bare_lines.index("LISTING-END")]
    assert bare_listing == [SEAT_NAME], f"the bare login shell cannot see the probe: {bare.stdout!r}"


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_a_login_shell_inside_the_sandbox_does_not_wrap_twice(fake_home: Path, tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "claude"
    stub.write_text(WRAPPED_STUB)
    stub.chmod(0o755)
    env = dict(os.environ, HOME=str(fake_home), PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
               SEATS_DIR=str(fake_home / SEATS_REL))
    script = f". {shlex.quote(str(ZPROFILE))}; claude"
    nested = subprocess.run(launch_line(fake_home) + [LOGIN_SHELL, "-c", script],
                            env=env, capture_output=True, text=True)
    assert nested.returncode == 0, nested.stderr
    lines = nested.stdout.splitlines()
    assert lines[0] == "STUB-RAN", nested.stdout
    assert lines[lines.index("LISTING-BEGIN") + 1:lines.index("LISTING-END")] == []
    assert sum("tmpfs" in line and str(fake_home / SEATS_REL) in line for line in lines) == 1, nested.stdout


def test_the_wrapper_refuses_to_start_claude_without_bwrap(fake_home: Path, tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "claude"
    stub.write_text(WRAPPED_STUB)
    stub.chmod(0o755)
    for tool in ("grep", "ls", "sh"):
        (bin_dir / tool).symlink_to(shutil.which(tool))
    env = dict(os.environ, HOME=str(fake_home), PATH=str(bin_dir), SEATS_DIR=str(fake_home / SEATS_REL))
    result = subprocess.run([LOGIN_SHELL, "-c", f". {shlex.quote(str(ZPROFILE))}; claude"],
                            env=env, capture_output=True, text=True)
    assert result.returncode != 0
    assert "STUB-RAN" not in result.stdout
    assert "bwrap is missing" in result.stderr


def test_the_box_turns_tiocsti_injection_off_on_every_kernel() -> None:
    settings = [line.split("=") for line in TIOCSTI_SYSCTL.read_text().splitlines()
                if line.strip() and not line.startswith("#")]
    assert [[k.strip(), v.strip()] for k, v in settings] == [["dev.tty.legacy_tiocsti", "0"]]


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_a_session_cannot_rewrite_the_owners_zsh_startup_file(fake_home: Path) -> None:
    rc = fake_home / ".zshrc"
    rc.write_text("# owner\n")
    result = run_case(f"echo 'claude() {{ command claude; }}' >> {shlex.quote(str(rc))}", fake_home, jailed=True)
    assert result.returncode != 0
    assert rc.read_text() == "# owner\n"
