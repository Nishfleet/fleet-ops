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
    found += sorted(INSTALLED.glob("fleet-host-config*"))
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
    "Remove tether's Cua Space env file while the marker exists",
    "Remove the retired Cua daemon token file",
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
    "Render tether's Cua Space env file",
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
    extra = (
        "-e", f"tether_photon_env={photon}", "-e", f"tether_calendar_env={calendar}",
        "-e", f"tether_cua_env={tmp_path / 'cua.env'}", "-e", "tether_space_port=40001", "-e", "tether_space_token=" + "a" * 32,
    )
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
    assert not off["Remove tether's Cua Space env file while the marker exists"].get("skipped")
    assert on["Remove tether's Cua Space env file while the marker exists"].get("skipped")
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


def _render_tether_nft(tmp_path: Path, name: str, extra_vars: dict, template: str = "tether.nft.j2") -> str:
    out = tmp_path / name
    facts = {
        "all_ipv4_addresses": ["192.0.2.5", "127.0.0.1"],
        "all_ipv6_addresses": ["2001:db8::5"],
        "interfaces": ["br-ab12", "br-new", "eth0"],
        "br_ab12": {"ipv4": {"network": "198.51.100.0", "prefix": "24"}},
    }
    task = {
        "ansible.builtin.template": {"src": str(ROOT / "ansible/templates" / template), "dest": str(out)},
        "vars": {"tether_uid": 995, "ansible_facts": facts, **extra_vars},
    }
    play = tmp_path / f"{name}.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "tasks": [task]}]))
    proc = subprocess.run(
        ["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return out.read_text()


def _nft_check(path: Path) -> None:
    if shutil.which("sudo") and shutil.which("nft"):
        check = subprocess.run(["sudo", "-n", "nft", "-c", "-f", str(path)], capture_output=True, text=True, check=False)
        assert check.returncode == 0, check.stderr


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_nft_template_renders_and_loads(tmp_path: Path) -> None:
    text = _render_tether_nft(tmp_path, "tether.nft", {})
    assert "meta skuid != 995 return" in text
    assert "ip daddr 127.0.0.1 tcp dport 4000 accept" in text
    assert "tcp dport 4000 accept" in text and text.count("127.0.0.1 tcp dport") == 1, "no Space port is known: the router port is the only loopback port"
    assert "ip daddr 198.51.100.0/24 drop" in text, "a bridge subnet is dropped"
    assert text.rstrip().endswith("}\n}"), "an interface with no fact does not break the render"
    _nft_check(tmp_path / "tether.nft")


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_nft_allows_exactly_the_spaces_port_before_the_loopback_drop(tmp_path: Path) -> None:
    text = _render_tether_nft(tmp_path, "with-port.nft", {"tether_space_port": "32786"})
    rule = "ip daddr 127.0.0.1 tcp dport 32786 accept"
    lines = [line.strip() for line in text.splitlines()]
    assert lines.count(rule) == 1
    assert lines.index("ip daddr 127.0.0.1 tcp dport 4000 accept") < lines.index(rule) < lines.index("ip daddr 127.0.0.0/8 drop")
    assert text.count("127.0.0.1 tcp dport") == 2, "the router and the one Space port"
    other = _render_tether_nft(tmp_path, "other-port.nft", {"tether_space_port": 32791})
    assert "tcp dport 32791 accept" in other and "tcp dport 32786" not in other, "the rule follows the port it is given"
    _nft_check(tmp_path / "with-port.nft")


SPACE_NFT = "tether-space.nft.j2"


def _nft_chains(text: str) -> dict[str, list[str]]:
    chains: dict[str, list[str]] = {}
    current = None
    for line in (line.strip() for line in text.splitlines()):
        if line.startswith(("chain ", "table ")):
            current = line.rstrip(" {")
            chains[current] = []
        elif current and line not in ("", "}") and not line.startswith("#"):
            chains[current].append(line)
    return chains


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_space_fence_drops_private_ranges_from_the_space_and_allows_the_internet(tmp_path: Path) -> None:
    text = _render_tether_nft(tmp_path, "fence.nft", {"tether_space_ip": "172.17.0.3"}, SPACE_NFT)
    space = "ip saddr 172.17.0.3"
    chains = _nft_chains(text)
    assert {"table inet tether_space", "table bridge tether_space"} <= set(chains)
    assert "hook input" in text and text.count("hook forward") == 2, "input, inet forward and bridge forward"
    assert chains["chain space_input"][1:] == [f"{space} ct state established,related accept", f"{space} drop"], "replies pass, nothing else reaches the host"
    forward = chains["chain space_forward"]
    assert forward[1] == f"{space} ct state established,related accept"
    drops = [line for line in forward if line.endswith("drop")]
    assert all(line.startswith(space) for line in drops), "every drop is from the Space's source address"
    joined = " ".join(drops)
    for private in ("10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "0xffc00000 == 0x64400000"):
        assert private in joined, private
    assert not any(line.endswith("accept") and "daddr" in line for line in forward), "no destination is allowed: the internet is the default"
    assert text.count("policy accept") == 3 and "policy drop" not in text, "everything not named stays open"
    assert chains["chain forward"][1:] == [f"{space} ct state established,related accept", f"{space} drop"], "a neighbour container is out of reach"
    assert text.index("destroy table bridge tether_space") < text.index("table bridge tether_space {")
    assert text.index("destroy table inet tether_space") < text.index("table inet tether_space {")
    assert "tether_uid" not in text and "skuid" not in text, "the fence does not depend on tether's uid or marker"
    other = _render_tether_nft(tmp_path, "fence-other.nft", {"tether_space_ip": "172.18.0.9"}, SPACE_NFT)
    assert "172.17.0.3" not in other and "ip saddr 172.18.0.9 drop" in other, "the fence follows the address it is given"
    _nft_check(tmp_path / "fence.nft")


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_tether_rule_has_no_fence_and_the_fence_file_is_not_removed_by_any_task(tmp_path: Path) -> None:
    text = _render_tether_nft(tmp_path, "tether.nft", {"tether_space_port": 32786, "tether_space_ip": "172.17.0.3"})
    assert "saddr" not in text and "bridge" not in text, "tether.nft, which the marker removes, holds no fence"
    for task in _play_tasks():
        for inner in [task] + task.get("block", []) + task.get("rescue", []):
            file = inner.get("ansible.builtin.file", {})
            assert file.get("path") != "{{ tether_space_nft }}" and "tether-space" not in str(file.get("path")), inner["name"]
    assert _host_var("tether_space_nft") == "/etc/nftables.d/tether-space.nft"
    assert "tether-space.nft" not in "".join(_play_tasks_text_for_removals()), "nothing deletes it by name"


def _play_tasks_text_for_removals() -> list[str]:
    out = []
    for task in _play_tasks():
        for inner in [task] + task.get("block", []) + task.get("rescue", []):
            if inner.get("ansible.builtin.file", {}).get("state") == "absent":
                out.append(json.dumps(inner))
    return out


CUA_DROPIN_DIR = "etc/systemd/user/cua-desk-daemon.service.d"


def test_cua_fixed_port_route_is_retired_and_nothing_restarts_the_daemon_for_config() -> None:
    assert not (ROOT / "rootfs" / CUA_DROPIN_DIR).exists(), "the fixed-port drop-in is gone from the repo"
    host = HOST_YML.read_text()
    update = (ROOT / "ansible/update.yml").read_text()
    assert f"- /{CUA_DROPIN_DIR}\n" in host.split("    retired:\n", 1)[1].split("    # Files kept off GitHub", 1)[0], "host.yml deletes it on the host"
    assert "cua_daemon_port" not in host + update + (ROOT / "ansible/templates/tether.nft.j2").read_text()
    assert "cua_daemon_stale" not in update and "cua_daemon_unit" not in update, "no config-triggered daemon restart"
    assert 'cua_upgrade: "{{ cua_newer and (cua_runs.stdout' in update, "the desk is recreated only for a newer release"
    assert "rejectattr('status', 'equalto', 'idle') | list | length == 0) }}" in update, "idle only"


def test_cua_leftovers_are_removed_by_name_and_the_nish_tasks_stay_off_the_tether_tag() -> None:
    blocks = {b.split("\n", 1)[0]: b for b in re.split(r"\n    - name: ", HOST_YML.read_text())}
    by_path = {
        "/etc/fleet-ops/cua-daemon-token": "Remove the retired Cua daemon token file",
        '{{ nish_config }}/fleet-ops/cua/daemon.env': "Remove the retired Cua daemon env file",
    }
    for path, name in by_path.items():
        block = blocks[name]
        assert f"path: {path if path.startswith('/') else chr(34) + path + chr(34)}\n        state: absent" in block, name
        # CI runs `--tags tether --check` as an unprivileged user: a task that
        # becomes nish and carries the tag fails there.
        assert ("become_user: nish" in block) != ("tags: [tether]" in block), name
    rmdir = blocks["Remove the retired Cua daemon env directory when it is empty"]
    assert 'argv: [rmdir, "{{ nish_config }}/fleet-ops/cua"]' in rmdir and "LC_ALL: C" in rmdir
    assert "tags:" not in rmdir and "become_user: nish" in rmdir
    assert "'Directory not empty' not in" in rmdir and "'No such file or directory' not in" in rmdir


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
PRIVATE_FILE_WRITER_DROPINS = ("systemd/leviathan-index@.service.d", "systemd/tincan-listen-devin-vps.service.d")


@pytest.mark.parametrize("dropin_dir", PRIVATE_FILE_WRITER_DROPINS)
def test_index_writer_dropin_sets_owner_only_umask(dropin_dir: str) -> None:
    dropin = ROOT / dropin_dir / "20-umask.conf"
    assert dropin.is_file(), f"{dropin_dir}/20-umask.conf is missing"
    lines = [line.strip() for line in dropin.read_text().splitlines()]
    assert "[Service]" in lines
    assert [line for line in lines if line.startswith("UMask=")] == ["UMask=0077"]
    unit = ROOT / dropin_dir.removesuffix(".d")
    # The Devin listener unit is hand-placed on the host (no repo copy), so only its drop-in is here.
    if unit.is_file():
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


SPACE_TOKEN = "Tk3-" + "x" * 28
CONTAINER_ID = "ab" * 32


def _host_task(name: str) -> dict:
    return next(task for task in _play_tasks() if task.get("name") == name)


def _space_block() -> dict:
    return _host_task("Ready tether's own Cua Space, or record why it failed")


def _space_ls(state: str | None) -> str:
    rows = [{"id": "local:desk", "state": "running", "status": "ready"}]
    if state is not None:
        rows.append({"id": "local:tether", "state": state, "status": "ready"})
    return json.dumps(rows)


def _unprivileged(task: dict) -> dict:
    """The tests run as the current user: no root owner on the rendered file."""
    task = dict(task)
    task.pop("become_user", None)
    if "ansible.builtin.template" in task:
        task["ansible.builtin.template"] = {k: v for k, v in task["ansible.builtin.template"].items() if k not in ("owner", "group")}
    return task


def _run_space_tasks(
    tmp_path: Path, state: str | None, port: int = 32791, space_ip: str = "172.17.0.3", restart: str = "no", ip6: str = "", expect_ok: bool = True
) -> tuple[list[str], str]:
    log = tmp_path / "calls.log"
    log.write_text("")
    (tmp_path / "ls.json").write_text(_space_ls(state))
    (tmp_path / "token").write_text(SPACE_TOKEN + "\n")
    (tmp_path / "info.json").write_text(
        json.dumps({"endpoints": {"env": f"http://127.0.0.1:{port}"}, "state": "running", "provider_details": {"container_id": CONTAINER_ID}})
    )
    docker = tmp_path / "docker"
    docker.write_text(
        "#!/bin/sh\n"
        f'echo "docker $*" >> {shlex.quote(str(log))}\n'
        f'[ "$1 $2" = "inspect --format" ] && [ "$4" = {CONTAINER_ID} ] && cat {shlex.quote(str(tmp_path / "inspect.json"))}\n'
    )
    (tmp_path / "inspect.json").write_text(
        json.dumps({"restart": restart, "networks": {"bridge": {"IPAddress": space_ip, "GlobalIPv6Address": ip6}}})
    )
    nft = tmp_path / "nft"
    nft.write_text("#!/bin/sh\n" f'echo "nft $*" >> {shlex.quote(str(log))}\n')
    nft.chmod(0o755)
    fence = tmp_path / "tether-space.nft"
    if not fence.exists():
        fence.write_text("# previous fence\n")
    docker.chmod(0o755)
    stub = tmp_path / "cua"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "$*" >> {shlex.quote(str(log))}\n'
        'case "$*" in\n'
        f'"sandbox ls --local --json --no-size") cat {shlex.quote(str(tmp_path / "ls.json"))};;\n'
        '"spaces create "*|"spaces start "*) ;;\n'
        f'"--embedded sandbox exec local:tether cat /run/cua/env-token") cat {shlex.quote(str(tmp_path / "token"))};;\n'
        f'"--embedded sandbox info local:tether --json") cat {shlex.quote(str(tmp_path / "info.json"))};;\n'
        "*) exit 2;;\nesac\n"
    )
    stub.chmod(0o755)
    facts = tmp_path / "facts.txt"
    tasks = [_unprivileged(dict(task, retries=0, delay=0) if "retries" in task else task) for task in _space_block()["block"]] + [
        {"ansible.builtin.copy": {"content": "{{ tether_space_port }} {{ tether_space_ip }} {{ tether_space_token }}", "dest": str(facts)}}
    ]
    vars_ = {
        "cua_cli": str(stub), "docker_cli": str(docker), "nft_cli": str(nft), "tether_space_nft": str(fence),
        "tether_space_nft_src": str(ROOT / "ansible/templates" / SPACE_NFT), "tether_space_name": "tether", "tether_space_ref": "local:tether",
    }
    play = tmp_path / "space-play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "vars": vars_, "tasks": tasks}]))
    proc = subprocess.run(["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False)
    if not expect_ok:
        assert proc.returncode != 0, "the step must fail loudly"
        return log.read_text().splitlines(), ""
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert SPACE_TOKEN not in proc.stdout + proc.stderr, "the token never reaches the run output"
    return log.read_text().splitlines(), facts.read_text()


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_an_existing_running_space_is_neither_recreated_nor_started(tmp_path: Path) -> None:
    calls, facts = _run_space_tasks(tmp_path, "running")
    assert not [c for c in calls if c.startswith("spaces ")], calls
    assert facts == f"32791 172.17.0.3 {SPACE_TOKEN}"
    assert any(c.startswith("docker inspect --format") and c.endswith(CONTAINER_ID) for c in calls)
    fence = (tmp_path / "tether-space.nft").read_text()
    assert "ip saddr 172.17.0.3 drop" in fence, "the fence is rendered from the address Docker reports"
    assert f"nft -f {tmp_path / 'tether-space.nft'}" in calls, "and loaded"
    assert calls.index(f"nft -f {tmp_path / 'tether-space.nft'}") < calls.index("--embedded sandbox exec local:tether cat /run/cua/env-token"), "before the token read"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
@pytest.mark.parametrize("state", ["stopped", "suspended"])
def test_an_existing_space_that_is_not_running_is_started_never_recreated(tmp_path: Path, state: str) -> None:
    calls, facts = _run_space_tasks(tmp_path, state, port=32795)
    assert "spaces start local:tether" in calls
    assert not [c for c in calls if c.startswith("spaces create")], calls
    assert facts == f"32795 172.17.0.3 {SPACE_TOKEN}", "the port is the one Docker publishes now"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_a_missing_space_is_created_once_on_this_computer(tmp_path: Path) -> None:
    calls, _ = _run_space_tasks(tmp_path, None)
    assert calls.count("spaces create linux --name tether --on local") == 1
    assert not [c for c in calls if c.startswith("spaces start")], calls


def test_space_tasks_run_as_nish_stay_off_the_tether_tag_and_respect_the_marker() -> None:
    block = _space_block()
    assert block["become"] is True and block["become_user"] == "nish" and block["environment"] == "{{ nish_env }}"
    assert block["when"] == "not tether_off.stat.exists"
    assert "tags" not in block and not any("tags" in task for task in block["block"])
    assert "no_log" not in block and "ignore_errors" not in block, "a failure must reach the rescue"
    facts = [task["ansible.builtin.set_fact"] for task in block["rescue"] if "ansible.builtin.set_fact" in task]
    assert [list(fact) for fact in facts] == [["tether_space_failure"]]
    names = [task["name"] for task in block["block"]]
    assert names.index("Wait until the Cua daemon answers") < names.index("Create tether's Cua Space when it does not exist")
    for task in block["block"]:
        argv = task.get("ansible.builtin.command", {}).get("argv", [])
        assert "delete" not in argv and "rm" not in argv, "nothing here deletes a Space"
        if "--embedded" in argv:
            assert argv[1] == "--embedded"
    secret = [task for task in block["block"] if "tether_space_token" in json.dumps(task) or "tether_space_token_out" in json.dumps(task)]
    assert secret and all(task.get("no_log") is True for task in secret), [task["name"] for task in secret]


def test_space_env_task_is_private_no_log_and_restarts_tether() -> None:
    task = _host_task("Render tether's Cua Space env file")
    copy = task["ansible.builtin.copy"]
    assert copy["content"] == "TETHER_SPACE_URL=http://127.0.0.1:{{ tether_space_port }}\nTETHER_SPACE_TOKEN={{ tether_space_token }}\n"
    assert (copy["dest"], copy["owner"], copy["group"], copy["mode"]) == ("{{ tether_cua_env }}", "root", "tether", "0640")
    assert task["no_log"] is True and task["diff"] is False
    assert task["notify"] == "Restart tether-agent after its release changed"
    assert task["tags"] == ["tether"]
    assert task["when"] == "not tether_off.stat.exists and tether_space_port is defined and tether_space_token is defined"
    assert _host_var("tether_cua_env") == "/etc/tether/cua.env"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_space_env_task_renders_the_address_and_token(tmp_path: Path) -> None:
    task = dict(_host_task("Render tether's Cua Space env file"))
    copy = dict(task["ansible.builtin.copy"])
    dest = tmp_path / "cua.env"
    copy.update(dest=str(dest), mode="0640")
    copy.pop("owner")
    copy.pop("group")
    for key in ("tags", "notify", "ignore_errors"):
        task.pop(key, None)
    task["ansible.builtin.copy"] = copy
    play = tmp_path / "env-play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "vars": {
        "tether_off": {"stat": {"exists": False}}, "tether_space_port": 32791, "tether_space_token": SPACE_TOKEN,
    }, "tasks": [task]}]))
    proc = subprocess.run(["ansible-playbook", "-c", "local", "-i", "localhost,", "--diff", str(play)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert dest.read_text() == f"TETHER_SPACE_URL=http://127.0.0.1:32791\nTETHER_SPACE_TOKEN={SPACE_TOKEN}\n"
    assert oct(dest.stat().st_mode & 0o777) == "0o640"
    assert SPACE_TOKEN not in proc.stdout + proc.stderr, "no_log and diff: false keep the token out of the run output"


def test_space_failure_fails_closed_and_fails_the_run_late() -> None:
    nft = _host_task("Install the tether egress rule")
    assert "tether_space_failure" not in nft["when"], "a failed Space step still renders the rule, without the Space port"
    assert "tether_space_port" not in nft["when"] and "tether_space_ip" not in nft["when"]
    names = [task["name"] for task in _play_tasks()]
    fail = names.index("Fail when tether's Cua Space could not be readied")
    assert names.index("Ready tether's own Cua Space, or record why it failed") < names.index("Render tether's Cua Space env file") < fail
    assert names.index("Install the tether egress rule") < fail
    assert fail < names.index("Apply pending handlers before the tether failure check"), "the page comes before the final handler flush"
    # The port and token are set by the last task of the block only, so a failure leaves neither defined.
    block = _space_block()["block"]
    keep = block[-1]
    assert keep["name"] == "Keep the address and token of tether's Cua Space"
    assert {"tether_space_port", "tether_space_token"} == set(keep["ansible.builtin.set_fact"])
    for task in block[:-1]:
        assert not {"tether_space_port", "tether_space_token"} & set(task.get("ansible.builtin.set_fact", {})), task["name"]


def test_the_fence_is_rendered_inside_the_block_after_the_address_and_before_the_token() -> None:
    block = _space_block()["block"]
    names = [task["name"] for task in block]
    inspect = names.index("Read the network and restart policy of tether's Cua Space container")
    render = names.index("Render the fence around tether's Cua Space")
    load = names.index("Load the fence around tether's Cua Space")
    token = names.index("Read tether's Cua Space token, which also waits until the Space answers")
    assert inspect < names.index("Keep the address of tether's Cua Space container") < render < load < token
    task = block[render]
    assert task["become_user"] == "root" and "tags" not in task
    assert task["ansible.builtin.template"]["src"] == "{{ tether_space_nft_src }}" and task["ansible.builtin.template"]["dest"] == "{{ tether_space_nft }}"
    assert "when" not in task and "when" not in block[load], "no marker or tether condition on the fence"
    assert _space_block()["when"] == "not tether_off.stat.exists"
    assert "tether_space_ip" in json.dumps(block[names.index("Keep the address of tether's Cua Space container")])
    assert block[names.index("Read tether's Cua Space address")]["no_log"] is True


def test_the_marker_stops_the_space_and_leaves_the_fence() -> None:
    stop = _host_task("Stop tether's Cua Space while the tether marker exists")
    assert stop["ansible.builtin.command"]["argv"] == ["{{ cua_cli }}", "spaces", "stop", "{{ tether_space_ref }}"]
    assert stop["become_user"] == "nish" and "tags" not in stop
    assert "tether_off.stat.exists" in stop["when"]
    assert any("== 'running'" in cond for cond in stop["when"])
    assert _host_task("List the Cua Spaces while the tether marker exists")["when"] == "tether_off.stat.exists"
    # The marker removes tether.nft and never the fence.
    remove = _host_task("Remove the tether egress rule while the marker exists")
    assert remove["ansible.builtin.file"]["path"] == "/etc/nftables.d/tether.nft" and remove["when"] == "tether_off.stat.exists"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
@pytest.mark.parametrize("state, stops", [("running", True), ("stopped", False), (None, False)])
def test_with_the_marker_the_space_is_stopped_and_the_fence_file_is_untouched(tmp_path: Path, state: str | None, stops: bool) -> None:
    log = tmp_path / "calls.log"
    log.write_text("")
    (tmp_path / "ls.json").write_text(_space_ls(state))
    stub = tmp_path / "cua"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "$*" >> {shlex.quote(str(log))}\n'
        f'[ "$*" = "sandbox ls --local --json --no-size" ] && cat {shlex.quote(str(tmp_path / "ls.json"))}\n'
        "exit 0\n"
    )
    stub.chmod(0o755)
    fence = tmp_path / "tether-space.nft"
    fence.write_text("# kept\n")
    tasks = []
    for name in ("List the Cua Spaces while the tether marker exists", "Stop tether's Cua Space while the tether marker exists"):
        task = dict(_host_task(name))
        for key in ("become", "become_user", "environment"):
            task.pop(key, None)
        tasks.append(task)
    play = tmp_path / "marker-play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "vars": {
        "cua_cli": str(stub), "tether_space_ref": "local:tether", "tether_off": {"stat": {"exists": True}}}, "tasks": tasks}]))
    proc = subprocess.run(["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert ("spaces stop local:tether" in log.read_text().splitlines()) is stops
    assert fence.read_text() == "# kept\n"


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
@pytest.mark.parametrize(
    "kwargs",
    [{"restart": "always"}, {"restart": "unless-stopped"}, {"ip6": "2001:db8::3"}, {"space_ip": ""}],
    ids=["restart-always", "restart-unless-stopped", "ipv6", "no-address"],
)
def test_a_space_that_breaks_the_fence_assumptions_fails_loudly_and_leaves_the_fence(tmp_path: Path, kwargs: dict) -> None:
    (tmp_path / "tether-space.nft").write_text("# previous fence\n")
    calls, _ = _run_space_tasks(tmp_path, "running", expect_ok=False, **kwargs)
    assert (tmp_path / "tether-space.nft").read_text() == "# previous fence\n", "the last rendered fence stays"
    assert not [c for c in calls if c.startswith("nft ")], "and nothing is loaded"
    assert not [c for c in calls if "env-token" in c], "the token is never read after a bad network"


def test_space_waits_stay_well_inside_the_deploy_job_budget() -> None:
    total = 0
    for task in _space_block()["block"]:
        total += int(task.get("retries", 0)) * int(task.get("delay", 5))
    assert 0 < total <= 120, total


@pytest.mark.skipif(shutil.which("ansible-playbook") is None, reason="ansible-playbook is not installed")
def test_a_failed_space_step_defines_no_port_or_address_and_renders_no_allow(tmp_path: Path) -> None:
    tasks = []
    for task in _space_block()["block"]:
        task = _unprivileged(task)
        if "retries" in task:
            task["retries"], task["delay"] = 0, 0
        tasks.append(task)
    fence = tmp_path / "tether-space.nft"
    fence.write_text("# previous fence\n")
    vars_ = {"cua_cli": str(tmp_path / "no-such-cua"), "tether_space_name": "tether", "tether_space_ref": "local:tether",
             "tether_space_nft": str(fence), "tether_space_nft_src": str(ROOT / "ansible/templates" / SPACE_NFT)}
    probe = {"ansible.builtin.copy": {"content": "{{ tether_space_port | default('none') }} {{ tether_space_ip | default('none') }}", "dest": str(tmp_path / "facts")}}
    play = tmp_path / "failed-play.json"
    play.write_text(json.dumps([{"hosts": "localhost", "gather_facts": False, "vars": vars_, "tasks": [
        {"block": tasks, "rescue": _space_block()["rescue"]}, probe]}]))
    proc = subprocess.run(["ansible-playbook", "-c", "local", "-i", "localhost,", str(play)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert (tmp_path / "facts").read_text() == "none none"
    assert fence.read_text() == "# previous fence\n", "a failed step never renders the fence away"
    text = _render_tether_nft(tmp_path, "failed.nft", {})
    assert "saddr" not in text and "table bridge tether_space {" not in text and "space_input" not in text and "tcp dport 4000 accept" in text
    assert text.count("127.0.0.1 tcp dport") == 1, "only the router port: no Space port is kept"
    _nft_check(tmp_path / "failed.nft")


def test_host_config_runs_once_after_every_boot() -> None:
    timer = INSTALLED / "fleet-host-config-boot.timer"
    keys: dict[str, list[str]] = {}
    for line in timer.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    assert keys["OnBootSec"] == ["3min"] and keys["Unit"] == ["fleet-host-config.service"]
    assert "RandomizedDelaySec" not in keys, "the daily timer's random delay would hold the boot run back"
    assert keys["WantedBy"] == ["timers.target"]
    enable = _host_task("Enable the host config run after boot")["ansible.builtin.systemd_service"]
    assert enable["name"] == "fleet-host-config-boot.timer" and enable["enabled"] is True
    assert "state" not in enable, "starting the timer after boot would fire it at once"
