"""The tincan relay's approval policy is generated from one roster, not hand-made.

The policy was written by hand on the relay host (fleet-ops#9979), so nothing in
the repo said what the gate was and a new agent silently reached every other
agent. config/tincan-relay/policy.jq now renders it from
config/tincan-relay/agents.txt and ansible/tasks/tincan-relay-policy.yml installs the result. These
checks read the roster, the jq program and the two playbooks.
"""
import json
import pathlib
import re
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROSTER_FILE = ROOT / "config/tincan-relay/agents.txt"
PROGRAM_FILE = ROOT / "config/tincan-relay/policy.jq"
HOST_PLAYBOOK = (ROOT / "ansible/tasks/tincan-relay-policy.yml").read_text()
NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

yq = pytest.mark.skipif(
    subprocess.run(["which", "yq"], capture_output=True).returncode != 0,
    reason="yq is not installed",
)


def roster() -> list[str]:
    lines = ROSTER_FILE.read_text().splitlines()
    return [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]


def render() -> dict:
    proc = subprocess.run(
        ["jq", "-j", "--indent", "1", "-n", "--rawfile", "roster", str(ROSTER_FILE), "-f", str(PROGRAM_FILE)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(proc.stdout)


def check_expression() -> str:
    """The jq -e expression the relay-policy tasks use to fail loudly on a bad policy."""
    found = re.findall(r"validate: jq -e '([^']+)' %s\n", HOST_PLAYBOOK)
    assert len(found) == 1, f"expected one validate: jq -e check in the policy tasks, found {len(found)}"
    return found[0]


def rendered_bytes() -> bytes:
    return subprocess.run(
        ["jq", "-j", "--indent", "1", "-n", "--rawfile", "roster", str(ROSTER_FILE), "-f", str(PROGRAM_FILE)],
        capture_output=True,
        check=True,
    ).stdout


RENDER_TASK = "Render the tincan relay approval policy from the agent roster"
INSTALL_TASK = "Install the rendered tincan relay approval policy"


def test_the_roster_holds_one_clean_agent_name_per_line():
    names = roster()
    assert names, "the roster is empty"
    assert "relay" not in names, "the relay is not an agent the roster gates"
    for name in names:
        assert NAME.match(name), f"{name!r} is not a plain agent name"
    assert len(set(names)) == len(names), "the roster has a duplicate name"


def test_the_roster_is_the_relays_agent_list():
    # The live authority is `tincan agents --json --socket
    # ~/.local/state/tincan-relay/admin.sock`, which CI cannot reach (it runs on
    # GitHub's runners, not the box). The list it answered on 2026-10-30 (amp, cursor-mac and droid-mac
    # gone from the mesh) is pinned here, and ansible/the policy tasks check the live one on every playbook
    # run. A roster edit that is not a deliberate agent change fails here until
    # this list is re-captured with that command.
    assert roster() == [
        "claude-mac",
        "claude-vps",
        "command-code",
        "cursor-vps",
        "devin-mac",
        "devin-vps",
        "fleet-worker",
        "grok-cli-mac",
        "hermes",
        "opencode",
        "pi",
        "pi-mac",
    ]


def test_the_roster_does_not_name_an_agent_the_relay_holds_as_an_outsider():
    # grokbot, instinct and muse are on the mesh but are not ours, so the policy
    # holds them. A name here that is not ours opens the gate for it.
    for outsider in ("grokbot", "instinct", "muse"):
        assert outsider not in roster(), outsider


def test_every_rostered_agent_gets_a_gate_that_holds_outside_chains():
    policy = render()
    names = roster()
    assert sorted(policy["gate"]) == sorted(names), "the gate keys are not the roster"
    allowed = sorted(names + ["relay"])
    for agent, gate in policy["gate"].items():
        assert list(gate) == ["unless"], f"{agent}: the gate is not a single unless list"
        assert gate["unless"] == allowed, f"{agent}: its unless list is not the whole roster plus the relay"


def test_the_policy_names_the_notify_destination_and_the_hold_ttl():
    policy = render()
    assert policy["notify"] == "hermes"
    assert policy["hold_ttl"] == "24h"


def test_the_policy_is_rendered_without_a_trailing_newline():
    # The hand-made file it replaces had none, and -j is what keeps that: a
    # trailing byte is a diff on every host-config run.
    argv = ["jq", "--indent", "1", "-n", "--rawfile", "roster", str(ROSTER_FILE), "-f", str(PROGRAM_FILE)]
    without_j = subprocess.run(argv, capture_output=True, text=True, check=True).stdout
    with_j = subprocess.run(["jq", "-j", *argv[1:]], capture_output=True, text=True, check=True).stdout
    assert without_j == with_j + "\n"


def test_the_loud_check_rejects_a_missing_malformed_or_wrong_shaped_policy(tmp_path):
    expr = check_expression()
    missing = tmp_path / "missing.json"
    assert missing.exists() is False
    cases = {
        "missing": (missing, 2),
        "malformed": (tmp_path / "bad.json", 5),
        "wrong shape": (tmp_path / "shape.json", 1),
    }
    (tmp_path / "bad.json").write_text("not json")
    (tmp_path / "shape.json").write_text(json.dumps({"gate": {}, "notify": "hermes", "hold_ttl": "24h"}))
    for label, (path, want) in cases.items():
        proc = subprocess.run(["jq", "-e", expr, str(path)], capture_output=True, text=True, check=False)
        assert proc.returncode == want, f"{label}: jq exit {proc.returncode}, wanted {want}"
    good = tmp_path / "good.json"
    good.write_text(json.dumps(render()))
    proc = subprocess.run(["jq", "-e", expr, str(good)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stderr


def test_the_host_playbook_renders_installs_and_checks_the_policy():
    # The render is jq driven by the repo's own program file, so there is no
    # script to keep in step with the roster.
    assert re.search(
        r"- name: Render the tincan relay approval policy from the agent roster\n"
        r"(?:.*\n)*?"
        r"\s+- \"\{\{ tincan_relay_roster_file \}\}\"\n"
        r"\s+- -f\n"
        r"\s+- \"\{\{ tincan_relay_policy_program \}\}\"\n",
        HOST_PLAYBOOK,
    ), "the policy tasks do not render the policy from the roster file with the repo's jq program"
    assert re.search(
        r"- name: Install the rendered tincan relay approval policy\n"
        r"(?:.*\n)*?"
        r"\s+content: \"\{\{ tincan_relay_policy\.stdout \| string \}\}\"\n"
        r"\s+dest: \"\{\{ tincan_relay_policy_path \}\}\"\n"
        r"\s+owner: nish\n"
        r"\s+group: nish\n"
        r"\s+mode: \"0600\"\n"
        r"\s+validate: jq -e '[^']+' %s\n",
        HOST_PLAYBOOK,
    ), "the policy tasks do not install the rendered policy 0600 in the relay's state directory"
    assert "- name: Fail when the roster names an agent the relay does not have\n" in HOST_PLAYBOOK


@pytest.mark.skipif(not (shutil.which("ansible-playbook") and shutil.which("yq")), reason="ansible or yq is not installed")
def test_the_host_playbook_installs_the_render_byte_for_byte(tmp_path):
    # The install moves the render through a registered result, and Ansible
    # folds a multi-line registered string into one line unless the task turns
    # it into a plain string first. Running the two real tasks is the only way
    # to see that: a policy that is one line long is still valid JSON, so the
    # loud check below would pass while the box's gate had drifted.
    state = tmp_path / ".local/state/tincan-relay"
    state.mkdir(parents=True)
    play = json.loads(
        subprocess.run(
            ["yq", "-o=json", ".", str(ROOT / "ansible/host.yml")],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )[0]
    relay_tasks = json.loads(
        subprocess.run(
            ["yq", "-o=json", ".", str(ROOT / "ansible/tasks/tincan-relay-policy.yml")],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    tasks = {t["name"]: t for t in relay_tasks}
    for name in (RENDER_TASK, INSTALL_TASK):
        task = json.loads(json.dumps(tasks[name]))
        task.pop("become", None)
        task.pop("become_user", None)
        for module in task.values():
            if isinstance(module, dict):
                for key in ("owner", "group"):
                    module.pop(key, None)
        tasks[name] = task
    book = tmp_path / "play.json"
    book.write_text(
        json.dumps(
            [
                {
                    "hosts": "localhost",
                    "connection": "local",
                    "gather_facts": False,
                    "vars": {
                        **play["vars"],
                        "nish_home": str(tmp_path),
                        "nish_env": {"HOME": str(tmp_path)},
                        "tincan_relay_roster_file": str(ROSTER_FILE),
                        "tincan_relay_policy_program": str(PROGRAM_FILE),
                    },
                    "tasks": [tasks[RENDER_TASK], tasks[INSTALL_TASK]],
                }
            ]
        )
    )
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(book)],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert (state / "approval.json").read_bytes() == rendered_bytes()
