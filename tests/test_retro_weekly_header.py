import os
import pathlib
import re
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/retro-weekly.service"
PROMPT = ROOT / "prompts/retro-weekly.md"


def header_command():
    text = UNIT.read_text()
    model_step = next(
        line for line in text.splitlines() if line.startswith("ExecStart=") and "umask 077; d=" in line
    )
    match = re.search(r"\{ cat \"\$\$RETRO_REPO/prompts/retro-weekly.md\"; (printf .*?); \}\s*\|\s*bwrap", model_step)
    assert match
    return match.group(1).replace("$$", "$").replace("%%", "%")


def make_file(path, size, age_days=0):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)
    stamp = time.time() - age_days * 86400
    os.utime(path, (stamp, stamp))


def run_header(tmp_path):
    make_file(tmp_path / ".claude/projects/p1/a.jsonl", 100)
    make_file(tmp_path / ".claude/projects/p1/sub/subagent.jsonl", 7)
    make_file(tmp_path / ".claude/projects/p2/old.jsonl", 9, age_days=10)
    make_file(tmp_path / ".pi/agent/sessions/w/deep/c.jsonl", 50)
    result = subprocess.run(
        ["bash", "-c", header_command()],
        env={"PATH": os.environ["PATH"], "HOME": str(tmp_path), "TZ": "Asia/Kolkata", "d": "2026-10-21", "run": "/r"},
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def test_header_carries_the_week_start_and_the_session_counts(tmp_path):
    assert run_header(tmp_path) == (
        "RUN_DIR=/r\nTODAY=2026-10-21\nWEEK_START=2026-10-14\n"
        "CLAUDE_SESSIONS=1\t100\nPI_SESSIONS=1\t50\n"
    )


def test_prompt_names_every_header_line(tmp_path):
    prompt = PROMPT.read_text()
    for line in run_header(tmp_path).splitlines():
        assert line.split("=")[0] in prompt
