import os
import pathlib
import re
import shutil
import socket
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-worker-github-token@.service"
STUB = ROOT / "tests/github_app_stub.py"
NAME = "fleet-worker-token-pytest@"
IN_CI = bool(os.environ.get("GITHUB_ACTIONS"))
SUDO = ["sudo", "-n"] if IN_CI else []
SCOPE = [] if IN_CI else ["--user"]
RUN_DIR = pathlib.Path("/run" if IN_CI else os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))
UNIT_DIR = pathlib.Path("/etc/systemd/system" if IN_CI else pathlib.Path.home() / ".config/systemd/user")
ENV_DIR = RUN_DIR / "fleet-worker-github-token"
pytestmark = pytest.mark.skipif(
    shutil.which("systemd-run") is None or not (IN_CI or (RUN_DIR / "bus").exists()),
    reason="needs a systemd manager",
)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ctl(*args):
    return sh([*SUDO, "systemctl", *SCOPE, *args])


@pytest.fixture(scope="module")
def mint(tmp_path_factory):
    d = tmp_path_factory.mktemp("worker-token")
    sh(["openssl", "genrsa", "-out", str(d / "app.pem"), "2048"], check=True)
    sh(["openssl", "rsa", "-in", str(d / "app.pem"), "-pubout", "-out", str(d / "app.pub")], check=True)
    mode, log = d / "mode", d / "log"
    mode.write_text("ok\n")
    log.write_text("")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    stub = subprocess.Popen(["python3", str(STUB), str(port), str(d / "app.pub"), "4728578", str(mode), str(log)])
    for _ in range(40):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                break
        time.sleep(0.25)
    text = UNIT.read_text()
    text = text.replace("%h/.config/fleet-worker/nishfleet-worker.private-key.pem", str(d / "app.pem"))
    text = re.sub(r"^OnFailure=.*\n", "", text, flags=re.M)
    text = re.sub(r"^Environment=GITHUB_API_URL=.*$", f"Environment=GITHUB_API_URL=http://127.0.0.1:{port}", text, flags=re.M)
    if IN_CI:
        text = text.replace("[Service]\n", f"[Service]\nUser={os.environ['USER']}\n")
    unit = d / f"{NAME}.service"
    unit.write_text(text)
    target = UNIT_DIR / f"{NAME}.service"
    sh([*SUDO, "install", "-m", "0644", str(unit), str(target)], check=True)
    ctl("daemon-reload")
    yield type("Mint", (), {"mode": mode, "log": log, "dir": d})
    stub.terminate()
    sh([*SUDO, "rm", "-rf", str(target), str(ENV_DIR)])
    ctl("daemon-reload")


def launch(mint, script, repo="drive", wait=True, env_file=None):
    unit = f"{NAME[:-1]}@{repo}.service"
    env_file = env_file or ENV_DIR / f"{repo}.env"
    cmd = [*SUDO, "systemd-run", *SCOPE, "--collect", "--quiet"]
    if wait:
        cmd += ["--wait", "--pipe"]
    cmd += [
        "-p", f"Requires={unit}", "-p", f"After={unit}",
        "-p", f"EnvironmentFile={env_file}",
        "-p", "ExecStartPre=/bin/sh -c 'test -n \"$GH_TOKEN\"'",
        "--", "/bin/sh", "-c", script,
    ]
    return sh(cmd)


def read_env(repo="drive"):
    return sh([*SUDO, "cat", str(ENV_DIR / f"{repo}.env")]).stdout.strip()


def test_launch_gets_a_minted_token_limited_to_its_repo(mint):
    mint.mode.write_text("ok\n")
    r = launch(mint, 'test -n "$GH_TOKEN" && echo "$GH_TOKEN" | cut -c1-9')
    assert r.returncode == 0 and r.stdout.strip() == "ghs_stub_"
    assert sh([*SUDO, "stat", "-c", "%a", str(ENV_DIR)]).stdout.strip() == "700"
    assert sh([*SUDO, "stat", "-c", "%a", str(ENV_DIR / "drive.env")]).stdout.strip() == "600"
    log = mint.log.read_text()
    assert "GET /repos/Nishfleet/drive/installation -> 200 ok" in log
    assert not re.search(r"bad-jwt|bad-body|unknown", log)


def test_each_launch_mints_a_fresh_token(mint):
    mint.mode.write_text("ok\n")
    assert launch(mint, "true").returncode == 0
    first = read_env()
    assert launch(mint, "true").returncode == 0
    assert read_env() != first


def test_failed_mint_refuses_the_launch_and_leaves_no_stale_token(mint, tmp_path):
    mint.mode.write_text("ok\n")
    assert launch(mint, "true").returncode == 0
    mint.mode.write_text("fail\n")
    ran = tmp_path / "ran"
    assert launch(mint, f"touch {ran}", wait=False).returncode != 0
    assert not ran.exists()
    assert sh([*SUDO, "test", "!", "-e", str(ENV_DIR / "drive.env")]).returncode == 0
    mint.mode.write_text("ok\n")


def test_empty_token_refuses_the_launch(mint, tmp_path):
    mint.mode.write_text("ok\n")
    empty = tmp_path / "empty.env"
    empty.write_text("GH_TOKEN=\n")
    ran = tmp_path / "ran"
    cmd = [*SUDO, "systemd-run", *SCOPE, "--collect", "--quiet", "-p", f"EnvironmentFile={empty}",
           "-p", "ExecStartPre=/bin/sh -c 'test -n \"$GH_TOKEN\"'", "--", "/bin/sh", "-c", f"touch {ran}"]
    assert sh(cmd).returncode != 0
    time.sleep(1)
    assert not ran.exists()


def test_no_token_or_jwt_reaches_the_journal(mint):
    mint.mode.write_text("ok\n")
    assert launch(mint, "true").returncode == 0
    journal = sh([*SUDO, "journalctl", *SCOPE, "--no-pager"]).stdout
    assert not re.search(r"ghs_stub_\d|eyJ", journal)
