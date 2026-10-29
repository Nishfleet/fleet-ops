"""The org ruleset requires this one workflow in every repo (fleet-ops#10554).

A break here is silent and org-wide: the rule is set in organization settings, so no repo's own
check fails when the shared workflow stops being callable.
"""

from pathlib import Path

import yaml

RATCHET = Path(__file__).resolve().parents[1] / ".github/workflows/ratchet.yml"
GITHUB_HOSTED = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04"}


def ratchet():
    doc = yaml.safe_load(RATCHET.read_text())
    return doc.get("on") or doc.get(True), doc["jobs"]


def test_another_repository_can_call_it():
    triggers, _ = ratchet()
    assert "workflow_call" in triggers


def test_the_required_call_needs_no_inputs():
    triggers, _ = ratchet()
    inputs = (triggers["workflow_call"] or {}).get("inputs") or {}
    for name, spec in inputs.items():
        assert "default" in spec, f"input {name} has no default, so a ruleset call fails"


def test_every_job_stays_named_and_hosted():
    _, jobs = ratchet()
    assert [job.get("name") for job in jobs.values()] == ["ratchet"]
    for job in jobs.values():
        assert job["runs-on"] in GITHUB_HOSTED, "repos without fleet runners would queue forever"
