import re
import subprocess
from pathlib import Path

import yaml

WF = Path(__file__).parents[1] / ".github/workflows/agent.yml"

OK_HEADERS = "HTTP/1.1 200 OK\r\nx-litellm-call-id: 7c943b89\r\nx-litellm-model-id: synthetic-glm53flash-senior\r\nx-litellm-model-name: openai/hf:zai-org/GLM-5.3-Flash\r\n\r\n"
OK_BODY = '{"id":"x","model":"senior","object":"chat.completion","choices":[{"finish_reason":"stop","index":0,"message":{"content":"APPROVE","role":"assistant"}}]}'
ERR_HEADERS = "HTTP/1.1 429 Too Many Requests\r\ncontent-type: application/json\r\n\r\n"
ERR_BODY = '{"error":{"message":"Too many concurrent requests","type":"None","param":"None","code":"429"}}'


def functions():
    run = next(s["run"] for j in yaml.safe_load(WF.read_text())["jobs"].values() for s in j.get("steps", []) if s.get("id") == "review")
    return run[run.index("family_of() {"):run.index("# After every retry")]


def seat_try(tmp_path, headers, body, want="GLM", used="Jev"):
    (tmp_path / "h").write_text(headers)
    (tmp_path / "b").write_text(body)
    script = functions() + 'ask_row() { cp "$H" "$RUNNER_TEMP/$2-headers.txt"; cp "$B" "$RUNNER_TEMP/$2-body.json"; }\n' + f'seat_try senior second "{want}" "{used}"; echo "rc=$?"; cat "$RUNNER_TEMP/second-why" 2>/dev/null; cat "$RUNNER_TEMP/second-row" 2>/dev/null\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0", "H": str(tmp_path / "h"), "B": str(tmp_path / "b"), "PATH": "/usr/bin:/bin"}
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout


def test_row_id_header_names_the_family(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY)
    assert "rc=0" in out and out.endswith("synthetic-glm53flash-senior")


def test_router_error_is_named_not_just_an_empty_row_id(tmp_path):
    out = seat_try(tmp_path, ERR_HEADERS, ERR_BODY)
    assert "rc=1" in out and "no row id, the router said: Too many concurrent requests" in out


def test_family_that_already_reviewed_is_refused(tmp_path):
    out = seat_try(tmp_path, OK_HEADERS, OK_BODY, want="", used="Jev GLM")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_fallback_is_asked_through_the_assistant_seat_not_the_judge_seat():
    text = WF.read_text()
    assert 'seat_try assistant "$r" "" "$used"' in text
    assert 'seat_try "$THIRD_SEAT" "$r" "" "$used"' not in text


def test_assistant_row_is_a_new_family_after_glm_and_qwen_reviewed(tmp_path):
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "opencodego-ds41flash-assistant")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev GLM Qwen")
    assert "rc=0" in out and out.endswith("opencodego-ds41flash-assistant")


def test_judge_row_is_refused_once_qwen_reviewed(tmp_path):
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "alibaba-qwen38max-judge")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev Qwen")
    assert "rc=1" in out and "a family that already reviewed this head" in out


def test_reviewer_request_disables_router_fallbacks():
    ask = next(l for l in WF.read_text().splitlines() if "{model: $m, stream: false" in l)
    assert "disable_fallbacks: true" in ask


def test_row_from_no_known_family_is_refused(tmp_path):
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "acme-model1-assistant")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev GLM Qwen")
    assert "rc=1" in out and "no known non-Claude family" in out


def test_stepfun_row_is_a_new_family(tmp_path):
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "stepfun-step5preview-worker-capable")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev GLM Qwen")
    assert "rc=0" in out and out.endswith("stepfun-step5preview-worker-capable")


def test_stepfun_row_is_refused_once_stepfun_reviewed(tmp_path):
    headers = OK_HEADERS.replace("synthetic-glm53flash-senior", "stepfun-step5preview-worker-capable")
    out = seat_try(tmp_path, headers, OK_BODY, want="", used="Jev GLM StepFun")
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
    # Every call fails: one first try and one per REVIEW_BACKOFF delay, then exit 1 with the reason and no review.
    script = functions() + 'ask_row() { echo x >> "$RUNNER_TEMP/calls"; return 7; }\nseat_try senior second GLM ""; echo "rc=$?"; cat "$RUNNER_TEMP/second-why"\n'
    env = {"RUNNER_TEMP": str(tmp_path), "REVIEW_BACKOFF": "0 0", "PATH": "/usr/bin:/bin"}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).stdout
    assert "rc=1" in out and "curl exit 7" in out
    assert len((tmp_path / "calls").read_text().split()) == 3
    assert not (tmp_path / "second.txt").exists()
