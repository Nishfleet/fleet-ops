"""A push to main always reaches the deploy steps (fleet-ops#10046).

2026-10-22: two merges at 14:14Z (ebf1d4e7, dbee9335) never reached the deploy
clone for 40 min, and their deploy runs 39796797875 and 39796924650 show why:
`runner-probe` ran as the deploy job's first step, so its failure marked both
`systemctl` steps `skipped`. These assertions read the workflow as YAML, so no path
filter, `needs`, `if`, `environment` or `continue-on-error` can sit between a push
to main and the deploy again.
"""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-box.yml"
PROBE = "Nishfleet/fleet-ops/.github/actions/runner-probe@main"


def _workflow():
    return json.loads(
        subprocess.run(
            ["yq", "-o=json", ".", str(WORKFLOW)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )


def test_every_path_on_main_triggers_the_deploy():
    on = _workflow()["on"]
    push = on["push"]
    assert push["branches"] == ["main"]
    for key in ("paths", "paths-ignore", "tags", "tags-ignore", "types"):
        assert key not in push, (
            "a %s filter means a merge outside it starts no deploy, and the box "
            "reads prompts/, config/, systemd/ and rootfs/ from the clone" % key
        )
    assert "pull_request" not in on
    assert "schedule" not in on


def test_nothing_gates_the_deploy():
    workflow = _workflow()
    assert list(workflow["jobs"]) == ["apply"]
    apply = workflow["jobs"]["apply"]
    assert apply.get("needs") is None
    assert apply.get("if") is None
    assert apply.get("environment") is None
    assert apply.get("continue-on-error") is None
    assert workflow["concurrency"] == {"group": "deploy-box", "cancel-in-progress": False}


def test_the_two_deploy_steps_run_unconditionally():
    steps = _workflow()["jobs"]["apply"]["steps"]
    deploy = [s for s in steps if "systemctl" in (s.get("run") or "")]
    assert len(deploy) == 2
    assert "systemctl --user start fleet-sync.service" in deploy[0]["run"]
    assert "systemctl start fleet-host-config.service" in deploy[1]["run"]
    for step in deploy:
        assert "uses" not in step
        assert "if" not in step
        assert "continue-on-error" not in step


def test_the_probe_runs_on_the_deploying_box_and_cannot_skip_the_deploy():
    steps = _workflow()["jobs"]["apply"]["steps"]
    probe = [s for s in steps if s.get("uses") == PROBE]
    assert len(probe) == 1, steps
    assert probe[0]["continue-on-error"] is True
    assert probe[0].get("if") is None
    assert steps.index(probe[0]) < steps.index(
        next(s for s in steps if "fleet-sync.service" in (s.get("run") or ""))
    )
    verdict = steps[-1]
    assert verdict.get("if") == "always()", "the verdict must run even after a failed step"
    assert verdict["env"]["PROBE_OUTCOME"] == "${{ steps.probe.outcome }}"
    assert "PROBE_OUTCOME" in verdict["run"]
    assert "${{" not in verdict["run"], "step outputs reach the shell through env, never as a template"
