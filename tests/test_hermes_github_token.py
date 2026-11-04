import os
import pathlib
import re
import shutil
import socket
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STUB = ROOT / "tests/github_app_stub.py"
IN_CI = bool(os.environ.get("GITHUB_ACTIONS"))
SUDO = ["sudo", "-n"] if IN_CI else []
SCOPE = [] if IN_CI else ["--user"]
RUN_DIR = pathlib.Path("/run" if IN_CI else os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))
UNIT_DIR = pathlib.Path("/etc/systemd/system" if IN_CI else pathlib.Path.home() / ".config/systemd/user")
pytestmark = pytest.mark.skipif(
    shutil.which("systemd-run") is None or not (IN_CI or (RUN_DIR / "bus").exists()),
    reason="needs a systemd manager",
)


def sh(cmd, check=False, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=check, **kw)


def ctl(*args):
    return sh([*SUDO, "systemctl", *SCOPE, *args])


@pytest.fixture(scope="module")
def mint(tmp_path_factory):
    d = tmp_path_factory.mktemp("app-token")
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
    yield type("Mint", (), {"mode": mode, "log": log, "dir": d, "port": port})
    stub.terminate()


def test_hermes_login_unit_writes_the_hosts_yml_gh_reads(mint):
    # Runs rootfs/etc/systemd/system/fleet-hermes-github-token.service itself, as
    # the host's system unit, through tests/github_app_stub.py (fleet-ops#10267). The key path and the runtime directory are the only
    # edits, so this is the ExecStart the host runs.
    mint.mode.write_text("ok\n")
    name = "fleet-hermes-token-pytest"
    text = (ROOT / "rootfs/etc/systemd/system/fleet-hermes-github-token.service").read_text()
    text = re.sub(r"^Environment=APP_KEY=.*$", f"Environment=APP_KEY={mint.dir / 'app.pem'}", text, flags=re.MULTILINE)
    text = re.sub(r"^OnFailure=.*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^Environment=GITHUB_API_URL=.*$", f"Environment=GITHUB_API_URL=http://127.0.0.1:{mint.port}", text, flags=re.MULTILINE)
    text = re.sub(r"^RuntimeDirectory=.*$", f"RuntimeDirectory={name}", text, flags=re.MULTILINE)
    # The host runs this as User=nish; the runner has no such user, so the copy
    # takes the job's user instead.
    text = re.sub(r"^User=.*$", f"User={os.environ['USER']}" if IN_CI else "", text, flags=re.MULTILINE)
    unit = mint.dir / f"{name}.service"
    unit.write_text(text)
    target = UNIT_DIR / unit.name
    sh([*SUDO, "install", "-m", "0644", str(unit), str(target)], check=True)
    ctl("daemon-reload")
    run = RUN_DIR / name
    hosts = run / "hosts.yml"
    try:
        first = ctl("start", unit.name)
        assert first.returncode == 0, first.stderr
        body = sh([*SUDO, "cat", str(hosts)]).stdout
        assert re.fullmatch(r"github\.com:\n {4}user: nishfleet-worker\n {4}oauth_token: ghs_stub_\d+\n {4}git_protocol: https\n", body), body
        assert sh([*SUDO, "stat", "-c", "%a", str(hosts)]).stdout.strip() == "600"
        assert sh([*SUDO, "stat", "-c", "%a", str(run)]).stdout.strip() == "700"
        # Age the token file past the 15 min skip window, or the second start
        # would exit 0 on the fresh-token skip instead of testing the failure path.
        sh([*SUDO, "touch", "-d", f"@{int(time.time()) - 1000}", str(hosts)], check=True)
        mint.mode.write_text("fail\n")
        start = ctl("start", unit.name)
        assert start.returncode != 0, "a fresh token file made this start skip instead of minting"
        assert sh([*SUDO, "cat", str(hosts)]).stdout == body, "a failed mint replaced a login Hermes is still reading"
        journal = sh([*SUDO, "journalctl", *SCOPE, "--no-pager", "-u", unit.name]).stdout
        assert not re.search(r"ghs_stub_\d|eyJ", journal), "the token or the App JWT reached the journal"
    finally:
        ctl("reset-failed", unit.name)
        sh([*SUDO, "rm", "-f", str(target)])
        sh([*SUDO, "rm", "-rf", str(run)])
        ctl("daemon-reload")
    mint.mode.write_text("ok\n")
