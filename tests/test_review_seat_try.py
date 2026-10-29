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


def seat_try(tmp_path, headers, body, want="Qwen", used="Jev Claude"):
    (tmp_path / "h").write_text(headers)
    (tmp_path / "b").write_text(body)
    script = functions() + 'ask_row() { cp "$H" "$RUNNER_TEMP/$2-headers.txt"; cp "$B" "$RUNNER_TEMP/$2-body.json"; }\n' + f'seat_try judge third "{want}" "{used}"; echo "rc=$?"; cat "$RUNNER_TEMP/third-why" 2>/dev/null; cat "$RUNNER_TEMP/third-row" 2>/dev/null\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0", "H": str(tmp_path / "h"), "B": str(tmp_path / "b"), "PATH": "/usr/bin:/bin"}
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
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "alibaba-qwen38max-judge")
    out = seat_try(tmp_path, headers, OK_BODY, want="GLM", used="")
    assert "rc=1" in out and "(Qwen), not the GLM family" in out


def test_answer_cut_at_its_token_limit_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY.replace('"stop"', '"length"'))
    assert "rc=1" in out and "cut at its token limit or empty" in out


def test_empty_answer_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY.replace('"APPROVE"', '" \\n "'))
    assert "rc=1" in out and "cut at its token limit or empty" in out


def test_retries_run_out_on_a_failed_call(tmp_path):
    script = functions() + 'ask_row() { echo x >> "$RUNNER_TEMP/calls"; return 7; }\nseat_try senior second GLM ""; echo "rc=$?"; cat "$RUNNER_TEMP/second-why"\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0 0", "PATH": "/usr/bin:/bin"}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout
    assert "rc=1" in out and "curl exit 7" in out
    assert len((tmp_path / "calls").read_text().splitlines()) == 3
    assert not (tmp_path / "second.txt").exists()


def test_a_failed_call_is_retried_until_a_review_lands(tmp_path):
    (tmp_path / "h").write_text(OK_HEADERS)
    (tmp_path / "b").write_text(OK_BODY)
    script = functions() + 'ask_row() { echo x >> "$RUNNER_TEMP/calls"; [ "$(wc -l < "$RUNNER_TEMP/calls")" -gt 1 ] || return 7; cp "$H" "$RUNNER_TEMP/$2-headers.txt"; cp "$B" "$RUNNER_TEMP/$2-body.json"; }\nseat_try senior second GLM ""; echo "rc=$?"; cat "$RUNNER_TEMP/second-row"\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0 0", "H": str(tmp_path / "h"), "B": str(tmp_path / "b"), "PATH": "/usr/bin:/bin"}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout
    assert "rc=0" in out and out.endswith("synthetic-glm53flash-senior")
    assert len((tmp_path / "calls").read_text().splitlines()) == 2
    assert (tmp_path / "second.txt").read_text() == "APPROVE"
