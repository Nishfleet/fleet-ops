"""Every workflow_run job in agent-dispatch.yml acts only on claim/issue-* heads, so the trigger
filters on that branch glob and a CI run on main never starts a run that skips."""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"


def test_workflow_run_trigger_filters_claim_branches():
    on = yaml.safe_load(DISPATCH.read_text())[True]
    assert on["workflow_run"] == {"workflows": ["CI"], "types": ["completed"], "branches": ["claim/issue-*"]}
