"""The approver bot's token and verdict stay out of the worker lane's reach (decisions ledger 2026-11-04).

The bot token reaches only a GitHub-hosted job in environment `approver`, and the Grok review runs
only in runner group `reviewer`, never on a runner the worker lane shares.
https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
"""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def jobs():
    for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
        for name, job in (yaml.safe_load(wf.read_text()).get("jobs") or {}).items():
            yield wf.name, name, job


def hosted(job) -> bool:
    return isinstance(job.get("runs-on"), str) and job["runs-on"].startswith("ubuntu-")


def test_no_self_hosted_job_reads_a_secret():
    leaks = [(wf, name) for wf, name, job in jobs() if not hosted(job) and "secrets." in yaml.safe_dump(job)]
    assert leaks == []


def test_the_bot_token_comes_only_from_environment_approver():
    readers = [(wf, name, job.get("environment")) for wf, name, job in jobs() if "APPROVER_TOKEN" in yaml.safe_dump(job)]
    assert readers == [("review.yml", "verdict", "approver")]


def test_the_review_runs_only_in_runner_group_reviewer():
    review = yaml.safe_load((ROOT / ".github/workflows/review.yml").read_text())["jobs"]["review"]
    assert review["runs-on"] == {"group": "reviewer", "labels": ["self-hosted", "reviewer"]}


def test_the_merge_bar_is_owner_reviewed():
    assert "/docs/review-bar.md @nish3451" in (ROOT / ".github/CODEOWNERS").read_text().splitlines()
