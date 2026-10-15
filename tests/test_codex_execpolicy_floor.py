"""The Codex execpolicy floor rejects irreversible commands and nothing else.

config/codex/rules/fleet-floor.rules is installed to ~/.codex/rules/ by
ansible/host.yml. Codex itself loads the file with `codex execpolicy check`,
which also refuses a file whose own match and not_match examples are wrong.
The binary comes from CODEX_BIN, else PATH, else the release pinned in
tests/codex-cli installed from its lockfile into a temp dir.
"""
import json
import os
import pathlib
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/codex/rules/fleet-floor.rules"
HOST = ROOT / "ansible/host.yml"
HOME = "/home/nish"
PIN = ROOT / "tests/codex-cli"
CODEX = []


def _install(dest):
    npm = shutil.which("npm")
    if not npm:
        return None
    for name in ("package.json", "package-lock.json"):
        shutil.copy(PIN / name, dest / name)
    env = {"PATH": os.environ["PATH"], "HOME": str(dest), "npm_config_cache": str(dest / ".npm")}
    done = subprocess.run(
        [npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
        capture_output=True, text=True, env=env, cwd=str(dest),
    )
    assert done.returncode == 0, done.stderr
    return str(dest / "node_modules/.bin/codex")


@pytest.fixture(scope="module")
def home(tmp_path_factory):
    found = os.environ.get("CODEX_BIN") or shutil.which("codex")
    found = found or _install(tmp_path_factory.mktemp("codex"))
    if not found:
        assert not os.environ.get("CI"), "CI needs npm to install the pinned codex"
        pytest.skip("codex and npm missing")
    CODEX[:] = [found]
    return tmp_path_factory.mktemp("home")


def _check(home, *argv, rules=RULES):
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "CODEX_HOME": str(home / ".codex")}
    return subprocess.run(
        [CODEX[0], "execpolicy", "check", "--rules", str(rules), "--", *argv],
        capture_output=True, text=True, env=env, cwd=str(home),
    )


def _decision(home, command):
    done = _check(home, *command.split())
    assert done.returncode == 0, done.stderr
    return json.loads(done.stdout).get("decision")


FORBIDDEN = [
    "git push --force origin main",
    "git push -f",
    "git push --force-with-lease",
    "git push origin --force",
    "git push origin main -f",
    "sudo git push --force",
    "git reset --hard",
    "git reset --hard origin/main",
    "git clean -f",
    "git clean -fd",
    "git clean -fdx",
    "git clean -ffdx",
    "git branch -D topic",
    "gh repo delete owner/name --yes",
    "gh release delete v1",
    "wrangler delete",
    "npx wrangler delete",
    "npx --yes wrangler delete",
    "restic forget --keep-last 1",
    "restic prune",
    "rm -rf /",
    "rm -fr /",
    "rm -rf /home",
    f"rm -rf {HOME}",
    f"rm -rf {HOME}/workspaces",
    "rm -rf ~/workspaces",
    "sudo rm -rf /",
    "reboot",
    "shutdown -h now",
    "poweroff",
    "halt",
    "systemctl stop fleet.service",
    "systemctl disable fleet.service",
    "systemctl --user stop fleet.service",
    "systemctl --user disable fleet.service",
    "sudo systemctl stop fleet.service",
]

HARMLESS = [
    "git push origin main",
    "git push -u origin feature",
    "git status",
    "git reset --soft HEAD~1",
    "git clean -n",
    "git branch -d topic",
    "gh pr list",
    "wrangler deploy",
    "restic snapshots",
    "rm -rf ./build",
    "rm -rf /tmp/build",
    f"rm -rf {HOME}/workspaces/agent-worktrees/job-1",
    "systemctl status fleet.service",
    "systemctl --user restart fleet.service",
    "ls -la",
]


@pytest.mark.parametrize("command", FORBIDDEN)
def test_forbidden(home, command):
    assert _decision(home, command) == "forbidden"


@pytest.mark.parametrize("command", HARMLESS)
def test_harmless_is_left_alone(home, command):
    assert _decision(home, command) is None


def test_a_forbidden_hit_carries_its_reason(home):
    out = json.loads(_check(home, "git", "reset", "--hard").stdout)
    hit = out["matchedRules"][0]["prefixRuleMatch"]
    assert hit["decision"] == "forbidden" and hit["justification"]


def test_every_rule_is_forbidden_with_a_justification(home):
    text = RULES.read_text()
    assert text.count("prefix_rule(") == text.count("decision = \"forbidden\"")
    assert text.count("prefix_rule(") == text.count("justification = ")
    assert "\"allow\"" not in text and "\"prompt\"" not in text


def test_rule_examples_are_checked_by_codex(home, tmp_path):
    bad = tmp_path / "bad.rules"
    bad.write_text('prefix_rule(pattern=["a"], decision="forbidden", match=[["b"]])\n')
    done = _check(home, "ls", rules=bad)
    assert done.returncode != 0 and "unmatched examples" in done.stderr
    bad.write_text('prefix_rule(pattern=["a"], decision="forbidden", not_match=[["a", "b"]])\n')
    done = _check(home, "ls", rules=bad)
    assert done.returncode != 0 and "expected example to not match" in done.stderr


def test_every_class_has_match_examples():
    text = RULES.read_text()
    for needle in [
        "git\", \"push\"", "\"reset\", \"--hard\"", "\"clean\"", "\"branch\", \"-D\"",
        "\"gh\", \"repo\", \"delete\"", "\"gh\", \"release\", \"delete\"",
        "\"wrangler\", \"delete\"", "\"restic\"", "\"forget\", \"prune\"", "\"rm\"",
        "reboot", "shutdown", "poweroff", "halt", "\"systemctl\"", "\"--user\"",
    ]:
        assert needle in text, needle
    assert text.count("match = [") >= text.count("not_match = [") >= 15


def test_host_play_installs_the_file_for_nish():
    play = json.loads(subprocess.run(
        ["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True,
    ).stdout)[0]
    tasks = {t["name"]: t for t in play["tasks"]}
    install = tasks["Install the Codex execpolicy floor"]
    copy = install["ansible.builtin.copy"]
    assert install["become"] is True and install["become_user"] == "nish"
    assert copy["src"] == "{{ playbook_dir }}/../config/codex/rules/fleet-floor.rules"
    assert copy["dest"] == "{{ nish_home }}/.codex/rules/fleet-floor.rules"
    assert copy["mode"] == "0644"
    mkdir = tasks["Create Codex's rules directory"]
    assert mkdir["become"] is True and mkdir["become_user"] == "nish"
    assert mkdir["ansible.builtin.file"]["state"] == "directory"
    assert "config.toml" not in json.dumps(install)
