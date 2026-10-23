"""A unit file with an unknown directive must fail CI: systemd skips it with a warning and exit 0 (fleet-ops#9967)."""

import fnmatch
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
    found += sorted(INSTALLED.glob("cua-agent-*"))
    found += sorted(INSTALLED.glob("tincan-listen-*"))
    return [path for path in found if path.is_file()]


@pytest.mark.parametrize("unit", unit_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_no_directive_starts_with_the_ignore_failure_dash(unit: Path) -> None:
    offenders = [line for line in unit.read_text().splitlines() if DASH_PREFIXED_KEY.match(line)]
    assert offenders == [], (
        f"{unit.relative_to(ROOT)}: {offenders}. The ignore-failure prefix goes after the '=' "
        "as ExecStart=-command, not in front of the key."
    )


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


CLAUDE_VPS_LISTENER = INSTALLED / "tincan-listen-claude-vps.service"
WORKSPACES = "/home/nish/workspaces"


def _listener_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in CLAUDE_VPS_LISTENER.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    return keys


def test_claude_vps_listener_restart_is_capped_and_pages() -> None:
    keys = _listener_keys()
    assert keys["Restart"] == ["on-failure"], "a clean exit must not restart, and a failure restarts only inside the start limit"
    interval = keys["StartLimitIntervalSec"][0]
    assert interval.endswith("min") and int(interval.removesuffix("min")) > 0, "a zero interval disables the start limit"
    burst = int(keys["StartLimitBurst"][0])
    restart = int(keys["RestartSec"][0])
    assert burst > 0
    assert burst * restart < int(interval.removesuffix("min")) * 60, "the limit must be reachable inside its interval"
    assert keys["OnFailure"] == ["fleet-unit-failed@%N.service"]


def test_claude_vps_listener_config_paths_are_read_only() -> None:
    keys = _listener_keys()
    writable = " ".join(keys["BindPaths"]).split()
    read_only = " ".join(keys["BindReadOnlyPaths"]).split()
    assert "ReadWritePaths" not in keys
    # The MCP config and the WorkingDirectory must sit under a read-only bind with no writable bind inside.
    mcp = re.search(r"--mcp-config (\S+)", keys["ExecStart"][0]).group(1)
    workdir = keys["WorkingDirectory"][0]
    for loaded in (mcp, workdir):
        assert any(loaded == ro or loaded.startswith(ro + "/") for ro in read_only), loaded
        assert not any(loaded == rw or loaded.startswith(rw + "/") for rw in writable), loaded
    assert WORKSPACES not in writable, "workspaces is read-only; only named sub-folders are writable"
    for rw in writable:
        if rw.startswith(WORKSPACES + "/"):
            assert not mcp.startswith(rw + "/") and not workdir.startswith(rw + "/")
    assert WORKSPACES in read_only


def test_claude_vps_listener_is_sandboxed_and_egress_capped() -> None:
    keys = _listener_keys()
    assert keys["ProtectSystem"] == ["strict"]
    assert keys["ProtectHome"] == ["tmpfs"]
    assert keys["NoNewPrivileges"] == ["yes"]
    families = set(keys["RestrictAddressFamilies"][0].split())
    assert families <= {"AF_UNIX", "AF_INET", "AF_INET6", "AF_NETLINK"}, families
    # Private and link-local ranges are closed; loopback stays open. The tailnet range is not capped here.
    denied = set(keys["IPAddressDeny"][0].split())
    allowed = set(keys["IPAddressAllow"][0].split())
    assert "any" not in denied, "the listener must still reach the public model API"
    assert {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"} <= denied
    assert allowed == {"localhost"}
    assert any("/srv/aiostreams" in v for v in keys["InaccessiblePaths"])
    for key in ("ProtectKernelTunables", "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock", "ProtectHostname", "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality"):
        assert keys[key] == ["yes"], key


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
        "-e", f"tether_cua_env={root}/cua.env",
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
    "Look for an enabled tether-agent unit",
    "Look for the tether Photon credentials file",
    "Look for the tether calendar credentials file",
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
    "Let the tether group read the calendar credentials file",
    "Render tether's Cua env file",
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
    calendar = tmp_path / "calendar.env"
    calendar.touch()
    extra = ("-e", f"tether_photon_env={photon}", "-e", f"tether_calendar_env={calendar}")
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


def test_tether_loads_all_environment_files() -> None:
    assert _tether_keys()["EnvironmentFile"] == [
        "-/etc/tether/tether.env",
        "-/etc/tether/photon.env",
        "-/etc/tether/calendar.env",
        "-/etc/tether/cua.env",
    ]


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


def test_tether_calendar_env_is_only_chowned_never_created() -> None:
    assert _host_var("tether_calendar_env") == "/etc/tether/calendar.env"
    users = [block for block in _tether_blocks() if "tether_calendar_env }}" in block and "ansible.builtin.stat:" not in block]
    assert len(users) == 1
    block = users[0]
    assert "ansible.builtin.file:" in block and "        state: file\n" in block
    assert "        owner: root\n        group: tether\n        mode: \"0640\"\n" in block
    assert "tether_calendar.stat.exists" in block, "a missing file must skip the task, not fail the run"
    assert 'ignore_errors: "{{ ansible_check_mode }}"' in block


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_calendar_env_task_waits_for_the_file(tmp_path: Path) -> None:
    name = "Let the tether group read the calendar credentials file"
    calendar = tmp_path / "calendar.env"
    # Photon's path is pointed away too: /etc/tether may not be readable here.
    extra = ("-e", f"tether_photon_env={tmp_path / 'photon.env'}", "-e", f"tether_calendar_env={calendar}")
    missing = _tether_tasks(tmp_path / "no-marker", extra=extra)
    assert missing[name].get("skipped"), "no file: nothing to do and nothing to fail"
    calendar.touch()
    present = _tether_tasks(tmp_path / "no-marker", extra=extra)
    assert not present[name].get("skipped")


def test_host_run_never_enables_or_starts_tether() -> None:
    blocks = re.split(r"\n    - name: ", (ROOT / "ansible/host.yml").read_text())
    tether = [block for block in blocks if "name: tether-agent.service" in block]
    assert tether, "the marker task is gone"
    restart = [block for block in tether if "state: restarted" in block]
    assert len(restart) <= 1
    for block in tether:
        assert "enabled: true" not in block and "state: started" not in block, block
        if block in restart:
            assert "tether_agent_enabled.stat.islnk" in block and "not tether_off.stat.exists" in block, block
        else:
            assert "when: tether_off.stat.exists" in block, block


def test_tether_release_change_restarts_an_enabled_agent() -> None:
    text = HOST_YML.read_text()
    link = [block for block in re.split(r"\n        - name: ", text) if block.startswith("Point tether current at the verified release")]
    assert len(link) == 1
    assert "notify: Restart tether-agent after its release changed" in link[0]
    lookup = [
        block
        for block in re.split(r"\n    - name: ", text.split("\n  handlers:", 1)[0])
        if block.startswith("Look for an enabled tether-agent unit")
    ]
    assert len(lookup) == 1
    assert "multi-user.target.wants/tether-agent.service" in lookup[0]
    assert "follow: false" in lookup[0]
    handler = [
        block
        for block in re.split(r"\n    - name: ", text.split("\n  handlers:", 1)[1])
        if block.startswith("Restart tether-agent after its release changed")
    ]
    assert len(handler) == 1
    assert "ansible.builtin.systemd_service:" in handler[0]
    assert "state: restarted" in handler[0]


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
    assert "4730" not in text and "dport {{" not in text, "no Cua port: tether reaches the daemon through a unix socket"
    assert "ip daddr 198.51.100.0/24 drop" in text, "a bridge subnet is dropped"
    assert text.rstrip().endswith("}\n}"), "an interface with no fact does not break the render"
    if shutil.which("sudo") and shutil.which("nft"):
        check = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(out)], capture_output=True, text=True, check=False)
        assert check.returncode == 0, check.stderr


CUA_SOCKET = INSTALLED / "cua-agent-tether.socket"
CUA_PROXY = INSTALLED / "cua-agent-tether.service"


def test_cua_agent_socket_admits_only_the_tether_group() -> None:
    keys = runner_dropin_keys(CUA_SOCKET)
    assert keys["ListenStream"] == ["/run/cua-agents/tether.sock"]
    assert keys["SocketUser"] == ["nish"] and keys["SocketGroup"] == ["tether"]
    assert keys["SocketMode"] == ["0660"], "owner and group, nobody else"
    # A 0750 root-owned parent keeps the tether user out; the socket's own mode is the gate.
    assert keys["DirectoryMode"] == ["0755"]
    assert keys["Accept"] == ["no"]


def test_cua_agent_proxy_is_the_stock_proxyd_as_the_daemon_user() -> None:
    keys = runner_dropin_keys(CUA_PROXY)
    assert keys["User"] == ["nish"], "the daemon's own socket is owner-only"
    assert keys["Requires"] == ["cua-agent-tether.socket"]
    (exec_start,) = keys["ExecStart"]
    assert "/usr/lib/systemd/systemd-socket-proxyd" in exec_start and '"$$HOME/.cua/cua.sock"' in exec_start
    assert "/home/" not in exec_start, "no literal home path: a system unit reads $HOME, which User= sets"
    assert keys["RestrictAddressFamilies"] == ["AF_UNIX"] and keys["IPAddressDeny"] == ["any"]
    assert keys["ProtectHome"] == ["read-only"], "the proxy must read the daemon's socket under the home"


def test_tether_reaches_the_cua_socket_and_the_daemon_is_not_reconfigured() -> None:
    keys = _tether_keys()
    assert "cua-agent-tether.socket" in keys["Wants"] and "cua-agent-tether.socket" in keys["After"] and "cua-agent-tether.socket" not in keys["Requires"]
    text = HOST_YML.read_text()
    block = [b for b in re.split(r"\n    - name: ", text) if b.startswith("Render tether's Cua env file")]
    assert len(block) == 1
    assert "owner: root\n        group: tether\n        mode: \"0640\"" in block[0]
    assert 'content: "TETHER_CUA_URL=/run/cua-agents/tether.sock\\n"' in block[0]
    assert "when: not tether_off.stat.exists" in block[0], "the off marker leaves tether no new file"
    assert "notify: Restart tether-agent after its release changed" in block[0]
    assert not (ROOT / "rootfs/etc/systemd/user/cua-desk-daemon.service.d").exists(), "the daemon keeps its own flags: no restart, no desk downtime"
    assert "/etc/systemd/user/cua-desk-daemon.service.d" in text.split("retired:", 1)[1].split("box_only_file", 1)[0]
    update = (ROOT / "ansible/update.yml").read_text()
    assert "cua_daemon_stale" not in update and "cua_daemon_unit" not in update


def test_unused_cua_token_files_are_removed_by_code() -> None:
    text = HOST_YML.read_text()
    for name, path in (
        ("Remove the unused Cua daemon token file", "/etc/fleet-ops/cua-daemon-token"),
        ("Remove the unused Cua daemon env directory", 'nish_config }}/fleet-ops/cua"'),
    ):
        block = [b for b in re.split(r"\n    - name: ", text) if b.startswith(name)]
        assert len(block) == 1, name
        assert path in block[0] and "state: absent" in block[0], name
    assert "lookup('ansible.builtin.password', cua" not in text


RUNNER_RULES = ROOT / "rootfs/etc/nftables.d/runners.nft"
NFT_CONF = ROOT / "rootfs/etc/nftables.conf"
RUNNER_CANARY = INSTALLED / "actions.runner.Nishfleet.netcup-fleet-ci-2.service.d/40-egress.conf"


def runner_rules() -> list[str]:
    return [line.strip() for line in RUNNER_RULES.read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]


def runner_dropin_keys(path: Path) -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        if line.strip() and not line.startswith(("#", "[")):
            key, _, value = line.partition("=")
            keys.setdefault(key, []).append(value)
    return keys


def test_runner_rule_matches_the_set_positively_and_never_destroys_it() -> None:
    lines = runner_rules()
    jump = "add rule inet runners output socket cgroupv2 level 2 @runner_cgroups jump runner_egress"
    assert jump in lines
    assert "add set inet runners runner_cgroups { type cgroupsv2; }" in lines
    assert not any(line.startswith("destroy") or "delete" in line for line in lines), "a reload must keep the set's elements"
    assert not any("!=" in line and "socket" in line for line in lines), "a negated cgroup match fails the wrong way"
    flush = [i for i, line in enumerate(lines) if line.startswith("flush chain inet runners")]
    first_rule = min(i for i, line in enumerate(lines) if line.startswith("add rule"))
    assert len(flush) == 2 and max(flush) < first_rule
    assert [line for line in lines if "hook" in line] == [
        "add chain inet runners output { type filter hook output priority filter; policy accept; }"
    ]


def test_runner_egress_chain_order() -> None:
    chain = [line.removeprefix("add rule inet runners runner_egress ") for line in runner_rules() if " runner_egress " in line and "jump" not in line]
    assert chain[0] == "ct state established,related return"
    assert chain.index("ip daddr 127.0.0.1 tcp dport 4000 return") < chain.index("fib daddr type local drop")
    assert chain.index("ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 return") < chain.index("fib daddr type local drop")
    first_drop = min(i for i, line in enumerate(chain) if line.endswith(" drop"))
    assert all(line.endswith(" return") for line in chain[:first_drop]), "every allow comes before the first drop"
    assert chain[-1] == "return"
    text = " ".join(chain)
    for dest in ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1", "fc00::/7", "fe80::/10", "fd7a:115c:a1e0::/48"):
        assert dest in text, dest


def test_canary_dropin_fills_the_set_and_denies_address_ranges() -> None:
    keys = runner_dropin_keys(RUNNER_CANARY)
    assert keys["NFTSet"] == ["cgroup:inet:runners:runner_cgroups"]
    deny = keys["IPAddressDeny"][0].split()
    cgnat = "100.64.0.0/10"  # gitleaks:allow
    for item in ("localhost", "link-local", "multicast", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", cgnat, "fd7a:115c:a1e0::/48", "fc00::/7"):
        assert item in deny, item
    assert keys["IPAddressAllow"] == ["127.0.0.1/32 127.0.0.53/32"]
    assert keys["After"] == ["nftables.service"] and keys["Wants"] == ["nftables.service"]
    assert "Requires" not in keys
    assert re.fullmatch(r"actions\.runner\.[A-Za-z0-9.-]+\.service\.d", RUNNER_CANARY.parent.name)


def test_stage_one_is_the_canary_only() -> None:
    with_nftset = sorted(p.parent.name for p in INSTALLED.glob("*/*.conf") if "NFTSet=" in "\n".join(l for l in p.read_text().splitlines() if not l.startswith("#")))
    assert with_nftset == [RUNNER_CANARY.parent.name]


def test_host_yml_installs_the_rules_with_a_check_validate() -> None:
    text = (ROOT / "ansible/host.yml").read_text()
    block = text[text.index("- name: Install the runner egress rule"):]
    block = block[: block.index("\n    - name:", 10)]
    assert "dest: /etc/nftables.d/runners.nft" in block
    assert "validate: /usr/sbin/nft -c -f %s" in block
    assert "notify: Reload nftables" in block
    assert "systemd_service" not in block, "no unit start in the host run"


@pytest.mark.skipif(not (shutil.which("sudo") and shutil.which("nft")), reason="sudo and nft are needed")
def test_nft_check_accepts_the_rules_and_the_full_conf(tmp_path: Path) -> None:
    probe = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(RUNNER_RULES)], capture_output=True, text=True, check=False)
    if probe.returncode != 0 and ("ermission" in probe.stderr or "sudo:" in probe.stderr):
        pytest.skip("no CAP_NET_ADMIN or sudo here")
    assert probe.returncode == 0, probe.stderr
    full = tmp_path / "nftables.conf"
    full.write_text(NFT_CONF.read_text().replace("/etc/nftables.d/", f"{RUNNER_RULES.parent}/"))
    check = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(full)], capture_output=True, text=True, check=False)
    assert check.returncode == 0, check.stderr


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_accepts_the_dropin_on_a_stand_in(tmp_path: Path) -> None:
    (tmp_path / "standin.service").write_text("[Service]\nExecStart=/usr/bin/true\n")
    (tmp_path / "standin.service.d").mkdir()
    (tmp_path / "standin.service.d/40-egress.conf").write_text(RUNNER_CANARY.read_text())
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", "./standin.service"], cwd=tmp_path, capture_output=True, text=True, check=False
    )
    out = proc.stdout + proc.stderr
    assert "Unknown key" not in out and "Unknown section" not in out and "Failed to parse" not in out, out


TMPFILES = ROOT / "rootfs/etc/tmpfiles.d"
RUNNER_DROPINS = sorted(INSTALLED.glob("actions.runner.*.service.d"))
CREATING_TYPES = {"d", "D", "f", "F", "L"}
RUN_PATH_ALLOWLIST = {
    "/run/docker.sock": "created by docker.socket (enabled, started at sockets.target, before the runners)",
    "/run/user/1000": "the user runtime dir comes from logind (linger), before the runners",
    "/run/user/1000/*": "entries of the user runtime dir; the dir itself comes from logind (linger)",
    "/run/podman-eval": "retired path, kept masked",
}


def _run_norm(path: str) -> str:
    path = path.rstrip("/") or "/"
    return "/run" + path[len("/var/run"):] if path == "/var/run" or path.startswith("/var/run/") else path


def tmpfiles_created(tmpfiles_dir: Path) -> set[str]:
    created = set()
    for conf in sorted(tmpfiles_dir.glob("*.conf")):
        for line in conf.read_text().splitlines():
            fields = line.split()
            if len(fields) >= 2 and not line.lstrip().startswith("#") and fields[0].rstrip("+!-=~^") in CREATING_TYPES:
                created.add(_run_norm(fields[1]))
    return created


def runner_mask_paths(dropin: Path) -> list[str]:
    """Every InaccessiblePaths= entry of one drop-in without its "-"/"+" prefixes; ValueError when empty or unparsable."""
    paths: list[str] = []
    lines = dropin.read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line.startswith("InaccessiblePaths="):
            continue
        value = line.removeprefix("InaccessiblePaths=")
        while value.endswith("\\") and i < len(lines):
            value = value[:-1] + " " + lines[i].strip()
            i += 1
        try:
            tokens = shlex.split(value)
        except ValueError as err:
            raise ValueError(f"{dropin}: unparsable InaccessiblePaths= line {line!r}: {err}") from err
        if not tokens:
            raise ValueError(f"{dropin}: empty InaccessiblePaths= line (it would reset the mask list)")
        for token in tokens:
            path = token.lstrip("-+")
            if not path.startswith("/") or path == "/":
                raise ValueError(f"{dropin}: unparsable InaccessiblePaths= entry {token!r}")
            paths.append(path)
    return paths


def unguarded_run_paths(dropin_dirs: list[Path], tmpfiles_dir: Path, allowlist: dict[str, str]) -> list[str]:
    """Masked /run paths with neither a boot-time creator nor an allowlist entry; ValueError when a mask list is empty."""
    created = tmpfiles_created(tmpfiles_dir)
    bad = []
    for directory in dropin_dirs:
        paths = [path for conf in sorted(directory.glob("*.conf")) for path in runner_mask_paths(conf)]
        if not paths:
            raise ValueError(f"{directory}: no InaccessiblePaths= entry in any drop-in")
        for path in paths:
            norm = _run_norm(path)
            if (norm == "/run" or norm.startswith("/run/")) and norm not in created:
                if not any(fnmatch.fnmatchcase(norm, pattern) for pattern in allowlist):
                    bad.append(f"{directory.name}: {path}")
    return bad


def test_every_masked_run_path_has_a_boot_time_creator() -> None:
    assert len(RUNNER_DROPINS) >= 5, "the runner drop-in directories were not found"
    assert unguarded_run_paths(RUNNER_DROPINS, TMPFILES, RUN_PATH_ALLOWLIST) == []


def test_run_path_allowlist_has_no_stale_entry() -> None:
    masked = {_run_norm(path) for d in RUNNER_DROPINS for conf in d.glob("*.conf") for path in runner_mask_paths(conf)}
    created = tmpfiles_created(TMPFILES)
    for pattern, reason in RUN_PATH_ALLOWLIST.items():
        assert reason.strip()
        assert any(fnmatch.fnmatchcase(path, pattern) for path in masked), f"{pattern} is masked by no runner"
        assert pattern not in created, f"{pattern} has a tmpfiles creator, drop it from the allowlist"
    assert "/run/dockerd-eval" in created and "/run/dockerd-eval" in masked


def _fixture(tmp_path: Path, mask: str, tmpfiles: str = "") -> tuple[list[Path], Path]:
    dropin = tmp_path / "actions.runner.X.service.d"
    dropin.mkdir()
    (dropin / "20-lockdown.conf").write_text(mask)
    tmpdir = tmp_path / "tmpfiles.d"
    tmpdir.mkdir()
    (tmpdir / "x.conf").write_text(tmpfiles)
    return [dropin], tmpdir


def test_run_path_check_fails_on_a_path_with_no_creator(tmp_path: Path) -> None:
    dirs, tmpdir = _fixture(tmp_path, "[Service]\nInaccessiblePaths=-/etc/example -/run/new-thing\n", "d /run/other 0700 nish nish -\n")
    assert unguarded_run_paths(dirs, tmpdir, {}) == ["actions.runner.X.service.d: /run/new-thing"]
    assert unguarded_run_paths(dirs, tmpdir, {"/run/new-thing": "test"}) == []


def test_run_path_check_accepts_a_creator_and_normalises_var_run(tmp_path: Path) -> None:
    mask = "[Service]\nInaccessiblePaths=-/run/a\nInaccessiblePaths=+/var/run/b -/run/c\n"
    tmpfiles = "# d /run/c\nd /run/a 0755 - - -\nf+ /run/b 0600 - - -\nz /run/c\n"
    dirs, tmpdir = _fixture(tmp_path, mask, tmpfiles)
    assert unguarded_run_paths(dirs, tmpdir, {}) == ["actions.runner.X.service.d: /run/c"]


def test_run_path_check_reads_every_line_and_prefix(tmp_path: Path) -> None:
    mask = "[Service]\nInaccessiblePaths=-/etc/a \\\n  -/run/x\nInaccessiblePaths=/run/y +/run/z\n"
    dirs, tmpdir = _fixture(tmp_path, mask)
    assert runner_mask_paths(dirs[0] / "20-lockdown.conf") == ["/etc/a", "/run/x", "/run/y", "/run/z"]
    assert len(unguarded_run_paths(dirs, tmpdir, {})) == 3


@pytest.mark.parametrize(
    "mask",
    ["[Service]\n", "[Service]\nInaccessiblePaths=\n", "[Service]\nInaccessiblePaths=-run/x\n", "[Service]\nInaccessiblePaths='-/run/x\n"],
    ids=["no-line", "empty-line", "relative-path", "bad-quote"],
)
def test_run_path_check_cannot_pass_vacuously(tmp_path: Path, mask: str) -> None:
    dirs, tmpdir = _fixture(tmp_path, mask)
    with pytest.raises(ValueError):
        unguarded_run_paths(dirs, tmpdir, RUN_PATH_ALLOWLIST)


# Units whose output files hold agent session text. The user manager default is
# UMask=0002, so each one needs a drop-in that makes new files owner-only.
PRIVATE_FILE_WRITER_DROPINS = ("systemd/leviathan-index@.service.d",)


@pytest.mark.parametrize("dropin_dir", PRIVATE_FILE_WRITER_DROPINS)
def test_index_writer_dropin_sets_owner_only_umask(dropin_dir: str) -> None:
    dropin = ROOT / dropin_dir / "20-umask.conf"
    assert dropin.is_file(), f"{dropin_dir}/20-umask.conf is missing"
    lines = [line.strip() for line in dropin.read_text().splitlines()]
    assert "[Service]" in lines
    assert [line for line in lines if line.startswith("UMask=")] == ["UMask=0077"]
    unit = ROOT / dropin_dir.removesuffix(".d")
    assert not [line for line in unit.read_text().splitlines() if line.startswith("UMask=")], (
        f"{unit.name} sets UMask itself; keep it in the drop-in only"
    )


CF_TOKENS_UNIT = ROOT / "systemd/cloudflare-tokens-apply.service"
CF_TOKENS_ENCRYPTION_EXAMPLE = ROOT / "infra/cloudflare-tokens/state-encryption.env.example"


def test_cloudflare_tokens_unit_loads_the_state_key_file_optionally_and_never_inline() -> None:
    text = CF_TOKENS_UNIT.read_text()
    files = [line.split("=", 1)[1] for line in text.splitlines() if line.startswith("EnvironmentFile=")]
    assert "-%h/.config/cloudflare/tofu-state-encryption.env" in files
    assert "TF_ENCRYPTION" not in text and "passphrase" not in text.lower(), "the key and method belong in the private file only"


def test_cloudflare_tokens_state_key_example_is_a_template_with_no_real_passphrase() -> None:
    lines = [line for line in CF_TOKENS_ENCRYPTION_EXAMPLE.read_text().splitlines() if line and not line.startswith("#")]
    assert len(lines) == 1 and lines[0].startswith("TF_ENCRYPTION={")
    assert "PASTE_THE_GENERATED_PASSPHRASE_HERE" in lines[0]
