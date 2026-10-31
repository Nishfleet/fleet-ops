import re
import subprocess
from pathlib import Path

import yaml

WF = Path(__file__).parents[1] / ".github/workflows/agent.yml"


def delays():
    text = WF.read_text()
    declared = re.search(r'REVIEW_BACKOFF: "([^"]+)"', text).group(1).split()
    fallback = re.search(r"\$\{REVIEW_BACKOFF:-([^}]+)\}", text).group(1).split()
    assert declared == fallback
    return declared


def claude_calls():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    return run[run.index("ask_claude() {"):run.index("\n", run.index("ask_claude() {"))]


def claude_retry(tmp_path, answers, backoff="0"):
    for d in ("workspaces/tooling/fleet-ops-deploy-clone/prompts", "bin"):
        (tmp_path / d).mkdir(parents=True)
    (tmp_path / "workspaces/tooling/fleet-ops-deploy-clone/prompts/risky-review.md").write_text("")
    (tmp_path / "AGENTS.md").write_text("")
    (tmp_path / "in").write_text("diff")
    (tmp_path / "bin/claude").write_text(f'#!/bin/bash\necho x >> "$CALLS"\n[ "$(wc -l < "$CALLS")" -le {answers} ] && exit 0\nprintf "no blocker lines\\nAPPROVE"\n')
    (tmp_path / "bin/claude").chmod(0o755)
    script = claude_calls() + '\nout=$(ask_claude opus "$IN" "$ERR" "$ANS"); echo "rc=$?"; echo "calls=$(wc -l < "$CALLS")"; echo "out=$out"\n'
    env = {"HOME": str(tmp_path), "REVIEW_BACKOFF": backoff, "IN": str(tmp_path / "in"), "CALLS": str(tmp_path / "calls"), "ERR": str(tmp_path / "err"), "ANS": str(tmp_path / "ans"), "PATH": f"{tmp_path}/bin:/usr/bin:/bin"}
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout


def test_an_empty_claude_answer_is_asked_again(tmp_path):
    out = claude_retry(tmp_path, answers=1, backoff="0 0")
    assert "rc=0" in out and "calls=2" in out and "APPROVE" in out


def test_a_claude_seat_that_never_answers_uses_every_delay(tmp_path):
    n = len(delays())
    out = claude_retry(tmp_path, answers=99, backoff=" ".join(["0"] * n))
    assert "rc=1" in out and f"calls={n + 1}" in out


def test_all_three_claude_reviews_are_asked_again():
    text = WF.read_text()
    assert "for d in 0 ${REVIEW_BACKOFF" in claude_calls()
    assert 'review=$(ask_claude "$first_model" "$RUNNER_TEMP/diff.txt" "$RUNNER_TEMP/first.err" "$RUNNER_TEMP/first.ans")' in text
    assert 'r2=$(ask_claude "$SECOND_MODEL" "$RUNNER_TEMP/extra-in.txt" "$RUNNER_TEMP/second.err" "$RUNNER_TEMP/second.ans")' in text
    assert 'r3=$(ask_claude "$THIRD_MODEL" "$RUNNER_TEMP/extra-in.txt" "$RUNNER_TEMP/third.err" "$RUNNER_TEMP/third.ans")' in text


def hold_functions():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    lines = run.split("\n")
    at = next(i for i, l in enumerate(lines) if "hold_at_limit()" in l)
    one = [l for l in lines if l.lstrip().startswith(('lim_re="', "lim_only() {", "ask_claude() {"))]
    return "\n".join(one + lines[at:at + 3])


def limit_answer(tmp_path, line, backoff="0 0 0", code=1, to="err"):
    for d in ("workspaces/tooling/fleet-ops-deploy-clone/prompts", "bin"):
        (tmp_path / d).mkdir(parents=True)
    (tmp_path / "workspaces/tooling/fleet-ops-deploy-clone/prompts/risky-review.md").write_text("")
    (tmp_path / "AGENTS.md").write_text("")
    (tmp_path / "in").write_text("diff")
    (tmp_path / "line").write_text(line + "\n")
    (tmp_path / "bin/claude").write_text(f'#!/bin/bash\ncat > /dev/null; echo x >> "$CALLS"; cat "$LINE" {" >&2" if to == "err" else ""}; exit {code}\n')
    (tmp_path / "bin/claude").chmod(0o755)
    script = hold_functions() + '''
say() { printf "%s\\n" "$1" >> "$SAID"; }
SHA=deadbeefcafe
rc=0; out=$(ask_claude opus "$IN" "$RUNNER_TEMP/err" "$RUNNER_TEMP/ans") || rc=$?
echo "rc=$rc calls=$(wc -l < "$CALLS")"; echo "out=$out"
if [ "$rc" = 2 ]; then hold_at_limit "$RUNNER_TEMP/err" "$RUNNER_TEMP/ans" "first review" opus; fi
echo "no-hold"
'''
    env = {"HOME": str(tmp_path), "RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": backoff, "IN": str(tmp_path / "in"), "LINE": str(tmp_path / "line"), "CALLS": str(tmp_path / "calls"), "SAID": str(tmp_path / "said"), "PATH": f"{tmp_path}/bin:/usr/bin:/bin"}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout
    said = tmp_path / "said"
    return out, said.read_text() if said.exists() else ""


def test_a_usage_limit_line_ends_the_ladder_and_holds_the_head(tmp_path):
    out, said = limit_answer(tmp_path, "You've hit your 5-hour limit · resets 11pm (Asia/Kolkata)")
    assert "rc=2 calls=1" in out and "no-hold" not in out
    assert said.startswith("review-held: deadbeefcafe") and "Nothing was approved or blocked" in said


def test_a_limit_line_wrapped_in_json_holds_the_head(tmp_path):
    out, said = limit_answer(tmp_path, '{"text":"You have reached your weekly limit · resets Nov 2"}')
    assert "rc=2 calls=1" in out and "no-hold" not in out and "review-held: deadbeefcafe" in said


def test_a_review_that_quotes_a_limit_line_is_still_a_review(tmp_path):
    out, said = limit_answer(tmp_path, 'blocker none\nrisk: the review can print "You\'ve hit your 5-hour limit · resets 11pm"\nnit: y', code=0, to="out")
    assert "rc=0 calls=1" in out and "no-hold" in out and said == ""


def test_a_one_line_answer_that_is_not_a_limit_keeps_the_retries(tmp_path):
    out, said = limit_answer(tmp_path, "You're out of usage credits")
    assert "rc=1 calls=4" in out and "no-hold" in out and said == ""


def test_a_seat_b_limit_with_a_seat_a_fault_still_holds(tmp_path):
    for d in ("workspaces/tooling/fleet-ops-deploy-clone/prompts", "bin", "seats"):
        (tmp_path / d).mkdir(parents=True)
    (tmp_path / "workspaces/tooling/fleet-ops-deploy-clone/prompts/risky-review.md").write_text("")
    (tmp_path / "AGENTS.md").write_text("")
    (tmp_path / "in").write_text("diff")
    (tmp_path / "seats/claude-seat-a.env").write_text("CLAUDE_CODE_OAUTH_TOKEN=tok-a\n")
    (tmp_path / "bin/claude").write_text('#!/bin/bash\ncat > /dev/null; echo x >> "$CALLS"\nif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo "You\'re out of usage credits" >&2; exit 1; fi\nprintf "You\'ve hit your 5-hour limit · resets 11pm (Asia/Kolkata)"\nexit 1\n')
    (tmp_path / "bin/claude").chmod(0o755)
    script = hold_functions() + '''
say() { printf "%s\\n" "$1" >> "$SAID"; }
SHA=deadbeefcafe
rc=0; out=$(ask_claude opus "$IN" "$RUNNER_TEMP/err" "$RUNNER_TEMP/ans") || rc=$?
echo "rc=$rc calls=$(wc -l < "$CALLS")"
if [ "$rc" = 2 ]; then hold_at_limit "$RUNNER_TEMP/err" "$RUNNER_TEMP/ans" "first review" opus; fi
echo "no-hold"
'''
    env = {"HOME": str(tmp_path), "RUNNER_TEMP": str(tmp_path), "CREDENTIALS_DIRECTORY": str(tmp_path / "seats"), "REVIEW_BACKOFF": "0 0", "IN": str(tmp_path / "in"), "CALLS": str(tmp_path / "calls"), "SAID": str(tmp_path / "said"), "PATH": f"{tmp_path}/bin:/usr/bin:/bin"}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout
    said = tmp_path / "said"
    said = said.read_text() if said.exists() else ""
    assert "rc=2 calls=2" in out and "no-hold" not in out
    assert said.startswith("review-held: deadbeefcafe") and "resets 11pm" in said
