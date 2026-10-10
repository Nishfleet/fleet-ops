"""scripts/pick-claude-seat.sh: the Claude seat is chosen once per job by a
two-hour time bucket, skipped when full, and kept when the usage call fails.

Only `curl` is a stub on PATH; jq and the script are real. The stub records its
argv so the test can prove the token never reaches it (argv is world-readable).
"""
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/pick-claude-seat.sh"
TOKENS = {"a": "tok-seat-a-secret", "b": "tok-seat-b-secret"}
STUB = """#!/bin/bash
echo "$*" >> "$STUB_LOG"
cfg=
while [ $# -gt 0 ]; do [ "$1" = --config ] && cfg=$2; shift; done
tok=$(sed -n 's/^header = "Authorization: Bearer \\(.*\\)"$/\\1/p' "$cfg")
echo "$tok" >> "$STUB_TOKENS"
[ -z "$FAIL" ] || exit 22
case "$tok" in
  tok-seat-a-secret) echo "{\\"five_hour\\":{\\"utilization\\":$UTIL_A}}" ;;
  tok-seat-b-secret) echo "{\\"five_hour\\":{\\"utilization\\":$UTIL_B}}" ;;
  *) echo '{"error":"no token"}' ;;
esac
"""


def _run(tmp_path, epoch, util_a="10.0", util_b="20.0", fail=False, cfg_dir=True):
    home = tmp_path / "home"
    runner = tmp_path / "runner-config"
    for d, t in ((runner, TOKENS["a"]), (home / ".claude", TOKENS["b"])):
        d.mkdir(parents=True, exist_ok=True)
        (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": t}}))
        (d / ".credentials.json").chmod(0o400)  # a write would fail
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    (bindir / "curl").write_text(STUB)
    (bindir / "curl").chmod(0o755)
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "CLAUDE_SEAT_EPOCH": str(epoch),
        "UTIL_A": util_a,
        "UTIL_B": util_b,
        "FAIL": "1" if fail else "",
        "STUB_LOG": str(tmp_path / "curl.log"),
        "STUB_TOKENS": str(tmp_path / "tokens.log"),
    }
    env.pop("CLAUDE_CONFIG_DIR", None)
    if cfg_dir:
        env["CLAUDE_CONFIG_DIR"] = str(runner)
    r = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    argv = (tmp_path / "curl.log").read_text() if (tmp_path / "curl.log").exists() else ""
    assert not any(t in argv + r.stdout + r.stderr for t in TOKENS.values()), "token leaked"
    toks = (tmp_path / "tokens.log").read_text().split() if (tmp_path / "tokens.log").exists() else []
    return r, toks


def _line(r):
    return re.search(r"^claude seat: .*$", r.stderr, re.M).group(0)


def test_bucket_0_keeps_runner_seat(tmp_path):
    r, toks = _run(tmp_path, 0)
    assert r.stdout.strip() == "keep"
    assert _line(r) == "claude seat: bucket=0 seat=a five_hour=10.0"
    assert toks == [TOKENS["a"]]


def test_bucket_1_drops_config_dir(tmp_path):
    r, toks = _run(tmp_path, 7200)
    assert r.stdout.strip() == "default"
    assert _line(r) == "claude seat: bucket=1 seat=b five_hour=20.0"
    assert toks == [TOKENS["b"]]


def test_buckets_alternate_every_two_hours(tmp_path):
    got = []
    for i, epoch in enumerate((0, 7199, 7200, 14399, 14400, 21600)):
        d = tmp_path / str(i)
        d.mkdir()
        got.append(_run(d, epoch)[0].stdout.strip())
    assert got == ["keep", "keep", "default", "default", "keep", "default"]


def test_full_seat_is_skipped_at_95(tmp_path):
    r, toks = _run(tmp_path, 0, util_a="95.0", util_b="30.5")
    assert r.stdout.strip() == "default"
    assert _line(r) == "claude seat: bucket=0 seat=b five_hour=30.5"
    assert toks == [TOKENS["a"], TOKENS["b"]]


def test_just_under_95_is_not_skipped(tmp_path):
    r, _ = _run(tmp_path, 0, util_a="94.9", util_b="0")
    assert r.stdout.strip() == "keep"


def test_full_bucket_1_seat_skips_to_runner_seat(tmp_path):
    r, _ = _run(tmp_path, 7200, util_a="5", util_b="100")
    assert r.stdout.strip() == "keep"
    assert _line(r) == "claude seat: bucket=1 seat=a five_hour=5"


def test_both_full_keeps_bucket_seat_with_warning(tmp_path):
    r, _ = _run(tmp_path, 0, util_a="99", util_b="99")
    assert r.stdout.strip() == "keep"
    assert "::warning::" in r.stderr
    assert _line(r) == "claude seat: bucket=0 seat=a five_hour=99"


def test_usage_call_failure_keeps_bucket_seat_with_warning(tmp_path):
    for i, (epoch, want) in enumerate(((0, "keep"), (7200, "default"))):
        d = tmp_path / str(i)
        d.mkdir()
        r, _ = _run(d, epoch, fail=True)
        assert r.stdout.strip() == want
        assert "::warning::" in r.stderr
        assert _line(r).endswith("five_hour=n/a")


def test_unparseable_usage_keeps_bucket_seat(tmp_path):
    r, _ = _run(tmp_path, 0, util_a='"x"')
    assert r.stdout.strip() == "keep"
    assert "::warning::" in r.stderr


def test_unset_config_dir_keeps_default(tmp_path):
    r, toks = _run(tmp_path, 0, cfg_dir=False)
    assert r.stdout.strip() == "keep"
    assert toks == []


def test_credentials_files_are_read_only_in_the_script():
    # Mode 0400 above already makes a write fail; this pins the source too.
    src = SCRIPT.read_text()
    assert not re.search(r"(>|>>|tee|mv|cp|sed -i|touch|chmod)\s*\S*credentials", src)


def test_workflow_calls_script_before_launch():
    wf = (ROOT / ".github/workflows/agent-dispatch.yml").read_text()
    i = wf.index("pick-claude-seat.sh")
    assert i < wf.index(".local/bin/claude -p")
    assert 'unset CLAUDE_CONFIG_DIR' in wf
