"""A push to main always reaches the deploy steps (fleet-ops#10046).

2026-10-22: two merges at 14:14Z (ebf1d4e7, dbee9335) never reached the deploy
clone, and dbee9335's deploy run 39796924650 shows why: `runner-probe` ran as the
deploy job's first step, so its failure marked both `systemctl` steps `skipped`.
These assertions read the workflow as YAML, so no job, step, condition or path
filter can sit between a push to main and the deploy again.
"""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-box.yml"


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
    for key in ("paths", "paths-ignore"):
        assert key not in push, (
            "a %s filter means a merge outside it starts no deploy, and the box "
            "reads prompts/, config/, systemd/ and rootfs/ from the clone" % key
        )
    assert "pull_request" not in on


def test_no_job_can_gate_the_deploy():
    jobs = _workflow()["jobs"]
    assert jobs["probe"].get("needs") is None
    assert jobs["apply"].get("needs") is None
    assert _workflow()["concurrency"] == {"group": "deploy-box", "cancel-in-progress": False}


def test_apply_runs_only_the_two_deploy_steps():
    steps = _workflow()["jobs"]["apply"]["steps"]
    deploy = [s for s in steps if "systemctl" in (s.get("run") or "")]
    assert len(deploy) == 2
    assert "systemctl --user start fleet-sync.service" in deploy[0]["run"]
    assert "systemctl start fleet-host-config.service" in deploy[1]["run"]
    for step in deploy:
        assert "uses" not in step
        assert "if" not in step
        assert "continue-on-error" not in step


def test_probe_is_its_own_job():
    probe = _workflow()["jobs"]["probe"]
    assert [s["uses"] for s in probe["steps"]] == [
        "Nishfleet/fleet-ops/.github/actions/runner-probe@main"
    ]
