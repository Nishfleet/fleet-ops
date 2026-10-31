"""The runner probe measures the sandbox the running runner actually applied.

A drop-in reaches a runner only at its next start, and the deploy restarts no
runner (fleet-ops#10898), so the loaded unit config can name a path the running
process never hid. A probe that read that config failed every job on the runner
for as long as the window lasted: six runner-probe and fourteen review-risky
failures in the week to 2026-10-29 (fleet-ops#11072, #11016). The probe reads
the job's own mount namespace instead: the /systemd/inaccessible/* over-mounts
in /proc/self/mountinfo are the paths the running sandbox actually hides, the
same read-back update.yml runs against a runner it restarted (fleet-ops#10866).
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github/actions/runner-probe/action.yml"


def probe_step() -> str:
    action = yaml.safe_load(ACTION.read_text())
    return action["runs"]["steps"][0]["run"]


def test_the_hidden_list_comes_from_the_job_mount_namespace() -> None:
    step = probe_step()
    assert "/proc/self/mountinfo" in step
    assert "/systemd/inaccessible/" in step


def test_the_probe_reads_no_loaded_unit_config() -> None:
    assert "systemctl show" not in probe_step()


def test_the_probe_still_guards_the_runner_unit_and_fails_closed() -> None:
    step = probe_step()
    assert "/proc/self/cgroup" in step
    assert "::error::this job is not in an actions.runner unit" in step
    assert "::error::$p is readable from this job" in step
    assert 'test "$bad" -eq 0' in step


def test_the_summary_line_and_the_no_path_branch_stay() -> None:
    step = probe_step()
    assert "checked=$n readable=$bad" in step
    assert "hides no paths" in step
