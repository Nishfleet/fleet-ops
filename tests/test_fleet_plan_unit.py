"""The host-config plan gate (fleet-ops#10931).

One approved head, one unit, one polkit grant, one ci job: the apply play runs
with ansible-pull --check --diff on the box, and the predicted changes are a PR
comment. These tests pin the three parts together, so none can drift: the unit
(rootfs/etc/systemd/system/fleet-plan@.service) must run the play in check and
diff mode with the instance sha, the polkit rule must let user nish start only a
40-hex instance with the start verb, and ci.yml's host-plan job must gate the
merge queue on it. Its facts about ansible (check mode skips modules without
check-mode support; the play's forced tasks are read-only probes) live in the
unit's header comment and host.yml's own comments, not here.
"""

import json
import shutil
import pathlib
import re
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-plan@.service"
RULE = ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-plan.rules"
CI = ROOT / ".github/workflows/ci.yml"


def _exec_start():
    m = re.search(r"^ExecStart=(.+)$", UNIT.read_text(), re.M)
    assert m
    return m.group(1)


def test_the_plan_is_the_apply_play_in_check_and_diff_mode():
    start = _exec_start()
    assert "/usr/bin/ansible-pull" in start
    assert " ansible/host.yml" in start
    for flag in ("--check", "--diff", "--verify-commit", "--clean"):
        assert re.search(rf"(?<![-a-z]){flag}(?![a-z-])", start), flag


def test_the_checked_head_is_the_instance_sha():
    assert "--checkout %i" in _exec_start()


def test_the_pull_anonymously_from_the_named_head():
    assert "https://github.com/Nishfleet/fleet-ops.git" in _exec_start()


def test_the_plan_log_is_the_run_log_of_that_head_alone():
    text = UNIT.read_text()
    assert "Type=oneshot" in text
    assert "StandardOutput=append:/var/lib/fleet-plan/plan-%i.log" in text
    assert "ExecStartPre=/usr/bin/truncate -s 0 /var/lib/fleet-plan/plan-%i.log" in text
    assert "plan-*.log" in text and "-delete" in text, "old heads' logs age out"


def test_a_plan_failure_is_not_paged_and_not_retried():
    text = UNIT.read_text()
    assert not re.search(r"^OnFailure=", text, re.M), "the plan is CI's failure path, not a box state"
    assert not re.search(r"^Restart=", text, re.M)


def test_neither_the_unit_nor_the_rule_is_a_repo_root_systemd_file():
    assert not (ROOT / "systemd/fleet-plan@.service").exists()


_CASES = [
    ["fleet-plan@" + "a" * 40 + ".service", "start", "nish", "YES"],
    ["fleet-plan@" + "a" * 40 + ".service", "restart", "nish", None],
    ["fleet-plan@" + "a" * 40 + ".service", "start", "root", None],
    ["fleet-plan@" + "f" * 39 + "1.service", "start", "nish", "YES"],
    ["fleet-plan@" + "g" * 40 + ".service", "start", "nish", None],
    ["fleet-plan@short-hex.service", "start", "nish", None],
    ["fleet-plan@" + "a" * 40, "start", "nish", None],
    ["fleet-host-config.service", "start", "nish", None],
]

_HARNESS = """
const fs = require('fs');
let rule;
const polkit = { addRule(fn) { rule = fn; }, Result: { YES: 'YES' } };
eval(fs.readFileSync(process.argv[2], 'utf8'));
const cases = CASES_PLACEHOLDER;
const out = cases.map(function (c) {
  const action = {
    id: 'org.freedesktop.systemd1.manage-units',
    lookup: function (k) { return k === 'unit' ? c[0] : c[1]; },
  };
  return ((rule(action, { user: c[2] }) ?? null)) === c[3];
});
process.stdout.write(JSON.stringify(out));
"""


def test_polkit_lets_nish_start_only_named_40hex_plan_instances(tmp_path):
    assert shutil.which("node"), "the polkit rule is JS, node runs it"
    script = tmp_path / "harness.js"
    script.write_text(_HARNESS.replace("CASES_PLACEHOLDER", json.dumps(_CASES)))
    run = subprocess.run(
        ["node", str(script), str(RULE)],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    assert json.loads(run.stdout) == [True] * len(_CASES), json.dumps(_CASES)


def test_the_rule_grants_one_action_one_verb_one_user():
    text = RULE.read_text()
    assert 'action.id == "org.freedesktop.systemd1.manage-units"' in text
    assert 'verb") == "start"' in text
    assert 'subject.user == "nish"' in text


def test_ci_gates_the_queue_on_the_plan_job():
    ci = yaml.safe_load(CI.read_text())
    jobs = ci["jobs"]
    assert "host-plan" in jobs["ci"]["needs"]
    job = jobs["host-plan"]
    assert job["if"] == "github.event_name == 'merge_group'"
    assert job["runs-on"] == ["self-hosted", "fleet-ci"]
    assert job["permissions"]["pull-requests"] == "write"
    assert job["permissions"]["contents"] == "read"
    env = job["env"]
    assert env["HEAD_SHA"] == "${{ github.event.merge_group.head_sha }}"
    assert env["GH_TOKEN"] == "${{ github.token }}"


def test_the_ci_step_starts_the_unit_for_the_paths_the_unit_plans():
    ci = yaml.safe_load(CI.read_text())
    run = ci["jobs"]["host-plan"]["steps"][0]["run"]
    assert 'systemctl start "fleet-plan@$HEAD_SHA.service"' in run
    for prefix in ("ansible/", "rootfs/", "systemd/", "containers/"):
        assert prefix in run
    gate = [l for l in run.splitlines() if "test -f" in l][0]
    assert "/etc/systemd/system/fleet-plan@.service" in gate
    assert "exit 0" in gate, "the bootstrap gate lets the first post-merge merge through"


def test_the_ci_step_checks_the_requested_head_is_a_40hex_sha():
    ci = yaml.safe_load(CI.read_text())
    run = ci["jobs"]["host-plan"]["steps"][0]["run"]
    assert '[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]' in run


def test_the_ci_step_comments_the_plan_back_to_the_entry():
    ci = yaml.safe_load(CI.read_text())
    run = ci["jobs"]["host-plan"]["steps"][0]["run"]
    assert "issues/$pr/comments" in run
    assert 'tail -c 48000 "/var/lib/fleet-plan/plan-$HEAD_SHA.log"' in run, \
        "the comment tail reads the run's own instance log, not a shared file"
    assert 'exit "$rc"' in run, "the unit's exit code gates the merge queue"
