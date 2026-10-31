"""fleet-ops#9800: an unreachable router is "could not be judged", not a dead review job.

The review step's judge call ran under `set -e`, so a curl exit 7 (the router was
down on #9798) ended the step after the first review and posted nothing. Here the
real judge lines of the review step run against a stub curl: a failed call must
post the could-not-be-judged comment, naming the curl exit, and exit 0, and a
healthy answer must still reach the verdict.
"""
import pathlib
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github" / "workflows" / "agent.yml"
SHA = "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345"
CURL_STUB = """#!/usr/bin/env bash
last="${!#}"
if [ "${CURL_CAPTURE:-}" ]; then printf '%s' "$last" > "$CURL_CAPTURE"; fi
if [ -z "$last" ]; then exit "${CURL_EMPTY_BODY_EXIT:-28}"; fi
[ -z "${CURL_BODY:-}" ] || printf '%s' "$CURL_BODY"
exit "${CURL_EXIT:-0}"
"""


def judge_lines():
    """The judge call, its could-not-be-judged guard and the verdict read, as the review step writes them."""
    jobs = yaml.safe_load(AGENT.read_text())["jobs"]
    run = next(s["run"] for j in jobs.values() for s in j.get("steps", []) if s.get("id") == "review")
    lines = run.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("item=$review")), None)
    if start is None:
        start = next(i for i, line in enumerate(lines) if line.startswith("body=$(jq"))
    end = next(i for i, line in enumerate(lines) if line.startswith("choice=$(jq"))
    assert start < end, "the judge call must come before the verdict read"
    return "\n".join(lines[start:end + 1])


def judge(tmp_path, curl_exit, curl_body="", review="No blockers.\nAPPROVE", capture=False):
    stub = tmp_path / "bin"
    stub.mkdir()
    (stub / "curl").write_text(CURL_STUB)
    (stub / "curl").chmod(0o755)
    (tmp_path / "home").mkdir()
    posted = tmp_path / "posted"
    review_file = tmp_path / "review.txt"
    review_file.write_text(review)
    review_pre = 'review=$(cat "$REVIEW_FILE")\n'
    script = 'say() { printf "%s\\n" "$1" >> "$POSTED"; }\n' + review_pre + judge_lines() + '\nprintf "choice=%s\\n" "$choice"\n'
    script_env = {
        "REVIEW_FILE": str(review_file),
        "PATH": f"{stub}:/usr/bin:/bin",
        "CURL_CAPTURE": str(tmp_path / "captured-body") if capture else "",
        "HOME": str(tmp_path / "home"),
        "RUNNER_TEMP": str(tmp_path),
        "POSTED": str(posted),
        "CURL_EXIT": str(curl_exit),
        "CURL_BODY": curl_body,
        "SHA": SHA,
        "REPO": "Nishfleet/fleet-ops",
        "PR": "7",
        "body": "{}",
    }
    r = subprocess.run(["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script], env=script_env, capture_output=True, text=True)
    return r, posted.read_text() if posted.exists() else ""


@pytest.mark.parametrize("curl_exit", [7, 28])
def test_unreachable_router_posts_the_could_not_be_judged_comment(tmp_path, curl_exit):
    r, posted = judge(tmp_path, curl_exit)
    assert r.returncode == 0, r.stderr
    assert "could not be judged" in posted
    assert f"curl exit {curl_exit}" in posted


def test_healthy_verdict_still_reaches_the_decision(tmp_path):
    r, posted = judge(tmp_path, 0, '{"answers":{"verdict":{"choice":"approve","probabilities":{"approve":0.95}}}}')
    assert r.returncode == 0, r.stderr
    assert posted == ""
    assert "choice=approve" in r.stdout


def test_oversized_review_reaches_a_verdict(tmp_path):
    """The judge caps its item (the gateway's max_tokens_exceeded sits near 140 KB of item), so a huge review reaches the judge truncated and still draws a verdict."""
    r, posted = judge(tmp_path, 0, '{"answers":{"verdict":{"choice":"approve","probabilities":{"approve":0.95}}}}', review="x" * 400000, capture=True)
    assert r.returncode == 0, r.stderr
    assert posted == ""
    assert "choice=approve" in r.stdout
    body = (tmp_path / "captured-body").read_text()
    assert len(body) < 131072, "the judge item must stay under the execve per-string limit"
    assert "truncated here" in body
