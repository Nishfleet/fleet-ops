"""The runner sandbox apply unit (fleet-ops#11248): a runner unit whose drop-in was
installed while it was running keeps the mount namespace it started with, so the
change reaches it only at its next start. The unit restarts the idle runners whose
drop-in is newer than their start, one pass, on the handler's start after a deploy
and on the timer every 5 min, which catches a runner that was busy then.

These tests run the unit's real ExecStart against stub systemctl and ps, with real stat and real date
reading the real drop-in files the test writes into a tmp DROPIN_ROOT. What they pin:
which runner restarts, which runner is busy, the name boundary between agent-1 and
agent-13, the restart-failure exit, the skip of a unit without a start timestamp, a
plan's template dir reaching its units, and the wiring: the handler after Reload
systemd, the notify on each drop-in copy task, and the 5-min timer with its enable.
"""
import datetime
import os
import pathlib
import shlex
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-runner-sandbox-apply.service"
TIMER = ROOT / "rootfs/etc/systemd/system/fleet-runner-sandbox-apply.timer"
HOST = (ROOT / "ansible/host.yml").read_text()
SERVICES = (ROOT / "ansible/tasks/services.yml").read_text()
INSTALL = (ROOT / "ansible/tasks/install-config.yml").read_text()

WILDCARD = "actions.runner.Nishfleet.netcup-agent-.service.d"

SYSTEMCTL = """#!/bin/sh
echo "$@" >> "$SC/systemctl.log"
if [ "$1" = list-units ]; then cat "$SC/list"; exit 0; fi
if [ "$1" = show ]; then
  u=$5
  [ -f "$SC/start.$u" ] || { echo "n/a"; exit 0; }  # $1 show $2 -p $3 ... $4 --value $5 <unit>
  cat "$SC/start.$u"
  exit 0
fi
if [ "$1" = restart ]; then
  [ -n "$FAIL_RESTART" ] && exit 1
  echo "$2" >> "$SC/restarts.log"
  exit 0
fi
exit 0
"""

PS = """#!/bin/sh
cat "$SC/cgroups"
exit 0
"""


def _stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch).strftime("%a %Y-%m-%d %H:%M:%S")


@pytest.fixture
def box(tmp_path):
    """The stub bin dir, the stub state dir ($SC), a DROPIN_ROOT with the agent
    wildcard dir, and the environment to run the unit's ExecStart with. The test
    adds the units, drop-ins, active list and Runner.Worker cgroups it wants."""
    sc = tmp_path / "sc"
    sc.mkdir()
    root = tmp_path / "systemd"
    (root / WILDCARD).mkdir(parents=True)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "systemctl").write_text(SYSTEMCTL)
    (bindir / "ps").write_text(PS)
    for p in ("systemctl", "ps"):
        (bindir / p).chmod(0o755)
    (sc / "cgroups").write_text("")
    (sc / "list").write_text("")
    env = dict(
        os.environ,
        SC=str(sc),
        SYSTEMCTL=str(bindir / "systemctl"),
        PS=str(bindir / "ps"),
        STAT="/usr/bin/stat",
        DATE="/usr/bin/date",
        DROPIN_ROOT=str(root),
        FLOCK=str(tmp_path / "flock.lock"),
        LC_ALL="C",
        FAIL_RESTART="",
    )
    return sc, root, env


def _dropin(root, name, mtime, dir_=WILDCARD):
    d = root / dir_
    d.mkdir(parents=True, exist_ok=True)
    f = d / name
    f.write_text(f"# {name}\n")
    os.utime(f, (mtime, mtime))
    return f


def _agent(sc, name, start_epoch):
    u = f"actions.runner.Nishfleet.netcup-{name}.service"
    (sc / f"start.{u}").write_text(_stamp(start_epoch) + "\n")
    return u


def _run(env):
    cmd = _exec_start()
    assert cmd[0] == "/usr/bin/flock"
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=120)


def _exec_start():
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$").replace("%%", "%"))


def test_a_stale_idle_agent_restarts_at_the_apply_pass(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now)               # deployed now
    u = _agent(sc, "agent-2", now - 6000)                # started before it, idle
    (sc / "list").write_text(u + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert (sc / "restarts.log").read_text() == u + "\n"
    assert f"{u} restarts (drop-in" in run.stdout
    assert "checked 1 restarted 1 busy-wait 0" in run.stdout


def test_a_stale_busy_agent_is_not_restarted_and_waits(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now)
    u = _agent(sc, "agent-9", now - 6000)
    (sc / "list").write_text(u + "\n")
    (sc / "cgroups").write_text(f"0::/agent.slice/{u}/job\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert not (sc / "restarts.log").exists()
    assert f"{u} busy, restarts when its job ends" in run.stdout
    assert "busy-wait 1" in run.stdout


def test_an_agent_that_started_after_the_drop_in_is_left_alone(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now - 6000)
    u = _agent(sc, "agent-2", now - 60)                  # restarted after the deploy
    (sc / "list").write_text(u + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert not (sc / "restarts.log").exists()
    assert "checked 1 restarted 0 busy-wait 0" in run.stdout


def test_agent_1_and_agent_13_do_not_share_a_name_boundary(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now)
    one = _agent(sc, "agent-1", now - 6000)
    third = _agent(sc, "agent-13", now - 6000)
    (sc / "list").write_text(one + "\n" + third + "\n")
    (sc / "cgroups").write_text(f"0::/agent.slice/{third}\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert (sc / "restarts.log").read_text() == one + "\n"
    assert f"{third} busy, restarts when its job ends" in run.stdout


def test_a_review_runner_matches_its_own_dir_and_the_wildcard_one(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now - 100)         # shared dir, older
    _dropin(root, "30-review-user.conf", now,
            dir_="actions.runner.Nishfleet.netcup-agent-11.service.d")
    u = _agent(sc, "agent-11", now - 6000)
    (sc / "list").write_text(u + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert (sc / "restarts.log").read_text() == u + "\n"


def test_a_plan_wildcard_drop_in_makes_its_plan_units_stale_but_others_not(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now,
            dir_="actions.runner.nish3451-nish-vault.netcup-vault-.service.d")
    vault = "actions.runner.nish3451-nish-vault.netcup-vault-1.service"
    (sc / f"start.{vault}").write_text(_stamp(now - 6000) + "\n")
    (sc / "list").write_text(vault + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert (sc / "restarts.log").read_text() == vault + "\n"


def test_a_unit_outside_a_plan_wildcard_dir_does_not_go_stale(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now,
            dir_="actions.runner.Nishfleet.netcup-agent-.service.d")
    u = "actions.runner.nish3451-nish-vault.netcup-vault-1.service"
    (sc / f"start.{u}").write_text(_stamp(now - 6000) + "\n")
    (sc / "list").write_text(u + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert not (sc / "restarts.log").exists()
    assert "restarted 0" in run.stdout


def test_a_failed_restart_fails_the_apply_pass(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now)
    u = _agent(sc, "agent-2", now - 6000)
    (sc / "list").write_text(u + "\n")
    env["FAIL_RESTART"] = "1"
    run = _run(env)
    assert run.returncode != 0
    assert f"restarting {u} failed" in run.stdout


def test_a_unit_without_a_start_timestamp_is_skipped(box):
    sc, root, env = box
    now = time.time()
    _dropin(root, "20-lockdown.conf", now)
    u = "actions.runner.Nishfleet.netcup-agent-3.service"
    (sc / "list").write_text(u + "\n")
    run = _run(env)
    assert run.returncode == 0, run.stderr
    assert not (sc / "restarts.log").exists()
    assert "restarted 0" in run.stdout


def test_the_unit_locks_a_second_start_out_and_exits_zero():
    exec_line = [ln for ln in UNIT.read_text().replace("\\\n", "").splitlines()
                 if ln.startswith("ExecStart=")][0]
    assert "flock -n -E 0" in exec_line
    assert "RuntimeDirectory=fleet-runner-sandbox-apply" in UNIT.read_text()


def test_the_timer_runs_the_apply_unit_every_5min():
    text = TIMER.read_text()
    timer = text[text.index("[Timer]"):text.index("[Install]")]
    assert "OnUnitActiveSec=5min" in timer and "OnBootSec=5min" in timer
    assert "Persistent=" not in timer


def test_services_yml_enables_and_starts_the_timer():
    block = SERVICES[SERVICES.index("Enable the runner sandbox apply timer"):]
    assert "fleet-runner-sandbox-apply.timer" in block
    assert "enabled: true" in block and "state: started" in block


def test_host_handlers_start_the_apply_after_the_reload():
    reload_at = HOST.index("name: Reload systemd")
    apply_at = HOST.index("name: Start the runner sandbox apply")
    # The hermes restart moved to tasks/services.yml (fleet-ops#10267), so the
    # next host.yml handler after the apply is the ssh one.
    ssh_at = HOST.index("name: Restart ssh.socket")
    assert reload_at < apply_at < ssh_at
    handler = HOST[apply_at:ssh_at]
    assert "fleet-runner-sandbox-apply.service" in handler and "started" in handler
    assert "Restart hermes units" not in handler, "a handler can flush before services.yml mints and proves the login (review of PR #11116)"


def test_every_drop_in_copy_task_notifies_the_apply():
    for task in ("Install the agent runner sandbox",
                 "Hold the two new review runner drop-ins back until both are review-only",
                 "Install systemd units, slices and drop-ins"):
        i = INSTALL.index(f"- name: {task}")
        end = INSTALL.find("- name:", i + 6)
        if end == -1:
            end = len(INSTALL)
        block = INSTALL[i:end]
        assert "Start the runner sandbox apply" in block, task
