"""The gh API call count per workflow and job, by which token identity pays (fleet-ops#11031).

Three budgets exist:

- the runner login (nish3451): 5,000 core requests/hour, shared with every other
  session on the two hosts, so a burst anywhere reddens every review run until
  the hour rolls over;
- the repository's Actions token (github.token): 1,000 core/hour per
  repository, shared by every job in every workflow of that repository;
- the worker App token: 5,000 core/hour per installation.

A `run:` line can hold several calls, so every command position counts. `gh
auth git-credential` is git authentication, not an API call, and is not
counted. A composite action under .github/actions runs inside the job that
`uses:` it, so its calls are counted into that job. ci.yml is not scanned: its
`gh` mentions are grep patterns and stub echoes inside its own tests, not API
calls.

The runner-login lane is pinned per job: that is the shared lane whose
exhaustion reddened already-approved review runs. A job that starts drawing
more on it must raise the pin here with a reason in docs/workflow-notes.md, or
put the call on the job token. The other two lanes are printed, not pinned.
"""

import re
from collections import Counter
from functools import lru_cache
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
ACTIONS = ROOT / ".github/actions"

# Command positions: the start of a shell command, after any of these separators.
SEPARATORS = re.compile(r"\$\(|&&|\|\||[|;&()]|\bthen\b|\bdo\b|\belse\b|\belif\b|\bif\b|\bwhile\b|\buntil\b|\bfi\b|\bdone\b|\besac\b")
# A gh REST call, with the wrappers the fleet writes in front of it. gh auth is
# git credential plumbing, not an API call.
CALL = re.compile(
    r"^(?:GH_TOKEN=\$\S+\s+)?(?:env\s+(?:-u\s+\S+\s+)+)?(?:xargs(?:\s+\S+)*\s+)?gh\s+"
    r"(api|pr|issue|repo|run|workflow|label|search|release|secret|variable|attestation|ruleset|project|codespace|gist|org|user|cache)\b"
)
RUNNER_LOGIN = re.compile(r"\benv\s+-u\s+GH_TOKEN")
INLINE_TOKEN = re.compile(r"\bGH_TOKEN=\$")
APP_TOKEN_DEFAULT = re.compile(r"steps\.|inputs\.|secrets\.")


def identity(line: str, default: str) -> str:
    if RUNNER_LOGIN.search(line):
        return "runner"
    if INLINE_TOKEN.search(line):
        return "app"
    return default


def default_identity(env: dict) -> str:
    token = str(env.get("GH_TOKEN", env.get("GITHUB_TOKEN", "")))
    if "github.token" in token:
        return "job"
    if APP_TOKEN_DEFAULT.search(token):
        return "app"
    return "runner"


def step_calls(run: str, default: str) -> Counter:
    counts: Counter = Counter()
    for line in run.splitlines():
        for segment in SEPARATORS.split(line):
            if CALL.match(segment.strip()):
                counts[identity(segment, default)] += 1
    return counts


def collect_run_blocks(steps: list, into: Counter) -> None:
    for step in steps:
        if "run" in step:
            into.update(step_calls(str(step["run"]), default_identity(step.get("env") or {})))


def local_action_name(uses: str) -> str | None:
    m = re.search(r"/\.github/actions/([\w-]+)@", str(uses))
    return m.group(1) if m else None


@lru_cache(maxsize=1)
def workflow_counts() -> dict:
    table: dict = {}
    for wf in sorted(p for p in WORKFLOWS.glob("*.yml") if p.name != "ci.yml"):
        doc = yaml.safe_load(wf.read_text())
        per_job = {}
        for job, spec in (doc.get("jobs") or {}).items():
            steps = (spec or {}).get("steps") or []
            counts: Counter = Counter()
            collect_run_blocks(steps, counts)
            for step in steps:
                action = local_action_name(step.get("uses", ""))
                if not action:
                    continue
                action_doc = yaml.safe_load((ACTIONS / action / "action.yml").read_text())
                collect_run_blocks(action_doc.get("runs", {}).get("steps") or [], counts)
            if counts:
                per_job[job] = dict(counts)
        if per_job:
            table[wf.name] = per_job
    return table


def format_table(table: dict) -> str:
    lines = ["workflow job                        runner  job  app"]
    for wf, jobs in table.items():
        lines.append(wf)
        for job, counts in jobs.items():
            lines.append(f"  {job:<30} {counts.get('runner', 0):>7}  {counts.get('job', 0):>3}  {counts.get('app', 0):>3}")
    totals: Counter = Counter()
    for jobs in table.values():
        for counts in jobs.values():
            totals.update(counts)
    lines.append(f"{'total':<34} {totals.get('runner', 0):>7}  {totals.get('job', 0):>3}  {totals.get('app', 0):>3}")
    return "\n".join(lines)


# Every gh-calling job, with its runner-login lane count as of 2026-10-30
# (fleet-ops#11031). Those calls draw on nish3451's 5,000/h, shared with every
# session on the two hosts; that exhaustion reddened approved review runs. A
# new gh-calling job belongs here too, with 0 when its calls are on the job or
# App token.
RUNNER_LANE_PIN = {
    ("agent.yml", "work"): 9,
    ("agent.yml", "review"): 0,
    ("agent.yml", "arm"): 0,
    ("agent.yml", "stuck"): 0,
    ("agent.yml", "inish-daily"): 0,
    ("agent-dispatch.yml", "list"): 2,
    ("agent-dispatch.yml", "orchestrate"): 7,
    ("agent-dispatch.yml", "stuck-prs"): 0,
    ("agent-dispatch.yml", "red-main"): 0,
    ("agent-dispatch.yml", "hold-risky"): 0,
    ("agent-dispatch.yml", "admit"): 0,
    ("agent-dispatch.yml", "close-claim"): 0,
    ("agent-dispatch.yml", "conflicts"): 0,
    ("agent-dispatch.yml", "rework-note"): 0,
    ("coordinator-approval.yml", "coordinator-approval"): 0,
}


def test_prints_the_count_per_workflow_job_and_identity():
    table = workflow_counts()
    print()
    print(format_table(table))
    seen = {(wf, job) for wf, jobs in table.items() for job in jobs}
    assert seen == set(RUNNER_LANE_PIN), (
        f"workflow/job set drifted: {seen ^ set(RUNNER_LANE_PIN)}. "
        "Add the gh-calling job to RUNNER_LANE_PIN, with 0 when its calls are on the job or App token."
    )


@pytest.mark.parametrize("workflow_job", sorted(RUNNER_LANE_PIN))
def test_the_runner_login_lane_is_pinned_per_job(workflow_job):
    counts = workflow_counts().get(workflow_job[0], {}).get(workflow_job[1], {})
    actual = counts.get("runner", 0)
    pin = RUNNER_LANE_PIN[workflow_job]
    assert actual <= pin, (
        f"{workflow_job[0]} job {workflow_job[1]} draws on the runner login for {actual} gh calls "
        f"(pin {pin}, fleet-ops#11031). That login's 5,000/h is shared with every session on the hosts, "
        "and its exhaustion reddened approved review runs. Put the call on the job token "
        "(GH_TOKEN: ${{ github.token }}), or raise the pin with a reason in docs/workflow-notes.md."
    )


def test_the_review_send_back_reads_the_job_token_not_the_runner_login():
    doc = yaml.safe_load((WORKFLOWS / "agent.yml").read_text())
    step = next(s for s in doc["jobs"]["review"]["steps"] if s.get("name") == "Send a blocked orch PR back to the orchestrator")
    assert "${{ github.token }}" in str(step["env"]["GH_TOKEN"])
