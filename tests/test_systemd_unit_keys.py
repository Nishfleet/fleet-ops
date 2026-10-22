"""A unit file with an unknown directive must fail CI: systemd skips it with a warning and exit 0 (fleet-ops#9967)."""

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLED = ROOT / "rootfs/etc/systemd/system"
DASH_PREFIXED_KEY = re.compile(r"^-[A-Za-z]+=")


def unit_files() -> list[Path]:
    found = []
    for pattern in ("systemd/*.service", "systemd/*.timer", "systemd/*.path", "systemd/*.slice"):
        found += sorted(ROOT.glob(pattern))
    found += sorted(INSTALLED.glob("*.slice"))
    found += sorted(INSTALLED.glob("fleet-deploy.*"))
    found += sorted(INSTALLED.glob("fleet-host-config.*"))
    found += sorted(INSTALLED.glob("fleet-update.*"))
    found += sorted(INSTALLED.glob("tether-*"))
    found += sorted(INSTALLED.glob("tincan-listen-*"))
    return [path for path in found if path.is_file()]


@pytest.mark.parametrize("unit", unit_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_no_directive_starts_with_the_ignore_failure_dash(unit: Path) -> None:
    offenders = [line for line in unit.read_text().splitlines() if DASH_PREFIXED_KEY.match(line)]
    assert offenders == [], (
        f"{unit.relative_to(ROOT)}: {offenders}. The ignore-failure prefix goes after the '=' "
        "as ExecStart=-command, not in front of the key."
    )


DEPLOY_BOX = ROOT / ".github/workflows/deploy-box.yml"
DEPLOY_DIR = "/var/lib/fleet-deploy"


def _deploy_box_run_block() -> str:
    """The apply job's shell, from the workflow's last (and only) run: block."""
    text = DEPLOY_BOX.read_text()
    marker = "        run: |\n"
    assert text.count(marker) == 1, "one run block in deploy-box.yml"
    return text.split(marker, 1)[1]


def _run_deploy_box(tmp_path: Path, result: str, log: str, systemctl_exit: int) -> subprocess.CompletedProcess:
    """Run deploy-box's step against a temp mailbox with a stub systemctl."""
    mailbox = tmp_path / "fleet-deploy"
    mailbox.mkdir(parents=True)
    (mailbox / "result").write_text(result)
    (mailbox / "log").write_text(log)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "systemctl").write_text(f"#!/bin/sh\nexit {systemctl_exit}\n")
    (bin_dir / "systemctl").chmod(0o755)
    body = _deploy_box_run_block().replace(DEPLOY_DIR, str(mailbox))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GITHUB_RUN_ID": "12345",
        "GITHUB_RUN_ATTEMPT": "2",
    }
    script = tmp_path / "step.sh"
    script.write_text(body)
    return subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, check=False)


def test_deploy_box_job_probes_the_runner_then_writes_the_request() -> None:
    text = DEPLOY_BOX.read_text()
    assert "runs-on: [self-hosted, fleet-ci]" in text
    probe = text.index("runner-probe")
    run_block = text.index("        run: |")
    assert probe < run_block, "the runner-probe step must come first"
    body = _deploy_box_run_block()
    assert "systemctl is-active --quiet fleet-deploy.path" in body, "an inactive path unit must fail the job at once"
    assert 'grep "^$stamp "' in body, "the poll must match only this run's own request line"
    for gone in ("--user", "XDG_RUNTIME_DIR", "sudo", "polkit", "systemctl start", "journalctl"):
        assert gone not in body, gone


def test_deploy_box_exits_0_on_a_success_verdict(tmp_path: Path) -> None:
    proc = _run_deploy_box(tmp_path, "run-12345-2 success 0 2026-10-22T10:00:00Z\n", "", 0)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "deploy request: run-12345-2" in proc.stdout
    assert "deploy verdict: run-12345-2 success 0" in proc.stdout


def test_deploy_box_fails_on_a_failed_verdict_and_prints_the_log(tmp_path: Path) -> None:
    proc = _run_deploy_box(tmp_path, "run-12345-2 exit-code 3 2026-10-22T10:00:00Z\n", "PLAY RECAP failed=1\n", 0)
    assert proc.returncode != 0
    assert "PLAY RECAP failed=1" in proc.stdout, "the runner cannot read the journal, so the unit's log is the evidence"


def test_deploy_box_ignores_another_runs_verdict_and_fails_when_the_path_unit_is_dead(tmp_path: Path) -> None:
    mailbox = tmp_path / "fleet-deploy"
    mailbox.mkdir()
    (mailbox / "result").write_text("run-99999-1 success 0 2026-10-22T10:00:00Z\n")
    (mailbox / "log").touch()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n")
    (bin_dir / "systemctl").chmod(0o755)
    script = tmp_path / "step.sh"
    script.write_text(_deploy_box_run_block().replace(DEPLOY_DIR, str(mailbox)))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "GITHUB_RUN_ID": "12345",
        "GITHUB_RUN_ATTEMPT": "2",
    }
    proc = subprocess.run(["timeout", "5", "bash", str(script)], env=env, capture_output=True, text=True, check=False)
    assert proc.returncode == 124, "a verdict for another request must never satisfy this run (job timeout is the backstop)"
    proc = _run_deploy_box(tmp_path / "dead", "", "", 3)
    assert proc.returncode != 0
    assert "fleet-deploy.path is not active" in proc.stdout


def test_the_polkit_rule_is_retired_not_shipped() -> None:
    host = (ROOT / "ansible/host.yml").read_text()
    retired = host.split("    retired:", 1)[1].split("    box_only_file:", 1)[0]
    assert f"- {DEPLOY_DIR}" not in host
    assert "/etc/polkit-1/rules.d/50-fleet-host-config.rules" in retired
    assert "Install polkit rules" not in host
    assert not (ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-host-config.rules").exists()


def test_the_fleet_ci_runners_hide_the_user_bus() -> None:
    for runner in ("1", "2"):
        conf = ROOT / f"rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-fleet-ci-{runner}.service.d/40-no-bus.conf"
        assert "InaccessiblePaths=-/run/user/1000" in conf.read_text(), conf


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_reports_no_unknown_directive() -> None:
    files = [str(path) for path in unit_files()]
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", *files],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    unknown = [
        line
        for line in (proc.stdout + proc.stderr).splitlines()
        if "Unknown key" in line or "Unknown section" in line
    ]
    assert unknown == [], "\n".join(unknown)


def test_fleet_deploy_verdict_line_names_the_request_the_run_started_with(tmp_path: Path) -> None:
    lines = (INSTALLED / "fleet-deploy.service").read_text().splitlines()
    post = [line.removeprefix("ExecStopPost=") for line in lines if line.startswith("ExecStopPost=/bin/sh -c 'r=")]
    assert len(post) == 1
    (tmp_path / "running").write_text("abc123 77-1\n")
    (tmp_path / "request").write_text("def456 78-1\n")
    command = post[0].replace("/var/lib/fleet-deploy", str(tmp_path)).replace("%%", "%").replace("$$", "$")
    env = {**os.environ, "SERVICE_RESULT": "exit-code", "EXIT_STATUS": "3"}
    subprocess.run(shlex.split(command), env=env, check=True)
    assert re.fullmatch(r"abc123 77-1 exit-code 3 \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\n", (tmp_path / "result").read_text())


TETHER = INSTALLED / "tether-agent.service"


def _tether_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in TETHER.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    return keys


def test_tether_restart_is_capped_and_pages() -> None:
    keys = _tether_keys()
    assert keys["Restart"] == ["on-failure"]
    assert keys["Requires"] == ["nftables.service"] and "nftables.service" in keys["After"]
    interval = int(keys["StartLimitIntervalSec"][0])
    burst = int(keys["StartLimitBurst"][0])
    restart = int(keys["RestartSec"][0])
    assert interval > 0 and burst > 0, "a zero interval disables the start limit"
    assert burst * restart < interval, "the limit must be reachable inside its interval"
    assert interval >= 3600, "a slow crash loop must still reach the limit"
    assert keys["OnFailure"] == ["fleet-unit-failed@%N.service"]


def test_tether_cannot_reach_loopback_or_rewrite_its_code() -> None:
    keys = _tether_keys()
    assert keys["IPAddressDeny"] == ["localhost"]
    assert keys["IPAddressAllow"] == ["127.0.0.1/32 127.0.0.53/32"]
    assert "ReadWritePaths" not in keys
    assert keys["ConditionPathExists"] == ["/opt/tether/current/dist/index.js"]
    assert keys["ExecStart"][0].split()[-1] == "/opt/tether/current/dist/index.js"
    assert not keys["WorkingDirectory"][0].startswith("/opt/")


def _tether_tasks(marker: Path, extra: tuple[str, ...] = ()) -> dict[str, dict]:
    # Every path the tether tasks look at is pointed at a temp root next to the
    # marker, so the result never depends on what this host already has under
    # /opt or /var/cache (the Node directory, the release, the symlink).
    root = marker.parent / "roots"
    roots = (
        "-e", f"tether_node_dir={root}/node",
        "-e", f"tether_node_cache={root}/node-cache",
        "-e", f"tether_release_root={root}/opt-tether",
        "-e", f"tether_release_cache={root}/release-cache",
    )
    env = {**os.environ, "ANSIBLE_STDOUT_CALLBACK": "json", "ANSIBLE_LOCALHOST_WARNING": "False"}
    proc = subprocess.run(
        [
            "ansible-playbook", "--check", "-c", "local", "-i", "localhost,", "--tags", "tether",
            "-e", f"tether_off_marker={marker}", *roots, *extra, "ansible/host.yml",
        ],
        cwd=ROOT, env=env, capture_output=True, text=True, check=False,
    )
    out = proc.stdout
    plays = json.loads(out[out.index("{"):])["plays"]
    assert plays, proc.stderr
    return {task["task"]["name"]: task["hosts"]["localhost"] for task in plays[0]["tasks"] if "localhost" in task["hosts"]}


# Tasks that run with or without the marker: they only read, or they are the
# marker's own tasks.
TETHER_ALWAYS = {
    "Look for the tether off marker",
    "Look for the tether Photon credentials file",
    "Look up the tether uid",
    "Read the host's addresses and bridges",
    "Create the nftables drop-in directory",
    "Remove the tether egress rule while the marker exists",
    "Keep tether disabled and stopped while the marker exists",
    "Apply pending handlers before the tether failure check",
}
# Tasks that a clean host (temp roots, nothing installed) must really reach with
# no marker. The rest of the release tasks are skipped by design on a clean host,
# or are command tasks that --check skips with its own message (checked below).
TETHER_REACHED = (
    "Create the tether group",
    "Create the tether service user",
    "Create the tether config directory",
    "Create the tether app directory, root-owned",
    "Download the pinned Node tarball for tether",
    "Create the versioned Node directory, root-owned",
    "Unpack the pinned Node for tether",
    "Create the tether release cache, root-owned",
    "Create the nish download directory for tether releases",
    "Look for this tether release directory",
    "Look for the entry point of this tether release",
    "Record whether this tether release is already installed whole",
    "Look for the verified tether tarball",
    "Record whether the tether release must be downloaded",
    "Read whether gh is logged in for nish",
    "Require nish's gh login before the download",
    "Download the pinned tether release as nish",
    "Verify the tether release against the pinned sha256",
    "Remove the unverified tether download",
    "Clear the tether staging directory",
    "Create the tether staging directory, root-owned",
    "Unpack the verified tether release into staging",
    "Look for the entry point in the staged tether release",
    "Look at the unverified tether download",
    "Require the tether download to be a plain file",
    "Scan the staged tether release for writable or non-root files",
    "Record the writable or non-root files in the staged tether release",
    "Require the expected layout and modes before the release is moved into place",
    "Look at where tether current points now",
    "Point tether current at the verified release",
    "Let the tether group read the Photon credentials file",
)
TETHER_COMMANDS = ("Move the staged tether release into place",)
# The block's own name and its rescue tasks never show as tasks of a run that
# does not fail.
TETHER_NEVER_RUN = {
    "Install the pinned tether release, or record why it failed",
    "Record that the tether release did not install",
    "Say that tether current was left alone",
}


def _play_tasks() -> list[dict]:
    if shutil.which("yq") is None:
        pytest.skip("yq is not installed")
    out = subprocess.run(["yq", "-o=json", ".", str(HOST_YML)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]["tasks"]


def _tether_task_names() -> list[str]:
    names: list[str] = []
    for task in _play_tasks():
        if "tether" in (task.get("tags") or []):
            names += [task["name"]] + [inner["name"] for key in ("block", "rescue") for inner in task.get(key, [])]
    return names


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_off_marker_survives_the_host_run(tmp_path: Path) -> None:
    marker = tmp_path / "tether-off"
    photon = tmp_path / "photon.env"
    photon.touch()
    extra = ("-e", f"tether_photon_env={photon}")
    on = _tether_tasks(marker, extra)
    marker.touch()
    off = _tether_tasks(marker, extra)
    for name in TETHER_REACHED:
        assert not on[name].get("skipped"), name
    for name in TETHER_COMMANDS:
        assert on[name].get("skipped") and "check mode" in on[name]["msg"], name
    # With the marker every tether task is skipped, the release ones included:
    # the ones the marker does not gate are named above, and a task added to the
    # play without a place in these lists fails here.
    names = [n for n in _tether_task_names() if n not in TETHER_ALWAYS and n not in TETHER_NEVER_RUN]
    assert set(TETHER_REACHED) | set(TETHER_COMMANDS) <= set(names)
    for name in names:
        assert off[name].get("skipped"), name
    assert not off["Keep tether disabled and stopped while the marker exists"].get("skipped")
    assert not off["Remove the tether egress rule while the marker exists"].get("skipped")
    assert on["Remove the tether egress rule while the marker exists"].get("skipped")
    assert on["Keep tether disabled and stopped while the marker exists"].get("skipped"), "no marker: the run never touches the unit"


HOST_YML = ROOT / "ansible/host.yml"


def _tether_blocks() -> list[str]:
    blocks = re.split(r"\n    - name: ", HOST_YML.read_text())
    return [block for block in blocks if "tags: [tether" in block]


def _tether_module_blocks(module: str) -> list[str]:
    return [block for block in _tether_blocks() if f"ansible.builtin.{module}:" in block]


def _host_var(name: str) -> str:
    match = re.search(rf"^    {name}: \"?([^\"\n]+)\"?$", HOST_YML.read_text(), re.MULTILINE)
    assert match, name
    return match.group(1)


def _node_dir() -> str:
    return _host_var("tether_node_dir").replace("{{ tether_node_version }}", _host_var("tether_node_version"))


def test_tether_has_no_apt_nodejs_pin() -> None:
    assert not [block for block in _tether_module_blocks("apt") if "nodejs" in block]
    assert "nodejs=" not in HOST_YML.read_text()


def test_tether_node_download_is_pinned_by_sha256() -> None:
    assert re.fullmatch(r"22\.\d+\.\d+", _host_var("tether_node_version"))
    assert re.fullmatch(r"[0-9a-f]{64}", _host_var("tether_node_sha256"))
    downloads = [block for block in _tether_module_blocks("get_url") if "tether_node_sha256" in block]
    assert len(downloads) == 1
    assert re.search(r'^        url: "https://nodejs\.org/dist/v\{\{ tether_node_version \}\}/[^"]+-linux-x64\.tar\.xz"$', downloads[0], re.M)
    assert re.search(r'^        checksum: "sha256:\{\{ tether_node_sha256 \}\}"$', downloads[0], re.M)
    unpack = [block for block in _tether_module_blocks("unarchive") if "tether_node_dir" in block]
    assert len(unpack) == 1
    assert re.search(r'^        dest: "\{\{ tether_node_dir \}\}"$', unpack[0], re.M)
    assert re.fullmatch(r"/opt/node-v\d+\.\d+\.\d+", _node_dir())


def test_tether_execstart_uses_the_pinned_node() -> None:
    command = _tether_keys()["ExecStart"][0].split()
    assert command[0] == f"{_node_dir()}/bin/node"
    assert command[-1].startswith("/opt/tether/")


def _release_block() -> dict:
    tasks = _play_tasks()
    blocks = [task for task in tasks if task["name"] == "Install the pinned tether release, or record why it failed"]
    assert len(blocks) == 1
    return blocks[0]


def _release_tasks() -> dict[str, dict]:
    return {task["name"]: task for task in _release_block()["block"]}


def test_tether_release_is_pinned_once_and_keyed_by_version_and_hash() -> None:
    assert re.fullmatch(r"\d+\.\d+\.\d+", _host_var("tether_version"))
    assert re.fullmatch(r"[0-9a-f]{64}", _host_var("tether_sha256"))
    text = HOST_YML.read_text()
    assert text.count("tether_sha256:") == 1 and text.count("tether_version:") == 1, "pin the release in one place"
    assert _host_var("tether_sha256") not in text.replace(f"tether_sha256: {_host_var('tether_sha256')}", "")
    assert _host_var("tether_release_key") == "{{ tether_version }}-{{ tether_sha256[:12] }}"
    assert _host_var("tether_release_dir") == "{{ tether_release_root }}/{{ tether_release_key }}"
    assert _host_var("tether_release_tarball") == "{{ tether_release_cache }}/tether-v{{ tether_release_key }}.tar.gz"
    assert _host_var("tether_release_root") == "/opt/tether", "the unit names /opt/tether/current"


def test_tether_release_installs_in_one_block_with_a_rescue_and_a_last_task_that_fails() -> None:
    tasks = _play_tasks()
    block = _release_block()
    assert block["when"] == "not tether_off.stat.exists"
    rescue = {task["name"]: task for task in block["rescue"]}
    facts = [task["ansible.builtin.set_fact"] for task in rescue.values() if "ansible.builtin.set_fact" in task]
    assert [list(fact) for fact in facts] == [["tether_install_failure"]]
    assert not any("link" in json.dumps(task) and "state" in json.dumps(task) for task in rescue.values()), "the rescue leaves current alone"
    last = tasks[-1]
    assert last["name"] == "Fail when the tether release could not be installed"
    assert "ansible.builtin.fail" in last
    assert last["when"] == "tether_install_failure is defined and not ansible_check_mode"
    assert tasks.index(block) < len(tasks) - 1
    assert "always" not in block and "ignore_errors" not in block, "a failure must reach the rescue"


def test_tether_release_steps_run_in_order_and_the_link_comes_last() -> None:
    names = list(_release_tasks())
    order = [
        "Look for this tether release directory",
        "Look for the verified tether tarball",
        "Require nish's gh login before the download",
        "Download the pinned tether release as nish",
        "Verify the tether release against the pinned sha256",
        "Create the tether staging directory, root-owned",
        "Unpack the verified tether release into staging",
        "Require the expected layout and modes before the release is moved into place",
        "Move the staged tether release into place",
        "Point tether current at the verified release",
        "Remove tether releases older than the previous one",
    ]
    assert [names.index(n) for n in order] == sorted(names.index(n) for n in order)
    tasks = _release_tasks()
    links = [n for n, task in tasks.items() if "ansible.builtin.file" in task and task["ansible.builtin.file"].get("state") == "link"]
    assert links == ["Point tether current at the verified release"]
    assert tasks[links[0]]["ansible.builtin.file"]["dest"] == "{{ tether_release_root }}/current"
    assert tasks[links[0]]["ansible.builtin.file"]["src"] == "{{ tether_release_dir }}"


def test_tether_release_is_verified_staged_and_renamed_into_place() -> None:
    tasks = _release_tasks()
    verify = tasks["Verify the tether release against the pinned sha256"]["ansible.builtin.get_url"]
    assert verify["checksum"] == "sha256:{{ tether_sha256 }}"
    assert verify["url"] == "file://{{ tether_release_download }}"
    assert verify["dest"] == "{{ tether_release_tarball }}"
    assert verify["owner"] == "root" and verify["group"] == "root"
    unpack = tasks["Unpack the verified tether release into staging"]["ansible.builtin.unarchive"]
    assert unpack["src"] == "{{ tether_release_tarball }}", "unpack the verified file, not the download"
    assert unpack["dest"] == "{{ tether_release_stage }}", "never straight into the final directory"
    assert unpack["mode"] == "u=rwX,go=rX" and unpack["owner"] == "root" and "creates" not in unpack
    assert "extra_opts" not in unpack, "the tarball root holds dist/ directly"
    assert _host_var("tether_release_stage") == "{{ tether_release_root }}/.tmp-{{ tether_release_key }}"
    move = tasks["Move the staged tether release into place"]["ansible.builtin.command"]["argv"]
    assert move == ["/usr/bin/mv", "-T", "{{ tether_release_stage }}", "{{ tether_release_dir }}"]
    check = json.dumps(tasks["Require the expected layout and modes before the release is moved into place"])
    assert "isreg" in check and "tether_stage_unsafe | length == 0" in check
    assert tasks["Clear the tether staging directory"]["ansible.builtin.file"]["state"] == "absent"
    stale = tasks["Remove a tether release directory that is incomplete or unsafe"]
    assert stale["ansible.builtin.file"]["state"] == "absent" and "not tether_rel_ok" in stale["when"]
    for name in ("Unpack the verified tether release into staging", "Move the staged tether release into place"):
        assert tasks[name]["when"] == "not tether_rel_ok", "a complete release directory is never unpacked over"


def test_tether_release_modes_are_checked_with_the_find_module_and_a_bad_dir_goes_last() -> None:
    text = HOST_YML.read_text()
    assert "/usr/bin/find" not in text, "use ansible.builtin.find, not a command"
    tasks = _release_tasks()
    for name in ("Scan this tether release for writable or non-root files", "Scan the staged tether release for writable or non-root files"):
        scan = tasks[name]["ansible.builtin.find"]
        assert scan["recurse"] is True and scan["hidden"] is True and scan["follow"] is False and scan["file_type"] == "any"
    names = list(tasks)
    remove = "Remove a tether release directory that is incomplete or unsafe"
    gate = "Require the expected layout and modes before the release is moved into place"
    move = "Move the staged tether release into place"
    verify = "Verify the tether release against the pinned sha256"
    assert names.index(verify) < names.index(gate) < names.index(remove) < names.index(move), "keep the old directory until its replacement is staged and checked"
    guard = tasks["Require the tether download to be a plain file"]["ansible.builtin.assert"]["that"]
    assert "isreg" in guard and names.index("Require the tether download to be a plain file") < names.index(verify)


def test_tether_failure_check_comes_after_a_handler_flush() -> None:
    tasks = _play_tasks()
    assert tasks[-1]["name"] == "Fail when the tether release could not be installed"
    assert tasks[-2]["ansible.builtin.meta"] == "flush_handlers", "pending reloads run before the play fails"


def test_tether_release_download_runs_as_nish_after_a_login_check() -> None:
    tasks = _release_tasks()
    download = tasks["Download the pinned tether release as nish"]
    assert download["become"] is True and download["become_user"] == "nish"
    argv = download["ansible.builtin.command"]["argv"]
    assert argv[:3] == ["{{ tether_gh }}", "release", "download"] and "Nishfleet/tether" in argv
    assert _host_var("tether_gh") == "/usr/bin/gh"
    check = tasks["Read whether gh is logged in for nish"]
    assert check["become_user"] == "nish" and check["no_log"] is True
    assert check["ansible.builtin.command"]["argv"] == ["{{ tether_gh }}", "auth", "token"]
    gate = tasks["Require nish's gh login before the download"]
    assert "gh not authenticated for nish" in gate["ansible.builtin.assert"]["fail_msg"]
    names = list(tasks)
    assert names.index(check["name"]) < names.index(gate["name"]) < names.index(download["name"])
    text = json.dumps(_release_block())
    assert "/" + "home" + "/" not in text, "no literal home path"
    assert not re.search(r"GH_TOKEN|GITHUB_TOKEN|Authorization|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_", HOST_YML.read_text())


def test_tether_release_prunes_to_the_new_and_the_previous_release() -> None:
    tasks = _release_tasks()
    for name in ("Remove tether releases older than the previous one", "Remove cached tether tarballs of releases that were removed"):
        assert tasks[name]["when"] == "tether_link.changed | default(false)", "a repeat run must not trim the previous release"
        loop = tasks[name]["loop"]
        assert "tether_release_dir" in loop or "tether_release_tarball" in loop
        assert "tether_cur.stat.lnk_source" in loop, "keep what current pointed at before"


def test_tether_loads_both_environment_files() -> None:
    assert _tether_keys()["EnvironmentFile"] == ["-/etc/tether/tether.env", "-/etc/tether/photon.env"]


def test_tether_photon_env_is_only_chowned_never_created() -> None:
    assert _host_var("tether_photon_env") == "/etc/tether/photon.env"
    users = [block for block in _tether_blocks() if "tether_photon_env }}" in block and "ansible.builtin.stat:" not in block]
    assert len(users) == 1
    block = users[0]
    assert "ansible.builtin.file:" in block and "        state: file\n" in block
    assert "        owner: root\n        group: tether\n        mode: \"0640\"\n" in block
    assert "tether_photon.stat.exists" in block, "a missing file must skip the task, not fail the run"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_photon_env_task_waits_for_the_file(tmp_path: Path) -> None:
    name = "Let the tether group read the Photon credentials file"
    photon = tmp_path / "photon.env"
    missing = _tether_tasks(tmp_path / "no-marker", extra=("-e", f"tether_photon_env={photon}"))
    assert missing[name].get("skipped"), "no file: nothing to do and nothing to fail"
    photon.touch()
    present = _tether_tasks(tmp_path / "no-marker", extra=("-e", f"tether_photon_env={photon}"))
    assert not present[name].get("skipped")


def test_host_run_never_enables_or_starts_tether() -> None:
    blocks = re.split(r"\n    - name: ", (ROOT / "ansible/host.yml").read_text())
    tether = [block for block in blocks if "name: tether-agent.service" in block]
    assert tether, "the marker task is gone"
    for block in tether:
        assert "enabled: true" not in block and "state: started" not in block, block
        assert "when: tether_off.stat.exists" in block, block


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_nft_template_renders_and_loads(tmp_path: Path) -> None:
    out = tmp_path / "tether.nft"
    facts = {
        "all_ipv4_addresses": ["192.0.2.5", "127.0.0.1"],
        "all_ipv6_addresses": ["2001:db8::5"],
        "interfaces": ["br-ab12", "br-new", "eth0"],
        "br_ab12": {"ipv4": {"network": "198.51.100.0", "prefix": "24"}},
    }
    task = {
        "ansible.builtin.template": {"src": str(ROOT / "ansible/templates/tether.nft.j2"), "dest": str(out)},
        "vars": {"tether_uid": 995, "ansible_facts": facts},
    }
    play = tmp_path / "play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "tasks": [task]}]))
    proc = subprocess.run(
        ["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    text = out.read_text()
    assert "meta skuid != 995 return" in text
    assert "ip daddr 127.0.0.1 tcp dport 4000 accept" in text
    assert "ip daddr 198.51.100.0/24 drop" in text, "a bridge subnet is dropped"
    assert text.rstrip().endswith("}\n}"), "an interface with no fact does not break the render"
    if shutil.which("sudo") and shutil.which("nft"):
        check = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(out)], capture_output=True, text=True, check=False)
        assert check.returncode == 0, check.stderr
