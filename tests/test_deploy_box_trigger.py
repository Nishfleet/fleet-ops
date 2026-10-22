"""A push to main always reaches the deploy steps (fleet-ops#10046).

2026-10-22: two merges at 14:14Z (ebf1d4e7, dbee9335) never reached the deploy
clone for 40 min, and their deploy runs 39796797875 and 39796924650 show why:
`runner-probe` ran as the deploy job's first step, so its failure marked both
`systemctl` steps `skipped`. These assertions read the workflow as YAML, so no path
filter, `needs`, `if`, `environment` or `continue-on-error` can sit between a push
to main and the deploy, and nothing runs before the two deploy steps.
"""

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-box.yml"
PROBE = "Nishfleet/fleet-ops/.github/actions/runner-probe@main"
YQ = shutil.which("yq")


def _yq(*args):
    assert YQ, "yq (mikefarah's Go build) must be on PATH to read the workflow"
    return subprocess.run(
        [YQ, *args, str(WORKFLOW)], check=True, capture_output=True, text=True
    ).stdout


def _workflow():
    flavour = subprocess.run(
        [YQ, "--version"], check=True, capture_output=True, text=True
    ).stdout
    assert "mikefarah" in flavour, (
        "these assertions parse with mikefarah's yq: -o=json, and `on` kept as a key. "
        "python-yq is a different tool and answers a different document: %r"
        % flavour.strip()
    )
    workflow = json.loads(_yq("-o=json", "."))
    assert {"on", "jobs", "concurrency"} <= set(workflow), (
        "the workflow did not parse to the expected keys, so the gate below would "
        "be read from the wrong document (a YAML 1.1 loader turns `on` into True): %s"
        % sorted(workflow)
    )
    return workflow


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


def test_the_two_deploy_steps_are_first_and_run_unconditionally():
    steps = _workflow()["jobs"]["apply"]["steps"]
    deploy = [s for s in steps if "systemctl" in (s.get("run") or "")]
    assert len(deploy) == 2
    assert "systemctl --user start fleet-sync.service" in deploy[0]["run"]
    assert "systemctl start fleet-host-config.service" in deploy[1]["run"]
    assert steps[:2] == deploy, (
        "the deploy steps come first, so no earlier step's failure can skip them: "
        "that is how run 39796797875 lost its deploy"
    )
    for step in deploy:
        for key in ("uses", "if", "continue-on-error", "env", "shell", "working-directory"):
            assert key not in step, step


def test_the_probe_runs_last_in_the_deploying_job():
    steps = _workflow()["jobs"]["apply"]["steps"]
    probe = [s for s in steps if s.get("uses") == PROBE]
    assert len(probe) == 1, steps
    assert steps[-1] == probe[0], "the probe is last, after both deploy steps"
    assert "if" not in probe[0] and "continue-on-error" not in probe[0], (
        "a red probe must fail the run, and it must not be able to skip the steps above it"
    )
