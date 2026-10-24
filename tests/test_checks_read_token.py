import json
import os
import pathlib
import re
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows"
AGENT = WF / "agent.yml"
DISPATCH = WF / "agent-dispatch.yml"
LEVEL = {"none": 0, "read": 1, "write": 2}
RUN_TOKEN = "${{ github.token }}"
CHECK_READ = re.compile(r"gh pr checks|statusCheckRollup|/check-runs|/check-suites|/statuses|/status\b")
APP, RUN = "app-token-value", "run-token-value"

FAKE_GH = r"""#!/usr/bin/env bash
echo "$*|token=${GH_TOKEN-unset}" >> "$FAKE_DIR/calls.log"
case "$1 $2" in
  "pr checks")
    [ "${GH_TOKEN-}" = "$RUN_TOKEN" ] || { echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)" >&2; exit 1; }
    jq=; while [ $# -gt 0 ]; do [ "$1" = --jq ] && jq=$2; shift; done
    if [ -n "$jq" ]; then jq -r "$jq" "$FAKE_DIR/checks.json"; else cat "$FAKE_DIR/checks.json"; fi ;;
  "pr view")
    case "$*" in
      *"--json state"*) echo OPEN ;;
      *"--json body"*) echo "Closes #7" ;;
      *"--json number,mergeable"*) echo '{"number":29,"mergeable":"MERGEABLE"}' ;;
      *"--json number"*) echo 29 ;;
      *"--json changedFiles"*) echo 1 ;;
      *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
    esac ;;
  "pr list") echo OPEN ;;
  "pr merge") echo "$*" >> "$FAKE_DIR/merges.log" ;;
  "api repos/Nishfleet/tether/issues/7") echo '{"state":"open","labels":[{"name":"agent-in-progress"}]}' ;;
  "api --paginate") echo docs/readme.md ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def yq(expr, path):
    return subprocess.run(["yq", "-o=json", expr, str(path)], check=True, capture_output=True, text=True).stdout


def load(path):
    return json.loads(yq(".", path))


def step(job, name):
    steps = load(AGENT)["jobs"][job]["steps"]
    return next(s for s in steps if s.get("name") == name)


def iter_steps():
    for path in (AGENT, DISPATCH):
        for jname, job in load(path)["jobs"].items():
            for s in job.get("steps", []):
                if "run" in s:
                    yield path.name, jname, job, s


def gh_lines(run):
    return [ln for ln in run.splitlines() if "gh " in ln and CHECK_READ.search(ln)]


def test_the_workflows_do_read_checks():
    assert sum(len(gh_lines(s["run"])) for _, _, _, s in iter_steps()) >= 8


@pytest.mark.parametrize("fname,jname,job,s", [t for t in iter_steps() if gh_lines(t[3]["run"])], ids=lambda v: v if isinstance(v, str) else "")
def test_no_check_read_uses_the_human_login(fname, jname, job, s):
    lines = gh_lines(s["run"])
    env = {**job.get("env", {}), **s.get("env", {})}
    perms = job.get("permissions", {})
    assert perms.get("statuses") == "read", (fname, jname)
    if any(not re.search(r"/statuses", ln) for ln in lines):
        assert perms.get("checks") == "read", (fname, jname)
    for ln in lines:
        assert "env -u" not in ln, ln
        if re.search(r'GH_TOKEN="?\$WF_TOKEN"? gh ', ln):
            assert env.get("WF_TOKEN") == RUN_TOKEN, ln
        else:
            assert env.get("GH_TOKEN") == RUN_TOKEN, ln
            assert "GH_TOKEN=" not in ln, ln


def test_every_agent_yml_caller_grants_what_agent_yml_asks():
    asked = {}
    for job in load(AGENT)["jobs"].values():
        for k, v in job.get("permissions", {}).items():
            asked[k] = max(asked.get(k, "none"), v, key=LEVEL.get)
    assert asked["checks"] == "read" and asked["statuses"] == "read"
    callers = {n: j for n, j in load(DISPATCH)["jobs"].items() if str(j.get("uses", "")).endswith("/agent.yml@main")}
    assert len(callers) >= 13
    for name, job in callers.items():
        granted = job.get("permissions", {})
        for k, v in asked.items():
            assert LEVEL[granted.get(k, "none")] >= LEVEL[v], (name, k)


def run_step(tmp_path, s, extra_env, checks, name):
    d = tmp_path / name
    d.mkdir()
    (d / "bin").mkdir()
    gh = d / "bin/gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (d / "checks.json").write_text(json.dumps(checks))
    (d / "script.sh").write_text(s["run"])
    env = {
        "PATH": f"{d / 'bin'}:{os.environ['PATH']}", "HOME": str(d), "FAKE_DIR": str(d),
        "RUN_TOKEN": RUN, "REPO": "Nishfleet/tether", "REF": "claim/issue-7-x",
        "GITHUB_SERVER_URL": "https://github.com", "GITHUB_OUTPUT": str(d / "out"),
        "GH_TOKEN": APP, "WF_TOKEN": RUN, "MISS": "", "ISSUE_N": "7", **extra_env,
    }
    r = subprocess.run(["bash", "-e", str(d / "script.sh")], capture_output=True, text=True, env=env)
    calls = (d / "calls.log").read_text() if (d / "calls.log").exists() else ""
    merges = (d / "merges.log").read_text() if (d / "merges.log").exists() else ""
    return r, calls, merges


GREEN = [{"name": "ci", "bucket": "pass"}]
RED = [{"name": "ci", "bucket": "fail"}]


@pytest.mark.parametrize("checks,rc", [(GREEN, 0), (RED, 1)], ids=["green", "red"])
def test_deliverable_reads_checks_with_the_run_token(tmp_path, checks, rc):
    r, calls, _ = run_step(tmp_path, step("work", "Deliverable"), {}, checks, "deliverable")
    assert r.returncode == rc, r.stdout + r.stderr
    assert "could not read checks" not in r.stderr + r.stdout
    assert f"token={RUN}" in calls and f"pr checks 29|token={APP}" not in calls


@pytest.mark.parametrize("checks,rc,merged", [(GREEN, 0, True), (RED, 1, False)], ids=["green", "red"])
def test_arm_reads_checks_with_the_run_token(tmp_path, checks, rc, merged):
    r, calls, merges = run_step(tmp_path, step("work", "Arm auto-merge as the App"), {}, checks, "arm")
    assert r.returncode == rc, r.stdout + r.stderr
    assert "unreadable" not in r.stdout + r.stderr
    check_calls = [c for c in calls.splitlines() if c.startswith("pr checks")]
    assert check_calls and all(c.endswith(f"token={RUN}") for c in check_calls)
    assert ("--auto --squash" in merges) is merged
    assert all(f"token={APP}" in c for c in calls.splitlines() if c.startswith("pr merge"))
