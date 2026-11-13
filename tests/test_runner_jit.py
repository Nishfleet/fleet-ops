"""Runner 22 registers as a just-in-time runner at every start (fleet-ops#11960).

The drop-in's pre-start step runs here for real, under bash, against tests/github_app_stub.py:
the real mint (config/github-app-token/mint.mjs) asks for the one permission, the step deletes
the stale record of the runner's name (GitHub answers 409 to a second request for it), asks for
a JIT config and hands it to systemd in a root-only file. GitHub docs, "Create configuration for
a just-in-time runner for an organization":
https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-an-organization
"""
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DROPIN = ROOT / "rootfs/etc/systemd/system/fleet-runner@22.service.d/10-jit.conf"
STUB = ROOT / "tests/github_app_stub.py"
NEEDS = pytest.mark.skipif(
    not (shutil.which("node") and shutil.which("jq") and shutil.which("curl") and shutil.which("openssl")
         and (ROOT / "config/github-app-token/node_modules").exists()),
    reason="needs node with the pinned Octokit packages, jq, curl and openssl",
)


def dropin_text():
    return DROPIN.read_text()


def prestart_script():
    """The bash -c program of the root pre-start line, as systemd hands it to bash."""
    m = re.search(r"^ExecStartPre=\+/bin/bash -c '(.*?)'$", dropin_text(), flags=re.MULTILINE | re.DOTALL)
    assert m, "no root bash pre-start line"
    body = re.sub(r"\\\n\s*", "", m.group(1))  # a trailing backslash joins the lines
    return body.replace("\\\\", "\\").replace("$$", "$").replace("%%", "%").replace("%i", "22")


def setting(name):
    m = re.search(rf"^Environment='?{name}=(.*?)'?$", dropin_text(), flags=re.MULTILINE)
    assert m, name
    return m.group(1)


@pytest.fixture
def stub(tmp_path):
    subprocess.run(["openssl", "genrsa", "-out", str(tmp_path / "app.pem"), "2048"], capture_output=True, check=True)
    subprocess.run(["openssl", "rsa", "-in", str(tmp_path / "app.pem"), "-pubout", "-out", str(tmp_path / "app.pub")],
                   capture_output=True, check=True)
    mode, log = tmp_path / "mode", tmp_path / "log"
    mode.write_text("ok\n")
    log.write_text("")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen(["python3", str(STUB), str(port), str(tmp_path / "app.pub"), "4728578", str(mode), str(log)])
    for _ in range(40):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                break
        time.sleep(0.25)
    yield type("Stub", (), {"mode": mode, "log": log, "dir": tmp_path, "port": port})
    proc.terminate()


def run_prestart(stub):
    """Run the step as the test user, with the root-only paths and the box's binaries swapped."""
    env_file = stub.dir / "fleet-runner-jit-22.env"
    script = (prestart_script()
              .replace("/usr/sbin/runuser -u nish -- ", "")
              .replace("/opt/node-v22.23.3/bin/node", shutil.which("node"))
              .replace("/etc/fleet-runner-jit-app.env", str(stub.dir / "app.env"))
              .replace("/run/fleet-runner-jit-22.env", str(env_file)))
    (stub.dir / "app.env").write_text(f"APP_ID=4728578\nAPP_KEY={stub.dir / 'app.pem'}\n"
                                      f"MINT={ROOT / 'config/github-app-token/mint.mjs'}\n")
    env = {
        "PATH": os.environ["PATH"],
        "GITHUB_API_URL": f"http://127.0.0.1:{stub.port}",
        "TOKEN_PERMISSIONS": setting("TOKEN_PERMISSIONS"),
    }
    done = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, check=False)
    return done, env_file


def calls(stub):
    return [line.split(" -> ")[0] + " -> " + line.split(" -> ")[1].split()[0] for line in stub.log.read_text().splitlines()]


@NEEDS
def test_start_deletes_the_stale_record_then_registers_the_same_name_with_todays_group_and_labels(stub):
    done, env_file = run_prestart(stub)
    assert done.returncode == 0, done.stderr
    assert env_file.read_text() == "ACTIONS_RUNNER_INPUT_JITCONFIG=jit_stub_netcup-agent-22_3_self-hosted+agent\n"
    assert oct(env_file.stat().st_mode & 0o777) == "0o600"
    seen = calls(stub)
    assert "POST /app/installations/77/access_tokens -> 201" in seen
    assert "ok organization_self_hosted_runners" in stub.log.read_text(), "the token asked for more than the one permission"
    assert seen[-3:] == ["GET /orgs/Nishfleet/actions/runners?per_page=100&name=netcup-agent-22 -> 200",
                         "DELETE /orgs/Nishfleet/actions/runners/5 -> 204",
                         "POST /orgs/Nishfleet/actions/runners/generate-jitconfig -> 201"]
    assert not (stub.dir / "fleet-runner-jit-22.env.new").exists()


@NEEDS
def test_a_restart_leaves_exactly_one_record_of_the_name(stub):
    for _ in range(3):
        done, _ = run_prestart(stub)
        assert done.returncode == 0, done.stderr
    seen = calls(stub)
    assert sum(c.endswith("generate-jitconfig -> 201") for c in seen) == 3
    assert not any("-> 409" in c for c in seen), "a stale record blocked a start"
    assert sum(c.startswith("DELETE ") and c.endswith("-> 204") for c in seen) == 3, "records were left behind"


@NEEDS
def test_a_start_that_cannot_reach_github_fails_and_leaves_no_config_or_secret_behind(stub):
    stub.mode.write_text("fail\n")
    done, env_file = run_prestart(stub)
    assert done.returncode != 0
    assert not env_file.exists()
    assert not re.search(r"ghs_stub_|jit_stub_|eyJ", done.stdout + done.stderr)


def test_the_unit_restarts_after_each_job_and_a_dead_start_ends_failed():
    text = dropin_text()
    assert re.search(r"^Restart=on-success$", text, flags=re.MULTILINE), "a failed start must not loop (fleet-ops#10253)"
    # mint 30s plus the list, one delete and the POST at 20s each
    assert int(re.search(r"^TimeoutStartSec=(\d+)s$", text, flags=re.MULTILINE).group(1)) > 30 + 3 * 20


def test_the_app_id_and_key_paths_stay_out_of_git_and_out_of_the_runner_environment():
    text = dropin_text()
    assert not re.search(r"^Environment='?(APP_ID|APP_KEY|MINT)=", text, flags=re.MULTILINE)
    assert "/home/nish" not in "".join(l for l in text.splitlines() if not l.startswith("#"))
    assert ". /etc/fleet-runner-jit-app.env" in prestart_script()


def test_the_token_asks_for_the_one_permission_and_the_config_never_reaches_the_job_user_or_argv():
    text = dropin_text()
    assert json.loads(setting("TOKEN_PERMISSIONS")) == {"organization_self_hosted_runners": "write"}
    assert re.search(r"^EnvironmentFile=-/run/fleet-runner-jit-%i\.env$", text, flags=re.MULTILINE)
    script = prestart_script()
    assert "umask 077" in script, "files the step creates as root must be root-only"
    assert "/usr/sbin/runuser -u nish -- " in script, "the mint must not run nish-owned code as root"
    assert "-H @-" in script and not re.search(r"-H\s+[\"'][^\"'\n]*\$", script), "the token must reach curl on stdin"
    assert not re.search(r"\becho\b|\bset -x\b|-v\b|--verbose|--trace", script), "nothing may print the token or the config"
    assert "ExecStopPost=+/usr/bin/rm -f /run/fleet-runner-jit-%i.env" in text
    assert re.search(r"^ExecStartPre=/usr/bin/rm -rf /var/lib/fleet-runner/%i/_work ", text, flags=re.MULTILINE), \
        "the work folder must be emptied at each start"
