"""Review runners run as fleet-reviewer and take the reviewer App key from the credential store (fleet-ops#10950).

Runners 9 to 12 run as fleet-reviewer, and no other unit may hold the reviewer App key: which
runner answers a job is a GitHub label this repo cannot read, and runners 20 to 30 keep
`review` too, so the check here is the set of units that hold the key, not the set a job lands
on. It arrives by bare name, which systemd reads
from /etc/credstore (root-owned 0600): a source path would be a readable copy under a home
directory, and a second unit that loaded it would be a second identity that can post an
approval (fleet-ops#9521). nish's home is mode 0700, so a bind of a 0600 file under it hands
the review user a path it cannot open, and every credential is loaded instead.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml
from jinja2 import Environment

ROOT = Path(__file__).resolve().parents[1]
UNITS = ROOT / "rootfs/etc/systemd/system"
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
REVIEW_KEY = "nishfleet-reviewer.private-key.pem"
WORKER_KEY = "nishfleet-worker.private-key.pem"
SEATS = "${CREDENTIALS_DIRECTORY:-$HOME/.config/fleet-ops/seats}"
LABEL_READ = "Read the labels GitHub holds for the two new review runners"
LABEL_HOLD = "Hold the two new review runner drop-ins back until both are review-only"
NEW_RUNNERS = ["netcup-agent-11", "netcup-agent-12"]
REVIEW_USERS = {
    "actions.runner.Nishfleet.netcup-agent-9.service.d/30-review-user.conf",
    "actions.runner.Nishfleet.netcup-agent-10.service.d/30-review-user.conf",
    "actions.runner.Nishfleet.netcup-agent-11.service.d/30-review-user.conf",
    "actions.runner.Nishfleet.netcup-agent-12.service.d/30-review-user.conf",
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


def test_the_review_dropins_differ_only_in_their_runner_number() -> None:
    """Each new drop-in is a copy, so a line that is not its own runner number is drift."""

    def own_number(name: str) -> str:
        return name.split("netcup-agent-")[1].split(".")[0]

    for name in sorted(REVIEW_USERS):
        text = (UNITS / name).read_text()
        assert text.count(f"/var/lib/fleet-reviewer/{own_number(name)}") >= 2, (
            "the drop-in must name its own runner directory in WorkingDirectory= and ExecStart=: " + name
        )
    shapes = {(UNITS / name).read_text().replace(f"/var/lib/fleet-reviewer/{own_number(name)}", "/N") for name in REVIEW_USERS}
    assert len(shapes) == 1, "the four review drop-ins differ in something other than their runner number"


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
    assert {job_id for _, job_id, _ in jobs} >= {"review"}, "the review runners' jobs were not found"  # arm left them (#11056)
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
    job = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())["jobs"]["review"]
    text = job_text(job)
    assert REVIEW_KEY in text, f"{name}: the review job does not read the reviewer App key"
    ids = [s.get("id") for s in job["steps"]]
    assert ids.index("review") < ids.index("reviewer-token"), f"{name}: the reviewer App token is minted before the review, so it can expire mid-review"
    mint = next(s for s in job["steps"] if s.get("id") == "reviewer-token")
    assert mint["if"] == "steps.review.outputs.approved_sha != ''", f"{name}: the reviewer App token is minted with no approval to post"
    assert mint["with"]["app-id"] == "5526765", f"{name}: the token is not the review-only App's"
    post = next(s for s in job["steps"] if s.get("name") == "Post the approval as the reviewer App")
    assert post["if"] == "steps.review.outputs.approved_sha != ''", f"{name}: the approval comment posts with no approval to post"
    assert post["env"]["GH_TOKEN"] == "${{ steps.reviewer-token.outputs.token }}", f"{name}: the approval comment does not post with the reviewer App token"
    assert 'gh api -X POST "repos/$REPO/issues/$PR/comments"' in post["run"], f"{name}: the approval comment does not go through the issues endpoint (the App carries issues:write only)"
    assert all(s.get("name") != "Park the reviewer App token in a private file" for s in job["steps"]), f"{name}: a reviewer App token is still parked where a step env or a file could leak it"
    reviewstep = next(s for s in job["steps"] if s.get("id") == "review")
    assert "REVIEWER_TOKEN" not in (reviewstep.get("env") or {}), f"{name}: the review step inherits the reviewer App token"
    assert 'review_jail="bwrap --dev-bind / / --tmpfs $RUNNER_TEMP/_runner_file_commands' in steps, f"{name}: the minted key lands in the runner file commands, so the reviewers must run jailed from it"
    # The login the approval goes out as is the login APPROVERS counts, or nothing counts it.
    approvers = yaml.safe_load((ROOT / ".github/workflows/agent-dispatch.yml").read_text())["env"]["APPROVERS"].split()
    login = next((v for k, v in (line.split("=", 1) for line in text.splitlines() if line.startswith("REVIEWER_LOGIN="))), "")
    assert login in approvers, f"{name}: {login!r} is not in APPROVERS {approvers}"


def install_config() -> list[dict]:
    """The tasks that install host config, in play order."""
    return [t for t in yaml.safe_load((ROOT / "ansible/tasks/install-config.yml").read_text()) if isinstance(t, dict)]


def guard_tasks() -> dict[str, dict]:
    """The two tasks that hold the new review drop-ins back until GitHub labels their runners."""
    tasks = {t["name"]: t for t in install_config() if t.get("name") in (LABEL_READ, LABEL_HOLD)}
    assert set(tasks) == {LABEL_READ, LABEL_HOLD}, "the review runner label guard is missing: " + ", ".join(sorted(tasks))
    names = [t["name"] for t in install_config()]
    assert len(names) == len(set(names)), "yaml keeps the last task of a repeated name, so a guard task could be shadowed"
    return tasks


def test_the_label_read_is_the_org_runner_list_read_as_nish() -> None:
    """GitHub routes a job by label, so the labels are the check, and they live at GitHub, not in this repo."""
    task = guard_tasks()[LABEL_READ]
    argv = task["ansible.builtin.command"]["argv"]
    assert argv[:3] == ["gh", "api", "orgs/Nishfleet/actions/runners"], argv
    assert "--paginate" in argv, "the box holds more runners than one page, so an unpaged read misses a runner"
    assert task["become"] is True and task["become_user"] == "nish", "the read runs as the login the box's other GitHub reads use"
    assert task["environment"] == "{{ nish_env }}"
    assert task["ignore_errors"] is True, "a read that cannot run must hold the drop-in back, not fail the deploy"
    assert task["until"] == "new_review_runner_labels.rc == 0", "one API blip must not hold a rollout back for a whole deploy cycle"
    assert task["retries"] == 3 and task["delay"] == 20, "the count in update.yml retries this same endpoint for the same reason"
    names = [t.get("name") for t in install_config()]
    assert names.index("Install systemd units, slices and drop-ins") < names.index(LABEL_READ) < names.index(LABEL_HOLD)


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq is not installed, so the filter cannot run")
def test_the_label_filter_names_a_runner_once_it_takes_only_review_jobs() -> None:
    """The filter decides the rollout, so it runs for real against the shape GitHub answers with."""
    jq = shutil.which("jq")
    assert jq is not None
    argv = guard_tasks()[LABEL_READ]["ansible.builtin.command"]["argv"]
    filt = argv[argv.index("--jq") + 1]

    def runners(*named: tuple[str, list[str]]) -> dict:
        return {"runners": [{"name": name, "labels": [{"name": label} for label in labels]} for name, labels in named]}

    def answer(payload: dict) -> list[str]:
        done = subprocess.run([jq, "-r", filt], input=json.dumps(payload), capture_output=True, text=True, check=True)
        return done.stdout.split()

    review_only = ["self-hosted", "review"]
    worker = ["self-hosted", "agent", "fleet-ops"]
    assert answer(runners(("netcup-agent-9", worker), *[(name, review_only) for name in NEW_RUNNERS])) == NEW_RUNNERS
    for kept in ("agent", "fleet-ops"):
        named = [(name, review_only) for name in NEW_RUNNERS]
        named[0] = (NEW_RUNNERS[0], review_only + [kept])
        assert answer(runners(*named)) == [NEW_RUNNERS[1]], f"{kept} still routes worker jobs to a runner that holds the reviewer key"
    assert answer(runners((NEW_RUNNERS[0], review_only))) == [NEW_RUNNERS[0]], "a runner GitHub does not list is not named, so the when cannot see both"
    assert answer(runners(*[(name, ["self-hosted"]) for name in NEW_RUNNERS])) == [], "no review label, no review job"


def test_a_dropin_stays_held_until_the_labels_say_the_runner_is_review_only() -> None:
    """The when decides the rollout, so it runs for real against what the read can answer."""
    when = guard_tasks()[LABEL_HOLD]["when"]

    def holds(read: dict) -> bool:
        return Environment().from_string("{{ (" + when + ") }}").render(new_review_runner_labels=read) == "True"

    both = {"rc": 0, "stdout_lines": NEW_RUNNERS}
    assert holds(both) is False, "both runners take only review jobs, so the drop-in must install"
    assert holds({"rc": 0, "stdout_lines": list(reversed(NEW_RUNNERS))}) is False, "page order is not a fact about the labels"
    for partial in ([], NEW_RUNNERS[:1], [NEW_RUNNERS[0], "netcup-agent-9"]):
        assert holds({"rc": 0, "stdout_lines": partial}) is True, f"one unlabelled runner still takes worker jobs: {partial}"
    assert holds({"rc": 1, "stdout_lines": NEW_RUNNERS}) is True, "a read that failed is not a read that says yes"
    assert holds({"rc": 1}) is True, "a read with no output at all still holds"


def test_the_hold_takes_back_only_the_two_new_review_dropins() -> None:
    task = guard_tasks()[LABEL_HOLD]
    assert task["ansible.builtin.file"]["state"] == "absent"
    assert task["loop"] == [11, 12], "runners 9 and 10 have been review-only since they were labelled"
    assert task["ansible.builtin.file"]["path"] == "/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-{{ item }}.service.d/30-review-user.conf", "a path that names no runner number can hold any runner's drop-in back"
    notify = task["notify"] if isinstance(task["notify"], list) else [task["notify"]]
    assert "Reload systemd" in notify, "systemd forgets a drop-in only on a daemon-reload, and the copy reports ok once the file is on the box"
    assert "Start the runner sandbox apply" in notify, "a held drop-in reaches a running runner only when the sandbox apply restarts it (fleet-ops#11248)"
