"""The worker packet's prompt prefix stays static (fleet-ops#9363, #11032).

Dynamic text before `=== FLEET-DYNAMIC-BELOW ===` in prompts/worker.md breaks the
shared prompt-cache prefix, so the first call of every run pays full input price:
static text first, then the marker line, then everything dynamic. The same rule
holds at the source: agent.yml's pi command lines and packet strings carry no
per-run text, so every session starts with byte-identical static text no matter
the issue or worktree.
"""

import re
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "prompts/worker.md"
AGENT_YML = ROOT / ".github/workflows/agent.yml"
AGENTS_MD = ROOT / "AGENTS.md"
MARKER = "=== FLEET-DYNAMIC-BELOW ==="
DYNAMIC_TEXT = re.compile(r"\$[0-9@]|\$ARGUMENTS|/_work/|agent-runner/[0-9]|agent-worktrees/[A-Za-z-]*[0-9]")
APPEND_PROMPT = re.compile(r'--append-system-prompt +"[^"]*"')
CONSTANT_APPEND = re.compile(r'^--append-system-prompt +"\$HOME/(AGENTS\.md|workspaces/tooling/fleet-ops-deploy-clone/[^$"]*)"$')
TOOL_FLAG = re.compile(r"--(?:tools|exclude-tools|mcp-config) +[^ ]+")
HOME_AGENTS_MD = '--append-system-prompt "$HOME/AGENTS.md"'


def _up_to_marker(text):
    lines = text.splitlines()
    try:
        return lines[: lines.index(MARKER) + 1]
    except ValueError:
        raise AssertionError(f"no {MARKER!r} line, so no static prefix ends") from None


def _joined_lines():
    joined, pending = [], None
    for line in AGENT_YML.read_text().splitlines():
        if pending is not None:
            line = pending + " " + line.lstrip()
        if line.endswith("\\"):
            pending = line[:-1]
        else:
            pending = None
            joined.append(line)
    return joined


@pytest.fixture(scope="module")
def pi_lines():
    lines = [line for line in _joined_lines() if "pi --print" in line]
    assert lines, "agent.yml holds no pi --print line, so the prefix rule has no source to hold"
    return lines


def test_worker_packet_has_exactly_one_marker():
    assert WORKER.read_text().splitlines().count(MARKER) == 1


def test_no_dynamic_text_before_the_marker():
    hit = DYNAMIC_TEXT.search("\n".join(_up_to_marker(WORKER.read_text())))
    assert hit is None, f"dynamic text before the marker: {hit.group()!r}"


def test_two_issues_render_the_same_prefix_in_two_worktrees():
    renders = []
    with tempfile.TemporaryDirectory() as temp:
        for issue_id, worktree in (("fleet-ops-9361", "wt-1"), ("drive-503", "wt-2")):
            path = Path(temp) / worktree / f"issue-{issue_id}"
            path.mkdir(parents=True)
            (path / "AGENTS.md").write_text(AGENTS_MD.read_text())
            packet = (path / "AGENTS.md").read_text() + WORKER.read_text().replace("$1", issue_id)
            renders.append("\n".join(_up_to_marker(packet)))
    assert renders[0] == renders[1], "the static prefix depends on the issue id or worktree path"


def test_every_pi_line_carries_no_context_files(pi_lines):
    missing = [line for line in pi_lines if "--no-context-files" not in line]
    assert not missing, "pi lines without --no-context-files:\n" + "\n".join(missing)


def test_every_pi_line_appends_system_prompt_at_a_constant_path(pi_lines):
    bad = [match for line in pi_lines for match in APPEND_PROMPT.findall(line) if not CONSTANT_APPEND.match(match)]
    assert not bad, "--append-system-prompt not at the constant deploy-clone path:\n" + "\n".join(bad)


def test_every_pi_line_appends_the_home_agents_md(pi_lines):
    missing = [line for line in pi_lines if HOME_AGENTS_MD not in line]
    assert not missing, "pi lines that drop the ~/AGENTS.md writing rules:\n" + "\n".join(missing)


def test_tool_flags_are_literal_and_sorted(pi_lines):
    bad = []
    for line in pi_lines:
        for flag in TOOL_FLAG.findall(line):
            name, _, value = flag.partition(" ")
            value = value.lstrip()
            if "$" in value:
                bad.append(f"{name} value not literal: {value}")
            elif "," in value and value.split(",") != sorted(value.split(",")):
                bad.append(f"{name} list not sorted: {value}")
    assert not bad, "tool flags must be literal and, where a list, sorted:\n" + "\n".join(bad)


def test_packet_strings_keep_the_issue_id_after_the_marker():
    before = [line.split(MARKER)[0] for line in AGENT_YML.read_text().splitlines() if 'packet="' in line]
    assert before, "agent.yml holds no packet= string, so the packet rule has no source to hold"
    bad = [line for line in before if "$id" in line]
    assert not bad, "$id before the marker in a packet string:\n" + "\n".join(bad)
