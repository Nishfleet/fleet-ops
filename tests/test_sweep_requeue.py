"""Parked hand-offs (fleet-ops#10420) live in control-plane/src/sweep.ts and are tested by vitest.
This file pins the one string shared across two files: the sweep counts ended hand-offs by the
prefix that the orchestrate job posts, so editing either alone leaves every hand-off uncounted.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]


def test_requeue_counts_the_prefix_the_orchestrate_job_posts():
    src = (ROOT / "control-plane/src/sweep.ts").read_text()
    counted = re.search(r'const ENDED = "([^"]+)"', src)
    assert counted, "sweep.ts no longer defines the ENDED prefix"
    wf = (ROOT / ".github/workflows/agent-dispatch.yml").read_text()
    posted = re.findall(r'gh issue comment "\$ISSUE" -R "\$REPO" --body "([^"$]*)\$', wf)
    assert counted.group(1) in posted, (counted.group(1), posted)
