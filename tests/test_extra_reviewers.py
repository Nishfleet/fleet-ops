"""review/extra_reviewers.py: every way an extra reviewer can fail, and the loud give-up (fleet-ops#10551)."""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "review/extra_reviewers.py"
spec = importlib.util.spec_from_file_location("extra_reviewers", PROGRAM)
er = importlib.util.module_from_spec(spec)
spec.loader.exec_module(er)

GLM, QWEN, DS = "synthetic-glm53flash-senior", "alibaba-qwen38max-judge", "deepseek-v4-assistant"


@pytest.fixture
def run(tmp_path, monkeypatch):
    """A fake router: answers[seat] is a list of (row id or None, content, finish_reason) or an int curl
    exit, one per call (the last repeats). Returns the calls made and the gh calls."""
    for k, v in {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0 0", "REPO": "Nishfleet/fleet-ops", "PR": "7",
                 "SHA": "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345", "SECOND_SEAT": "senior", "SECOND_FAMILY": "GLM",
                 "THIRD_SEAT": "judge", "THIRD_FAMILY": "Qwen", "JUDGE_FAMILY": "Jev"}.items():
        monkeypatch.setenv(k, v)
    calls, ghs, answers = [], [], {}

    def ask_row(seat, pre):
        calls.append((seat, pre))
        seq = answers[seat]
        a = seq.pop(0) if len(seq) > 1 else seq[0]
        if isinstance(a, int):
            (tmp_path / f"{pre}-body.json").write_text("")
            (tmp_path / f"{pre}-headers.txt").write_text("")
            return a
        row, content, fr = a
        (tmp_path / f"{pre}-headers.txt").write_text(f"x-litellm-model-id: {row}\r\n" if row else "")
        (tmp_path / f"{pre}-body.json").write_text(json.dumps(
            {"choices": [{"finish_reason": fr, "message": {"content": content}}]}))
        return 0

    def gh(*args):
        ghs.append(args)
        out = "https://github.com/Nishfleet/fleet-ops/issues/99\n" if args[:2] == ("issue", "create") else ""
        return subprocess.CompletedProcess(args, 0, out, "")

    monkeypatch.setattr(er, "ask_row", ask_row)
    monkeypatch.setattr(er, "gh", gh)

    def go(**kw):
        answers.clear()
        answers.update(kw)
        try:
            er.main()
            return 0
        except SystemExit as e:
            return e.code

    return go, calls, ghs, tmp_path


def comment(ghs):
    return [a[a.index("--body") + 1] for a in ghs if a[:2] == ("pr", "comment")]


def test_family_of_reads_the_row_id():
    assert [er.family_of(r) for r in (GLM, QWEN, DS, "ds4-flash", "claude-opus-5-5", "")] == \
        ["GLM", "Qwen", "DeepSeek", "DeepSeek", "", ""]


def test_both_families_answer(run, capsys):
    go, calls, ghs, t = run
    assert go(senior=[(GLM, "No blockers.\nAPPROVE", "stop")], judge=[(QWEN, "APPROVE\n", "stop")]) == 0
    assert capsys.readouterr().out.strip() == "Jev GLM Qwen"
    assert (t / "second.txt").read_text() == "No blockers.\nAPPROVE" and (t / "third.txt").read_text() == "APPROVE"
    assert (t / "second-row").read_text() == GLM and (t / "third-family").read_text() == "Qwen"
    assert sorted(calls) == [("judge", "third"), ("senior", "second")] and ghs == []


def test_no_row_id_retries_then_falls_back(run, capsys):
    go, calls, ghs, t = run
    assert go(senior=[(None, "APPROVE", "stop")], judge=[(QWEN, "APPROVE", "stop")], assistant=[(DS, "APPROVE", "stop")]) == 0
    assert calls.count(("senior", "second")) == 3 and ("assistant", "second") in calls
    assert capsys.readouterr().out.strip() == "Jev Qwen DeepSeek"
    assert (t / "second-why").read_text() == "answered by no row id (no known non-Claude family), not the GLM family"


def test_wrong_family_is_not_a_review(run):
    go, calls, ghs, t = run
    assert go(senior=[(QWEN, "APPROVE", "stop")], judge=[(QWEN, "APPROVE", "stop")], assistant=[(DS, "APPROVE", "stop")]) == 0
    assert (t / "second-why").read_text() == f"answered by {QWEN} (Qwen), not the GLM family"
    assert (t / "second-row").read_text() == DS


def test_fallback_answered_by_a_family_that_already_reviewed(run):
    go, calls, ghs, t = run
    assert go(senior=[7], judge=[(QWEN, "APPROVE", "stop")], assistant=[(QWEN, "APPROVE", "stop")]) == 1
    assert (t / "second-why").read_text() == f"answered by {QWEN} (Qwen), a family that already reviewed this head"
    assert "a family that already reviewed this head" in comment(ghs)[0]


def test_length_cut_is_retried(run, capsys):
    go, calls, ghs, t = run
    assert go(senior=[(GLM, "half a review", "length"), (GLM, "APPROVE", "stop")], judge=[(QWEN, "APPROVE", "stop")]) == 0
    assert calls.count(("senior", "second")) == 2 and (t / "second.txt").read_text() == "APPROVE"
    assert (t / "second-why").read_text() == "the answer was cut at its token limit or empty"


def test_a_malformed_answer_is_retried_not_a_crash(run):
    go, calls, _, t = run
    assert go(senior=[(GLM, "APPROVE", "stop")], judge=[(QWEN, "APPROVE", "stop")]) == 0
    for body in ('{"choices": ["x"]}', '{"choices": "x"}', '{"choices": [{"message": "x"}]}', '"x"'):
        (t / "third-body.json").write_text(body)
        assert er.judge_answer("third", "Qwen", [])[3] in {
            "the answer was cut at its token limit or empty", "the call failed or its answer was not JSON (curl exit 0)"}


def test_retries_run_out_files_one_loud_issue(run):
    go, calls, ghs, t = run
    assert go(senior=[7], judge=[(QWEN, "APPROVE", "stop")], assistant=[7]) == 1
    assert calls.count(("senior", "second")) == 3 and calls.count(("assistant", "second")) == 3
    created = [a for a in ghs if a[:2] == ("issue", "create")]
    assert len(created) == 1 and "review-retry" in created[0]
    assert comment(ghs) == [(
        "review of 3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345 did not finish after retries: the second reviewer and the "
        "fallback family both failed; the last reason: the call failed or its answer was not JSON (curl exit 7). "
        "Nothing was approved or blocked. Issue #99 is filed; a new head also gets a fresh review.")]


def test_a_crashed_reviewer_gives_up_loud(run, monkeypatch):
    go, calls, ghs, t = run
    monkeypatch.setattr(er, "seat_try", lambda *a: 1 / 0)
    assert go() == 1
    assert "reviewer process crashed: the second reviewer raised ZeroDivisionError" in comment(ghs)[0]


def test_curl_gets_the_key_on_stdin_never_in_argv(tmp_path):
    home, bin_ = tmp_path / "home", tmp_path / "bin"
    (home / er.DEPLOY / "prompts").mkdir(parents=True)
    (home / ".config/fleet-ops/seats").mkdir(parents=True)
    bin_.mkdir()
    (home / "AGENTS.md").write_text("agents ")
    (home / er.DEPLOY / "prompts/risky-review.md").write_text("review")
    (home / ".config/fleet-ops/seats/typesafe-jev.env").write_text("OTHER=1\nLITELLM_JEV_KEY=sk-test\n")
    (tmp_path / "extra-in.txt").write_text("the diff")
    # The fake router records argv and stdin, then answers as the row of the asked seat's family.
    (bin_ / "curl").write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$RUNNER_TEMP/argv"; cat >> "$RUNNER_TEMP/stdin"
while [ $# -gt 0 ]; do case $1 in -D) h=$2 ;; -o) b=$2 ;; --data-binary) r=${2#@} ;; esac; shift; done
case $(grep -o '"model": "[a-z0-9-]*"' "$r") in *senior*) row=glm-x ;; *) row=qwen-x ;; esac
printf 'x-litellm-model-id: %s\\r\\n' "$row" > "$h"
printf '{"choices":[{"finish_reason":"stop","message":{"content":"APPROVE"}}]}' > "$b"
""")
    (bin_ / "curl").chmod(0o755)
    e = {"PATH": f"{bin_}:{os.environ['PATH']}", "HOME": str(home), "RUNNER_TEMP": str(tmp_path), "PR": "7",
         "FLEET_TASK_ID": "review-1-1", "REVIEW_BACKOFF": "0", "SECOND_SEAT": "senior", "SECOND_FAMILY": "GLM",
         "THIRD_SEAT": "judge", "THIRD_FAMILY": "Qwen", "JUDGE_FAMILY": "Jev"}
    p = subprocess.run([sys.executable, "-I", str(PROGRAM)], env=e, capture_output=True, text=True, check=False)
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == "Jev GLM Qwen"
    argv = (tmp_path / "argv").read_text()
    assert "sk-test" not in argv and "--config -" in argv
    assert "x-litellm-session-id: review-1-1-pr7-second-senior" in argv and "review-1-1-pr7-third-judge" in argv
    assert (tmp_path / "stdin").read_text().count('header = "Authorization: Bearer sk-test"') == 2
    req = json.loads((tmp_path / "second-req.json").read_text())
    assert req["messages"] == [{"role": "system", "content": "agents review"}, {"role": "user", "content": "the diff"}]
    assert req["max_tokens"] == 32768 and req["stream"] is False
