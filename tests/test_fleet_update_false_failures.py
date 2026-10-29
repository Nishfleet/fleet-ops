"""The daily update fails only when a check really failed: the npm check ignores a long-lived `npm exec`, a running npm is recorded instead of aborting the run, the router is given time before the smoke call, every failed unit fails the run with nothing tolerated, and a git pin off its repo's default branch is named instead of waved through."""
import json
import os
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)
if not shutil.which("jq"):
    pytest.skip("jq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]
BLOCK = next(t for t in PLAY["tasks"] if "block" in t and "always" in t)
INNER = {t["name"]: t for t in BLOCK["block"]}
NAMES = [t["name"] for t in BLOCK["block"]]
ASSERT = next(t for t in BLOCK["always"] if t["name"] == "Fail loudly if any step or check went wrong")["ansible.builtin.assert"]
ALWAYS = {t["name"]: t for t in BLOCK["always"]}
ALWAYS_NAMES = [t["name"] for t in BLOCK["always"]]
THAT = " ".join(ASSERT["that"])
FAIL_MSG = ASSERT["fail_msg"]
NPM_CHECK = INNER["Check that no npm install or update runs as nish before its staging dirs go"]
PATTERN = NPM_CHECK["ansible.builtin.command"]["argv"][-1]
WAIT = "Wait for the model router to answer before the smoke call"
SMOKE = "Call pi for real, so a broken extension fails here"
GIT_PIN_CHECK = "Check every git extension pin is on its repo's default branch"
PI_SETTINGS = "${HOME}/.pi/agent/settings.json"
ON_MAIN = "git:github.com/Nishfleet/pi-runner-guard@" + "a" * 40
BEHIND_MAIN = "git:github.com/Nishfleet/pi-runner-guard@" + "b" * 40
OFF_MAIN = "git:github.com/Nishfleet/pi-runner-guard@" + "c" * 40
AHEAD_OF_MAIN = "git:github.com/Nishfleet/pi-runner-guard@" + "d" * 40
UNANSWERED = "git:github.com/Nishfleet/pi-runner-guard@" + "e" * 40
ANSWERS = {"aaaa": "identical", "bbbb": "behind", "cccc": "diverged", "dddd": "ahead"}


def run_git_pin_check(tmp_path, packages, answers=ANSWERS):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"packages": packages}), encoding="utf-8")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    gh = bindir / "gh"
    table = "".join(f"  {prefix}*) echo {status} ;;\n" for prefix, status in answers.items())
    gh.write_text(
        "#!/bin/bash\n"
        'sha="${2##*...}"\n'
        'case "$sha" in\n'
        f"{table}"
        "  *) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    gh.chmod(0o755)
    for package in packages:
        if isinstance(package, str) and package.startswith("git:github.com/"):
            prefix = package.rsplit("@", 1)[1][:4]
            assert prefix in answers or prefix == UNANSWERED.rsplit("@", 1)[1][:4], package
    cmd = INNER[GIT_PIN_CHECK]["ansible.builtin.shell"]["cmd"].replace(PI_SETTINGS, str(settings))
    assert str(settings) in cmd
    return subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}"},
    )


def matches(cmdline):
    return subprocess.run(["grep", "-qE", PATTERN], input=cmdline + "\n", text=True).returncode == 0


def test_both_npm_leftovers_are_found_for_removal():
    find = INNER["Find stale npm staging dirs a stopped self-update left behind"]["ansible.builtin.find"]
    assert find["patterns"] == [".*-stage-*", ".*-old-*"]
    assert find["hidden"] is True


def test_a_long_lived_npm_exec_is_not_install_activity():
    assert not matches("npm exec @modelcontextprotocol/server-filesystem /srv/notes")


def test_a_real_npm_install_or_update_still_stops_the_removal():
    for cmdline in ("npm install -g @openai/codex", "npm update --global", "npm ci",
                    "/usr/bin/npm i -g tincan",
                    "node /usr/lib/node_modules/npm/bin/npm-cli.js i -g tincan"):
        assert matches(cmdline), cmdline


def test_a_running_npm_is_recorded_for_the_final_assert_instead_of_aborting_the_run():
    assert "Refuse to remove staging dirs while an npm is running" not in NAMES
    assert "npm_running" in THAT
    removal = INNER["Remove them, because npm reads each as an invalid package name"]
    assert "npm_running" in removal["when"]


def test_the_router_is_waited_for_before_the_smoke_call_for_a_bounded_time():
    wait = INNER[WAIT]
    assert wait["ansible.builtin.uri"]["url"] == "http://127.0.0.1:4000/health/readiness"
    assert wait["until"] == "router_before_smoke.status == 200"
    assert 300 <= wait["retries"] * wait["delay"] <= 900
    assert NAMES.index(WAIT) < NAMES.index(SMOKE)
    assert "router_before_smoke" in THAT


def test_the_smoke_call_still_has_to_answer_ok_and_the_failure_text_separates_never_ran_from_failed():
    assert "(pi_smoke | default({})).stdout | default('') is search('OK')" in THAT
    assert "not run, an earlier step in the block failed" in FAIL_MSG
    assert "no reply, stderr: " in FAIL_MSG


def test_the_failed_user_unit_check_tolerates_nothing_and_reads_no_flag_or_clock():
    """A tolerance window was cut (fleet-ops#10211): the gap between two runs varies, so a
    window either equals the run period and can miss a red run, or is wide enough to hide a
    failure for days."""
    assert "failed_system.stdout_lines | length == 0" in THAT
    assert "failed_user.stdout_lines | length == 0" in THAT
    assert "difference(" not in THAT
    assert "Transient" not in THAT and "InactiveEnterTimestamp" not in THAT


def test_the_failure_text_names_every_failed_unit_and_tolerates_none():
    assert "failed units: " in FAIL_MSG
    assert "failed_system.stdout_lines + failed_user.stdout_lines" in FAIL_MSG
    assert "tolerated" not in FAIL_MSG


def test_no_task_was_added_to_read_a_transient_flag_or_to_tolerate_a_unit():
    assert [n for n in ALWAYS_NAMES if any(w in n for w in ("tolerat", "transient", "clock", "stale", "stop time"))] == []


def test_the_run_never_resets_a_unit_so_a_fresh_failure_keeps_its_record():
    argv = [t["ansible.builtin.command"]["argv"] for t in BLOCK["always"] if "ansible.builtin.command" in t]
    argv += [t["ansible.builtin.command"]["argv"] for t in BLOCK["block"] if "ansible.builtin.command" in t]
    assert [a for a in argv if "reset-failed" in a] == []
    assert [a for a in argv if a[:2] == ["date", "+%s"]] == []
    assert [a for a in argv if "--property=Transient" in a] == []


def test_no_line_of_the_runbook_launches_work_under_the_user_manager_without_collect():
    """A unit `systemd-run` created stays loaded in `failed` state after it stops and
    nothing unloads it, which is the cause of the leftovers (fleet-ops#10211).
    `--collect` is the stock flag that unloads it instead. The gate reads every
    line of the RUNBOOK, prose included, so a `sudo`-prefixed line or one wrapped
    after the flag cannot slip past it."""
    runbook = (ROOT / "docs/RUNBOOK.md").read_text()
    joined = runbook.replace("\\\n", " ")
    offenders = {
        number: line.strip()
        for number, line in enumerate(joined.splitlines(), start=1)
        if "systemd-run" in line and "--user" in line and "--collect" not in line
    }
    assert not offenders, offenders


@pytest.mark.skipif(not shutil.which("ansible-playbook"), reason="ansible-playbook missing")
def test_a_failed_user_unit_still_fails_the_run(tmp_path):
    """The detector is unchanged by the cut: a failed user unit fails the run however old
    it is, and the failure text names it (fleet-ops#10211)."""
    probe = [
        {
            "name": "probe the failed-user-unit check of ansible/update.yml",
            "hosts": "localhost",
            "connection": "local",
            "gather_facts": False,
            "vars": {
                "failed_system": {"stdout_lines": []},
                "failed_user": {"stdout_lines": ["item9-pi-only-1028.service loaded failed failed a one-off proof run"]},
                "rc_state": {"stdout": "active"},
            },
            "tasks": [
                {
                    "name": "Fail loudly if any step or check went wrong",
                    "ansible.builtin.assert": {
                        "quiet": True,
                        "that": ASSERT["that"],
                        "fail_msg": ASSERT["fail_msg"],
                    },
                }
            ],
        }
    ]
    path = tmp_path / "failed-user-units.yml"
    path.write_text(json.dumps(probe), encoding="utf-8")
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(path)], capture_output=True, text=True, check=False
    )
    assert result.returncode != 0, result.stdout + result.stderr
    assert "item9-pi-only-1028.service" in result.stdout


def test_the_git_pin_check_asks_github_about_the_default_branch_of_every_github_pin():
    task = INNER[GIT_PIN_CHECK]
    shell = task["ansible.builtin.shell"]
    assert shell["executable"] == "/bin/bash"
    assert task["become_user"] == "nish"
    assert task["register"] == "off_branch_pins"
    assert task["ignore_errors"] is True
    assert 'select(type == "string" and startswith("git:github.com/"))' in shell["cmd"]
    assert "repos/${repo}/compare/HEAD...${sha}" in shell["cmd"]
    assert "identical|behind" in shell["cmd"]


@pytest.mark.parametrize("pin", [ON_MAIN, BEHIND_MAIN])
def test_a_git_pin_on_the_default_branch_passes_the_check_without_output(tmp_path, pin):
    result = run_git_pin_check(tmp_path, [pin, "npm:pi-mcp-adapter@5.3.0"])
    assert result.returncode == 0, result.stderr
    assert result.stdout == ""


@pytest.mark.parametrize("pin, verdict", [(OFF_MAIN, "diverged"), (AHEAD_OF_MAIN, "ahead")])
def test_a_git_pin_off_the_default_branch_fails_the_check_and_names_the_pin(tmp_path, pin, verdict):
    result = run_git_pin_check(tmp_path, [ON_MAIN, pin])
    assert result.returncode == 1
    assert result.stdout.strip() == f"{pin} is not on the default branch ({verdict})"


def test_a_git_pin_github_cannot_answer_fails_the_check_instead_of_passing(tmp_path):
    result = run_git_pin_check(tmp_path, [ON_MAIN, UNANSWERED])
    assert result.returncode == 1
    assert result.stdout.startswith(f"no answer from GitHub for {UNANSWERED}: ")


def test_a_settings_file_that_cannot_be_read_fails_the_check(tmp_path):
    cmd = INNER[GIT_PIN_CHECK]["ansible.builtin.shell"]["cmd"].replace(PI_SETTINGS, str(tmp_path / "gone.json"))
    assert str(tmp_path / "gone.json") in cmd
    result = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert result.returncode == 1
    assert "could not read the git pins from settings.json" in result.stdout


def test_a_settings_file_with_no_git_pins_passes_the_check_without_asking_github(tmp_path):
    result = run_git_pin_check(tmp_path, [])
    assert result.returncode == 0, result.stderr
    assert result.stdout == ""


def test_a_packages_entry_that_is_not_a_string_does_not_fail_the_check(tmp_path):
    result = run_git_pin_check(tmp_path, [ON_MAIN, None, {"name": "pi-grok"}])
    assert result.returncode == 0, result.stderr
    assert result.stdout == ""
