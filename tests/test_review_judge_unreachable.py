"""fleet-ops#9800: an unreachable router is "could not be judged", not a dead review job.

The review step's judge call ran under `set -e`, so a curl exit 7 (the router was
down on #9798) ended the step after the first review and posted nothing. Here the
real judge lines of the review step run against a stub curl: a failed call must
post the could-not-be-judge comment and exit 0, and a healthy answer must still
reach the verdict.
"""
import pathlib
import subprocess

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github" / "workflows" / "agent.yml"
SHA = "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345"
CURL_STUB = """#!/usr/bin/env bash
[ -z "${CURL_BODY:-}" ] || printf '%s' "$CURL_BODY"
exit "${CURL_EXIT:-0}"
"""


def judge_lines():
    """The judge call, its could-not-be-judged guard and the verdict read, as the review step writes them."""
    jobs = yaml.safe_load(AGENT.read_text())["jobs"]
    run = next(s["run"] for j in jobs.values() for s in j.get("steps", []) if s.get("id") == "review")
    lines = run.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(("jev_rc=0", "resp=$(curl")))
    end = next(i for i, line in enumerate(lines) if line.startswith("choice=$(jq"))
    assert start < end, "the judge call must come before the verdict read"
    return "\n".join(lines[start:end + 1])


def judge(tmp_path, curl_exit, curl_body=""):
    stub = tmp_path / "bin"
    stub.mkdir()
    (stub / "curl").write_text(CURL_STUB)
    (stub / "curl").chmod(0o755)
    (tmp_path / "home").mkdir()
    posted = tmp_path / "posted"
    script = 'say() { printf "%s\\n" "$1" >> "$POSTED"; }\n' + judge_lines() + '\nprintf "choice=%s\\n" "$choice"\n'
    env = {
        "PATH": f"{stub}:/usr/bin:/bin",
        "HOME": str(tmp_path / "home"),
        "RUNNER_TEMP": str(tmp_path),
        "POSTED": str(posted),
        "CURL_EXIT": str(curl_exit),
        "CURL_BODY": curl_body,
        "SHA": SHA,
        "REPO": "Nishfleet/fleet-ops",
        "PR": "7",
        "review": "No blockers.\nAPPROVE",
        "body": "{}",
    }
    r = subprocess.run(["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script], env=env, capture_output=True, text=True)
    return r, posted.read_text() if posted.exists() else ""


def test_unreachable_router_posts_the_could_not_be_judged_comment(tmp_path):
    r, posted = judge(tmp_path, 7)
    assert r.returncode == 0, r.stderr
    assert "could not be judged" in posted
    assert "curl exit 7" in posted


def test_healthy_verdict_still_reaches_the_decision(tmp_path):
    r, posted = judge(tmp_path, 0, '{"answers":{"verdict":{"choice":"approve","probabilities":{"approve":0.95}}}}')
    assert r.returncode == 0, r.stderr
    assert posted == ""
    assert "choice=approve" in r.stdout
