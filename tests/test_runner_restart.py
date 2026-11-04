"""A changed runner unit restarts the runner, but never while it runs a job (fleet-ops#11715).

The play's check runs here with systemctl and pgrep replaced by fixtures that answer from a temp
directory; stat, sort and test are the real ones. A restart cancels the running job
(actions/runner src/Misc/layoutbin/RunnerService.js sends SIGINT, then SIGKILL), and a job is the
Runner.Worker process the listener starts (src/Runner.Listener/JobDispatcher.cs).
"""
import os
import subprocess

import ansible_host

UNIT = "fleet-runner@1.service"
CGROUP = "/agent.slice/u"


def _tasks():
    return ansible_host.play()["tasks"]


def _check():
    return next(t for t in _tasks() if t.get("register") == "runner_stale")


def _stale(tmp_path, started, newest_file, busy, cgroup=CGROUP, pgrep_rc=None, missing=None):
    """rc of the play's check for one runner that started at `started`, whose `newest_file`
    was last written at 2000, that runs a job when `busy`, and whose cgroup systemd reports as
    `cgroup`. The pgrep fixture follows pgrep(1): 2 on a bad command line, 0 only when a
    Runner.Worker runs in the runner's own cgroup, else 1; `pgrep_rc` forces an exit status."""
    run = tmp_path / "run"
    run.mkdir()
    for name in ("unit.service", ".env", ".path"):
        (run / name).write_text("")
        os.utime(run / name, (1000, 1000))
    os.utime(run / newest_file, (2000, 2000))
    if missing:
        (run / missing).unlink()
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    props = {"ActiveEnterTimestamp": f"@{started}", "WorkingDirectory": str(run),
             "FragmentPath": str(run / "unit.service"), "ControlGroup": cgroup}
    cases = "".join(f'  *{k}*) echo "{v}";;\n' for k, v in props.items())
    (bin_ / "systemctl").write_text(f'#!/bin/sh\ncase "$*" in\n{cases}esac\n')
    pgrep = (f"exit {pgrep_rc}\n" if pgrep_rc is not None else
             '[ $# -eq 4 ] && [ "$1" = --cgroup ] && [ -n "$2" ] && [ "$3" = -x ] || exit 2\n'
             f'[ "$2" = "{CGROUP}" ] && [ "$4" = Runner.Worker ] && exit {0 if busy else 1}\n'
             "exit 1\n")
    (bin_ / "pgrep").write_text("#!/bin/sh\n" + pgrep)
    for f in bin_.iterdir():
        f.chmod(0o755)
    cmd = _check()["ansible.builtin.shell"]["cmd"].replace("{{ item }}", UNIT)
    env = {**os.environ, "PATH": f"{bin_}:{os.environ['PATH']}"}
    return subprocess.run(["/bin/bash", "-c", cmd], env=env, check=False, capture_output=True).returncode


def test_an_idle_runner_started_before_its_unit_changed_is_restarted(tmp_path):
    assert _stale(tmp_path, started=1500, newest_file="unit.service", busy=False) == 0


def test_an_env_or_path_change_counts_like_a_unit_change(tmp_path):
    assert _stale(tmp_path, started=1500, newest_file=".path", busy=False) == 0


def test_a_runner_that_runs_a_job_is_left_for_a_later_run(tmp_path):
    assert _stale(tmp_path, started=1500, newest_file="unit.service", busy=True) == 1


def test_a_runner_started_after_the_change_is_left_alone(tmp_path):
    assert _stale(tmp_path, started=2500, newest_file="unit.service", busy=False) == 1


def test_the_task_fails_on_any_status_but_restart_or_leave():
    assert _check()["failed_when"] == "runner_stale.rc not in [0, 1]"


def test_a_pgrep_error_fails_the_task_instead_of_restarting(tmp_path):
    for rc in (2, 3):
        (tmp_path / str(rc)).mkdir()
        assert _stale(tmp_path / str(rc), started=1500, newest_file="unit.service", busy=True,
                      pgrep_rc=rc) not in (0, 1)


def test_an_empty_cgroup_fails_the_task_instead_of_restarting(tmp_path):
    assert _stale(tmp_path, started=1500, newest_file="unit.service", busy=True, cgroup="") not in (0, 1)


def test_a_missing_runner_file_fails_the_task(tmp_path):
    assert _stale(tmp_path, started=1500, newest_file="unit.service", busy=False, missing=".env") not in (0, 1)


def test_the_check_covers_every_runner_and_only_its_hits_restart():
    check = _check()
    assert "fleet_runner_ids" in check["loop"] and "fleet-reviewer-runner.service" in check["loop"]
    restarts = [t for t in _tasks() if t.get("ansible.builtin.systemd_service", {}).get("state") == "restarted"
                and "runner" in t["ansible.builtin.systemd_service"]["name"] + str(t.get("loop", ""))]
    assert [t["loop"] for t in restarts] == [
        "{{ runner_stale.results | selectattr('changed') | map(attribute='item') | list }}"]
    handlers = ansible_host.play()["handlers"]
    assert not [h for h in handlers if "runner" in str(h.get("ansible.builtin.systemd_service", {}))]
