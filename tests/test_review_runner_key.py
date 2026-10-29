"""Review runners run as fleet-reviewer and take the reviewer App key from the credential store (fleet-ops#10950).

Runners 9 and 10 are the only units the review job and the arm job run on, so they are the
only units that may hold the reviewer App key. It arrives by bare name, which systemd reads
from /etc/credstore (root-owned 0600): a source path would be a readable copy under a home
directory, and a second unit that loaded it would be a second identity that can post an
approval (fleet-ops#9521). nish's home is mode 0700, so a bind of a 0600 file under it hands
the review user a path it cannot open, and every credential is loaded instead.
"""

from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
UNITS = ROOT / "rootfs/etc/systemd/system"
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
REVIEW_KEY = "nishfleet-reviewer.private-key.pem"
WORKER_KEY = "nishfleet-worker.private-key.pem"
SEATS = "${CREDENTIALS_DIRECTORY:-$HOME/.config/fleet-ops/seats}"
REVIEW_USERS = {
    "actions.runner.Nishfleet.netcup-agent-9.service.d/30-review-user.conf",
    "actions.runner.Nishfleet.netcup-agent-10.service.d/30-review-user.conf",
}


def values(text: str, key: str) -> list[str]:
    """Every `key=value` line of a drop-in, in file order (comments skipped)."""
    return [l.strip().removeprefix(key + "=") for l in text.splitlines() if l.strip().startswith(key + "=")]


def review_dropins() -> dict[Path, str]:
    """The drop-ins that set `User=fleet-reviewer`, by path."""
    found = {}
    for conf in sorted(UNITS.glob("actions.runner.*.service.d/*.conf")):
        if "fleet-reviewer" in values(conf.read_text(), "User"):
            found[conf] = conf.read_text()
    return found


def test_only_the_review_runners_run_as_the_review_user() -> None:
    found = review_dropins()
    assert {str(p.relative_to(UNITS)) for p in found} == REVIEW_USERS


@pytest.mark.parametrize("name", sorted(REVIEW_USERS))
def test_the_review_runners_take_the_reviewer_key_by_bare_name(name: str) -> None:
    text = (UNITS / name).read_text()
    loaded = [v for v in values(text, "LoadCredential") if v.split(":")[0] == REVIEW_KEY]
    assert loaded == [REVIEW_KEY], (
        "the reviewer App key must be loaded by bare name from /etc/credstore, with no source path: " + repr(loaded)
    )


@pytest.mark.parametrize("name", sorted(REVIEW_USERS))
def test_the_review_runners_take_the_worker_key_and_the_router_key(name: str) -> None:
    text = (UNITS / name).read_text()
    loaded = values(text, "LoadCredential")
    assert f"{WORKER_KEY}:/home/nish/.config/fleet-worker/{WORKER_KEY}" in loaded, (
        "the arm job mints its App token from the worker key, and this uid has no copy under HOME"
    )
    assert "typesafe-jev.env:/home/nish/.config/fleet-ops/seats/typesafe-jev.env" in loaded, (
        "the review job reads the router key by path, so it arrives as a credential"
    )
    assert "CLAUDE_CONFIG_DIR=/var/lib/fleet-reviewer/.claude" in values(text, "Environment")
    assert values(text, "EnvironmentFile") == ["/home/nish/.config/fleet-ops/seats/claude-seat-b.env"], (
        "the review job runs claude on the default login (seat b); the token file is that seat's"
    )


@pytest.mark.parametrize("name", sorted(REVIEW_USERS))
def test_the_review_runners_never_get_nish_gh_login(name: str) -> None:
    bound = [v for k in ("BindPaths", "BindReadOnlyPaths") for v in values((UNITS / name).read_text(), k)]
    assert [v for v in bound if "/.config/gh" in v] == [], "a review runner that reads nish's gh login is the bug this issue removes"


def test_no_other_unit_names_the_reviewer_key() -> None:
    """A second unit that loaded the key would be a second identity that can post an approval."""
    named = {str(p.relative_to(UNITS)) for p in sorted(UNITS.rglob("*")) if p.is_file() and REVIEW_KEY in p.read_text()}
    assert named == REVIEW_USERS


def test_no_unit_binds_the_credential_store() -> None:
    """A bind of /etc/credstore or /run/credentials would put the reviewer key back in reach of a job."""
    bad = []
    for conf in sorted(UNITS.rglob("*.conf")):
        for key in ("BindPaths", "BindReadOnlyPaths", "TemporaryFileSystem", "InaccessiblePaths"):
            for value in values(conf.read_text(), key):
                for token in value.split():
                    path = token.lstrip("-+").split(":")[0]
                    if path in ("/etc/credstore", "/run/credentials") or path.startswith(("/etc/credstore/", "/run/credentials/")):
                        bad.append(f"{conf.relative_to(ROOT)}: {key}={token}")
    assert bad == []


def review_jobs() -> list[tuple[str, str, str]]:
    """(workflow, job id, the job's step scripts) for every job that runs on the review runners."""
    found = []
    for workflow in WORKFLOWS:
        jobs = yaml.safe_load(workflow.read_text()).get("jobs") or {}
        for job_id, job in jobs.items():
            runs_on = job.get("runs-on")
            labels = runs_on if isinstance(runs_on, list) else [runs_on or ""]
            if "review" not in labels:
                continue
            steps = "\n".join(str(step.get("run", "")) for step in job.get("steps") or [])
            found.append((workflow.name, job_id, steps))
    return found


def job_text(job: dict) -> str:
    """Every string a job's steps can read the reviewer key from: run text, env values and a step's with:."""
    parts = []
    for step in job.get("steps") or []:
        parts.append(str(step.get("run", "")))
        parts += [f"{k}={v}" for k, v in (step.get("env") or {}).items()]
        parts += [f"{k}={v}" for k, v in (step.get("with") or {}).items() if isinstance(v, str)]
    return "\n".join(parts + [f"{k}={v}" for k, v in (job.get("env") or {}).items()])


def test_the_review_jobs_read_the_router_key_from_the_credential_first() -> None:
    """These jobs run as fleet-reviewer, whose HOME holds no seat file, so the credential is the only copy."""
    jobs = review_jobs()
    assert {job_id for _, job_id, _ in jobs} >= {"review", "arm"}, "the review runners' jobs were not found"
    reads = 0
    for workflow, job_id, steps in jobs:
        for line in (l.strip() for l in steps.splitlines() if "typesafe-jev.env" in l):
            reads += 1
            assert f"{SEATS}/typesafe-jev.env" in line, f"{workflow}:{job_id}: " + line
    assert reads, "no review-runner job reads the router key"


def reads_reviewer_key(text: str) -> bool:
    """A line that names the key next to the credential store reads it; a name in a grep or a comment does not."""
    return any(
        REVIEW_KEY in line and ("CREDENTIALS_DIRECTORY" in line or "/etc/credstore" in line)
        for line in text.splitlines()
    )


def test_no_worker_can_read_the_reviewer_key_or_the_owner_login() -> None:
    """A worker that read the reviewer key could approve its own PR (fleet-ops#9521).

    The key posts the approval line APPROVERS counts, so it may be in reach of no job a PR can reach: only the
    review job reads it, only agent.yml asks for the review runners, and agent.yml declares no pull_request or
    push trigger, so a branch's own copy of it never runs. The runners' org group lists agent.yml@main alone,
    which is what keeps a workflow a PR adds off those two units. The owner login half lives in
    tests/test_no_runner_gh_login.py, and the credential store's own units and binds are held above."""
    readers = []
    for workflow in WORKFLOWS:
        jobs = yaml.safe_load(workflow.read_text()).get("jobs") or {}
        for job_id, job in jobs.items():
            if not reads_reviewer_key(job_text(job)):
                continue
            labels = job.get("runs-on")
            labels = labels if isinstance(labels, list) else [labels or ""]
            readers.append((workflow.name, job_id, labels))
            assert any("review" in label for label in labels), (
                f"{workflow.name}:{job_id} reads the reviewer App key off the review runners"
            )
    assert readers == [("agent.yml", "review", ["self-hosted", "review"])], readers
    assert {name for name, _, _ in review_jobs()} == {"agent.yml"}, "a job off agent.yml asks for the review runners"
    on = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())[True]
    assert not on.keys() & {"pull_request", "pull_request_target", "push"}, (
        "agent.yml runs on a branch event, so a PR's own copy of it could read the key: " + str(sorted(on.keys()))
    )


def test_the_review_job_posts_the_approval_as_the_reviewer_app() -> None:
    """The approval line is only worth the identity behind it (fleet-ops#9521)."""
    name, steps = {job_id: (n, s) for n, job_id, s in review_jobs()}["review"]
    text = job_text(yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())["jobs"]["review"])
    assert REVIEW_KEY in text, f"{name}: the review job does not read the reviewer App key"
    assert "GH_TOKEN=$REVIEWER_TOKEN gh pr comment" in steps, f"{name}: the approval comment is not posted as the reviewer App"
    # The login the approval goes out as is the login APPROVERS counts, or nothing counts it.
    approvers = yaml.safe_load((ROOT / ".github/workflows/agent-dispatch.yml").read_text())["env"]["APPROVERS"].split()
    login = next(v for k, v in (line.split("=", 1) for line in text.splitlines() if line.startswith("REVIEWER_LOGIN=")))
    assert login in approvers, f"{name}: {login} is not in APPROVERS {approvers}"
