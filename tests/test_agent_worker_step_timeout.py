"""The Worker step carries its own deadline under the job's 90-minute limit (fleet-ops#12065).

Stuck builder runs used the whole job: 43824107505 was cancelled at 77 minutes on a
whole-disk grep, 43829700947 failed at 78, 43824061004 timed out at 91 (park's own
comment: a job past timeout-minutes ends `cancelled`, and failure() is false for it),
and the 2026-11-12 #11923 runs died at ~45 minutes — all ending in "Terminate orphan
process: pid (pi)" with the job's limit as the only deadline. No vendor setting below
the step bounds a stuck worker (see the step's comment in agent.yml for the measured
vendor facts), so the step carries the stock GitHub deadline itself. 60 minutes keeps
the step's other work (clone, merge, bundle) inside the 90-minute job with room for
the park job, and every stuck run now ends with the deadline in the job log instead of
a silent burn.
https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobstimeminutes
"""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WF = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())


def test_worker_step_has_a_deadline_under_the_job_limit():
    job = WF["jobs"]["work"]
    step = next(s for s in job["steps"] if s.get("name") == "Worker")
    assert step["timeout-minutes"] == 60
    assert step["timeout-minutes"] < job["timeout-minutes"] == 90
