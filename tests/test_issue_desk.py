"""issue-desk is one Tincan agent with three tools and no shell: its unit keeps the no-tools flags and its extension tests pass."""

import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/tincan-listen-issue-desk.service"
EXTENSION = ROOT / "pi-extensions/issue-desk"
PROMPT = ROOT / "prompts/issue-desk.md"
TOOLS = {"tincan_inbox", "file_issue", "tincan_reply"}
TINCAN = "/.local/bin/tincan"

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(text: str) -> str:
    return ANSI.sub("", text)


NO_TOOLS_FLAGS = [
    "--no-session",
    "--no-builtin-tools",
    "--no-extensions",
    "--no-mcp",
    "--no-skills",
    "--no-context-files",
    "--no-prompt-templates",
]


def exec_start() -> str:
    for line in UNIT.read_text().splitlines():
        if line.startswith("ExecStart="):
            return line.removeprefix("ExecStart=")
    raise AssertionError(f"{UNIT.name} has no ExecStart")


def pi_argv() -> list[str]:
    argv = shlex.split(exec_start())
    assert argv[0].endswith(TINCAN) and argv[1:3] == ["listen", "--exec"], argv[:3]
    return shlex.split(argv[3])


def test_the_wake_is_the_vendors_own_listen_command() -> None:
    argv = shlex.split(exec_start())
    assert argv[0].endswith(TINCAN)
    assert argv[1] == "listen"
    assert argv[2] == "--exec"


def test_the_model_gets_no_tools_except_the_extension() -> None:
    argv = pi_argv()
    assert argv[0].endswith("/.local/bin/pi")
    missing = [flag for flag in NO_TOOLS_FLAGS if flag not in argv]
    assert missing == [], f"pi would load more than the three tools; missing {missing}"
    extensions = [argv[index + 1] for index, arg in enumerate(argv) if arg == "-e"]
    assert len(extensions) == 1, extensions
    assert extensions[0].endswith("/pi-extensions/issue-desk/index.ts")
    assert argv[argv.index("--provider") + 1] == "litellm"
    assert argv[argv.index("--model") + 1] == "worker-cheap"


def test_the_prompt_reaches_pi_on_stdin() -> None:
    argv = pi_argv()
    assert argv[-2] == "<"
    assert argv[-1].endswith("/prompts/issue-desk.md")
    assert PROMPT.is_file()
    text = PROMPT.read_text()
    assert len(text) > 200
    for tool in TOOLS:
        assert tool in text, f"prompts/issue-desk.md never names {tool}"


def test_a_failed_run_pages_through_the_dead_man() -> None:
    text = UNIT.read_text()
    assert "OnFailure=fleet-unit-failed@%N.service" in text
    assert "Restart=always" in text
    assert "TINCAN_CONFIG=" in text
    assert "/tincan/issue-desk.json" in text


def test_the_extension_registers_exactly_the_three_tools() -> None:
    source = (EXTENSION / "index.ts").read_text()
    registered = re.findall(r'pi\.registerTool\(\{\s*\n\s*name: "([a-z_]+)"', source)
    assert sorted(registered) == sorted(TOOLS)
    assert "registerCommand" not in source
    assert "registerFlag" not in source
    manifest = EXTENSION / "package.json"
    assert '"extensions": ["./index.ts"]' in manifest.read_text()


def test_the_extension_can_reach_no_shell_and_no_path() -> None:
    for source in sorted(EXTENSION.glob("src/*.ts")):
        text = source.read_text()
        assert "exec(" not in text.replace("execFile(", ""), source.name
        assert "shell: true" not in text, source.name
    schema = (EXTENSION / "index.ts").read_text()
    for name in ("command", "path", "argv"):
        assert f"{name}:" not in schema, f"a tool parameter is called {name}"


def test_the_desk_never_skips_admission() -> None:
    issue = (EXTENSION / "src/issue.ts").read_text()
    assert '"needs-triage"' in issue
    assert "agent-ready" not in issue
    for source in [*(EXTENSION / "src").glob("*.ts"), EXTENSION / "index.ts"]:
        assert "--add-label" not in source.read_text(), source.name


NODE_MIN = (22, 12)


def node_is_new_enough() -> bool:
    node = shutil.which("node")
    if node is None:
        return False
    out = subprocess.run(
        [node, "--version"], capture_output=True, text=True, check=False
    ).stdout.strip()
    match = re.match(r"v(\d+)\.(\d+)", out)
    if match is None:
        return False
    return (int(match.group(1)), int(match.group(2))) >= NODE_MIN


@pytest.mark.skipif(shutil.which("npm") is None, reason="npm is not installed")
@pytest.mark.skipif(
    not node_is_new_enough(), reason="vitest 5 needs node 22.12 or newer"
)
def test_the_extension_tests_pass() -> None:
    install = subprocess.run(
        ["npm", "ci", "--no-audit", "--no-fund"],
        cwd=EXTENSION,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )
    assert install.returncode == 0, install.stderr
    tests = subprocess.run(
        ["npm", "test"],
        cwd=EXTENSION,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )
    assert tests.returncode == 0, tests.stdout + tests.stderr
    clean = strip_ansi(tests.stdout)
    assert "failed" not in clean, clean
    assert re.search(r"Test Files\s+4 passed", clean), clean
    assert re.search(r"Tests\s+\d+ passed", clean), clean
