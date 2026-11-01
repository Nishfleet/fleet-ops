"""PR rot in agent-dispatch.yml is stock actions/stale and nothing custom.

A PR idle 6 days gets the Stale label, 7 idle days closes it, and the branch is
kept so a closed claim PR goes back through the list job's requeue path. Issues
are never touched by the step. #10666 grew a tested rot program and rules of its
own; the owner ruled that over-built, so this test fails if a custom rot rule
grows back beside the stock step.
"""
import pathlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"
STALE_V9_1_0 = "actions/stale@5bef64f19d7facfb25b37b414482c7164d639639"


def workflow():
    return yaml.safe_load(DISPATCH.read_text())


def stale_steps():
    return [
        step
        for job in workflow()["jobs"].values()
        for step in job.get("steps") or []
        if str(step.get("uses", "")).startswith("actions/stale@")
    ]


def test_the_over_built_rot_program_does_not_grow_back():
    assert not (ROOT / "review/pr_rot.py").exists()
    runs = [
        str(step.get("run", ""))
        for job in workflow()["jobs"].values()
        for step in job.get("steps") or []
    ]
    assert not [run for run in runs if "review/" in run]
