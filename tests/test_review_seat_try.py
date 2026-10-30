import re
import subprocess
from pathlib import Path

import yaml

WF = Path(__file__).parents[1] / ".github/workflows/agent.yml"

OK_HEADERS = "HTTP/1.1 200 OK\r\nx-litellm-call-id: 7c943b89\r\nx-litellm-model-id: alibaba-qwen38max-judge\r\nx-litellm-model-name: openai/qwen3.8-max\r\n\r\n"
OK_BODY = '{"id":"x","model":"judge","object":"chat.completion","choices":[{"finish_reason":"stop","index":0,"message":{"content":"APPROVE","role":"assistant"}}]}'
ERR_HEADERS = "HTTP/1.1 429 Too Many Requests\r\ncontent-type: application/json\r\n\r\n"
ERR_BODY = '{"error":{"message":"Too many concurrent requests","type":"None","param":"None","code":"429"}}'


def functions():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    return run[run.index("family_of() {"):run.index("# After every retry")]


def delays():
    text = WF.read_text()
    declared = re.search(r'REVIEW_BACKOFF: "([^"]+)"', text).group(1).split()
    fallback = re.search(r"\$\{REVIEW_BACKOFF:-([^}]+)\}", text).group(1).split()
    assert declared == fallback
    return declared


def seat_try(tmp_path, headers, body, want="Qwen", used="Jev Claude", ask=None, backoff="0"):
    (tmp_path / "h").write_text(headers)
    (tmp_path / "b").write_text(body)
    stub = ask or 'ask_row() { cp "$H" "$RUNNER_TEMP/$2-headers.txt"; cp "$B" "$RUNNER_TEMP/$2-body.json"; }'
    script = functions() + stub + f'\nseat_try judge third "{want}" "{used}"; echo "rc=$?"; cat "$RUNNER_TEMP/third-why" 2>/dev/null; cat "$RUNNER_TEMP/third-row" 2>/dev/null\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": backoff, "H": str(tmp_path / "h"), "B": str(tmp_path / "b"), "PATH": "/usr/bin:/bin"}
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout


def test_row_id_header_names_the_family(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY)
    assert "rc=0" in out and out.endswith("alibaba-qwen38max-judge")


def test_router_error_is_named_not_just_an_empty_row_id(tmp_path):
    out = seat_try(tmp_path, ERR_HEADERS, ERR_BODY)
    assert "rc=1" in out and "no row id, the router said: Too many concurrent requests" in out


def test_family_that_already_reviewed_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY, want="", used="Jev Claude Qwen")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_fallback_is_asked_through_the_assistant_seat_not_the_judge_seat():
    text = WF.read_text()
    assert 'seat_try assistant third "" "$used"' in text
    assert 'seat_try "$THIRD_SEAT" third "" "$used"' not in text


def test_assistant_row_is_a_new_family_after_claude_reviewed(tmp_path):
    headers = OK_HEADERS.replace("alibaba-qwen38max-judge", "opencodego-ds41flash-assistant")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Claude")
    assert "rc=0" in out and out.endswith("opencodego-ds41flash-assistant")


def test_judge_row_is_refused_once_qwen_reviewed(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY, want="", used="Jev Claude Qwen")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_a_claude_row_never_counts_as_the_non_claude_fallback(tmp_path):
    headers = OK_HEADERS.replace("alibaba-qwen38max-judge", "anthropic-claude-opus-55-assistant")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Claude")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_reviewer_request_disables_router_fallbacks():
    ask = next(l for l in WF.read_text().splitlines() if "{model: $m, stream: false" in l)
    assert "disable_fallbacks: true" in ask


def test_row_from_no_known_family_is_refused(tmp_path):
    headers = OK_HEADERS.replace("alibaba-qwen38max-judge", "acme-model1-assistant")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Claude Qwen")
    assert "rc=1" in out and "no known non-Claude family" in out


def test_stepfun_row_is_a_new_family(tmp_path):
    headers = OK_HEADERS.replace("alibaba-qwen38max-judge", "stepfun-step5preview-worker-capable")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Claude Qwen")
    assert "rc=0" in out and out.endswith("stepfun-step5preview-worker-capable")


def test_stepfun_row_is_refused_once_stepfun_reviewed(tmp_path):
    headers = OK_HEADERS.replace("alibaba-qwen38max-judge", "stepfun-step5preview-worker-capable")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Claude StepFun")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_row_of_the_wrong_family_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY, want="GLM", used="")
    assert "rc=1" in out and "(Qwen), not the GLM family" in out


def test_answer_cut_at_its_token_limit_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY.replace('"stop"', '"length"'))
    assert "rc=1" in out and "cut at its token limit or empty" in out


def test_empty_answer_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY.replace('"APPROVE"', '" \\n "'))
    assert "rc=1" in out and "cut at its token limit or empty" in out


def test_retries_run_out_on_a_failed_call(tmp_path):
    n = len(delays())
    out = seat_try(tmp_path, "", "", backoff=" ".join(["0"] * n), ask='ask_row() { echo x >> "$RUNNER_TEMP/calls"; return 7; }\n')
    assert "rc=1" in out and "curl exit 7" in out
    assert len((tmp_path / "calls").read_text().splitlines()) == n + 1
    assert not (tmp_path / "third.txt").exists()


def test_a_failed_call_is_retried_until_a_review_lands(tmp_path):
    n = len(delays())
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY, backoff=" ".join(["0"] * n), ask='ask_row() { echo x >> "$RUNNER_TEMP/calls"; [ "$(wc -l < "$RUNNER_TEMP/calls")" -gt 1 ] || return 7; cp "$H" "$RUNNER_TEMP/$2-headers.txt"; cp "$B" "$RUNNER_TEMP/$2-body.json"; }\n')
    assert "rc=0" in out and out.endswith("alibaba-qwen38max-judge")
    assert len((tmp_path / "calls").read_text().splitlines()) == 2
    assert (tmp_path / "third.txt").read_text() == "APPROVE"


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
    script = claude_calls() + '\nout=$(ask_claude opus "$IN" "$ERR"); echo "rc=$?"; echo "calls=$(wc -l < "$CALLS")"; echo "out=$out"\n'
    env = {"HOME": str(tmp_path), "REVIEW_BACKOFF": backoff, "IN": str(tmp_path / "in"), "CALLS": str(tmp_path / "calls"), "ERR": str(tmp_path / "err"), "PATH": f"{tmp_path}/bin:/usr/bin:/bin"}
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout


def test_an_empty_claude_answer_is_asked_again(tmp_path):
    out = claude_retry(tmp_path, answers=1, backoff="0 0")
    assert "rc=0" in out and "calls=2" in out and "APPROVE" in out


def test_a_claude_seat_that_never_answers_uses_every_delay(tmp_path):
    n = len(delays())
    out = claude_retry(tmp_path, answers=99, backoff=" ".join(["0"] * n))
    assert "rc=1" in out and f"calls={n + 1}" in out


def test_both_claude_reviews_are_asked_again():
    text = WF.read_text()
    assert "for d in 0 ${REVIEW_BACKOFF" in claude_calls()
    assert 'review=$(ask_claude "$first_model" "$RUNNER_TEMP/diff.txt" "$RUNNER_TEMP/first.err" "$RUNNER_TEMP/first.ans")' in text
    assert 'r2=$(ask_claude "$SECOND_MODEL" "$RUNNER_TEMP/extra-in.txt" "$RUNNER_TEMP/second.err" "$RUNNER_TEMP/second.ans")' in text


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
