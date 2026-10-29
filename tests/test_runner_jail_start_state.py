"""Runner jail: every hidden path must exist when the runner starts (fleet-ops#10081).

InaccessiblePaths= hides a path only if it exists at the moment the unit starts. A path that
user services create later stays visible to jobs until the runner restarts. The agent runner
drop-in therefore starts after the user manager and creates the runtime dirs that user
services would otherwise make later. The fleet-ci and vault runner drop-ins do the same
(fleet-ops#10120).
"""

import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
AGENT_DIR = SYSTEM / "actions.runner.Nishfleet.netcup-agent-.service.d"
FLEET_CI_DIR = SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-.service.d"
VAULT_DIR = SYSTEM / "actions.runner.nish3451-nish-vault.netcup-vault-1.service.d"
# pool -> (drop-in with the start order and the pre-start step, drop-in with InaccessiblePaths=)
POOLS = {
    "agent": (AGENT_DIR / "10-agent.conf", AGENT_DIR / "20-lockdown.conf"),
    "fleet-ci": (FLEET_CI_DIR / "10-fleet-ci.conf", FLEET_CI_DIR / "20-lockdown.conf"),
    # The vault runner has one drop-in, so the start order and the lockdown are the same file.
    "vault": (VAULT_DIR / "20-lockdown.conf", VAULT_DIR / "20-lockdown.conf"),
}
pool = pytest.mark.parametrize("start_conf,lockdown_conf", POOLS.values(), ids=POOLS.keys())
USER_UNIT_DIRS = [ROOT / "systemd", ROOT / "rootfs/etc/systemd/user"]
USER_RUN = "/run/user/1000/"


def values(text: str, key: str) -> list[str]:
    """Every `key=value` line of a drop-in, in file order (comments skipped)."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            out.append(line.removeprefix(key + "="))
    return out


def masked_user_run_names(lockdown_text: str) -> set[str]:
    names = set()
    for value in values(lockdown_text, "InaccessiblePaths"):
        for token in shlex.split(value):
            path = token.lstrip("-+")
            if path.startswith(USER_RUN):
                names.add(path.removeprefix(USER_RUN).split("/")[0])
    return names


def runtime_dirs_of_user_units(unit_dirs: list[Path]) -> dict[str, tuple[str, bool]]:
    """RuntimeDirectory= name -> (RuntimeDirectoryMode=, preserved) of every repo user unit that sets one."""
    found = {}
    for unit_dir in unit_dirs:
        for unit in sorted(unit_dir.rglob("*.service")) + sorted(unit_dir.rglob("*.conf")):
            text = unit.read_text()
            modes = values(text, "RuntimeDirectoryMode")
            preserve = values(text, "RuntimeDirectoryPreserve")
            for names in values(text, "RuntimeDirectory"):
                for name in names.split():
                    found[name] = (modes[0] if modes else "0755", bool(preserve) and preserve[-1] == "yes")
    return found


def pre_created(agent_text: str) -> dict[str, str]:
    """Path -> mode of every directory an unprivileged ExecStartPre= `mkdir -p -m` makes."""
    made = {}
    for value in values(agent_text, "ExecStartPre"):
        if value.startswith(("+", "!", "-", "@", ":")):
            continue
        argv = shlex.split(value)
        if len(argv) < 4 or Path(argv[0]).name != "mkdir" or "-p" not in argv or "-m" not in argv:
            continue
        mode = argv[argv.index("-m") + 1]
        for path in argv[1:]:
            if path.startswith("/"):
                made[path] = mode
    return made


def uncovered(lockdown_text: str, agent_text: str, unit_dirs: list[Path]) -> list[str]:
    """Hidden user-runtime paths that a user service creates later and the runner does not pre-create."""
    later = runtime_dirs_of_user_units(unit_dirs)
    made = pre_created(agent_text)
    bad = []
    for name in sorted(masked_user_run_names(lockdown_text) & set(later)):
        mode, preserved = later[name]
        made_mode = made.get(USER_RUN + name)
        if made_mode is None:
            bad.append(f"{name}: not created before start")
        elif int(made_mode, 8) != int(mode, 8):
            bad.append(f"{name}: mode {made_mode} differs from the service's {mode}")
        elif not preserved:
            bad.append(f"{name}: the service does not set RuntimeDirectoryPreserve=yes")
    return bad


def section_values(text: str, section: str, key: str) -> list[str]:
    """Like values(), but only inside one [section] (a later [Service] line must not count as [Unit])."""
    out, current = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
        elif current == section and line.startswith(key + "="):
            out.append(line.removeprefix(key + "="))
    return out


def starts_after_user_manager(text: str) -> list[str]:
    """What is missing so the runner is ordered after, and pulls in, the user manager."""
    missing = []
    for key in ("After", "Wants"):
        if "user@1000.service" not in " ".join(section_values(text, "Unit", key)).split():
            missing.append(f"[Unit] {key}=user@1000.service")
    return missing


def merged_values(dirs: list[Path], key: str) -> list[str]:
    """Effective `key=` list of one unit the way systemd merges its drop-ins.

    A drop-in of the unit's own .service.d replaces a same-named one in a prefix dir (`...ci-.service.d`);
    all are read in file-name order, and an empty `key=` clears what came before.
    """
    files = {}
    for d in dirs:  # prefix dirs first, so the unit's own dir wins on a same name
        for conf in d.glob("*.conf"):
            files[conf.name] = conf
    out: list[str] = []
    for name in sorted(files):
        for value in values(files[name].read_text(), key):
            out = [] if value.strip() == "" else out + [value]
    return out


def runner_units() -> dict[str, list[Path]]:
    """Unit dir name -> the drop-in dirs that apply to it, for every runner .service.d in the repo."""
    dirs = sorted(SYSTEM.glob("actions.runner.*.service.d"))
    units = {}
    for d in dirs:
        stem = d.name.removesuffix(".service.d")
        prefixes = [SYSTEM / (stem[: i + 1] + ".service.d") for i, c in enumerate(stem) if c == "-" and i + 1 < len(stem)]
        units[d.name] = [p for p in prefixes if p.is_dir()] + [d]
    return units


def pre_start_paths_under_hidden_dir(dirs: list[Path]) -> list[str]:
    """Paths an unprivileged ExecStartPre= touches that sit under a directory the unit hides whole.

    InaccessiblePaths= also applies to ExecStartPre= (same mount namespace), so a mkdir below a hidden
    parent fails with "Permission denied" and the runner never starts. Hiding the target itself is fine:
    it exists already, so mkdir -p finds it.
    """
    hidden = set()
    for value in merged_values(dirs, "InaccessiblePaths"):
        hidden |= {Path(t.lstrip("-+")) for t in shlex.split(value)}
    bad = []
    for value in merged_values(dirs, "ExecStartPre"):
        for arg in shlex.split(value.lstrip("-@:!")):
            if arg.startswith("/") and hidden & set(Path(arg).parents):
                bad.append(f"ExecStartPre={value} needs {arg}, below hidden {sorted(hidden & set(Path(arg).parents))[0]}")
    return bad


def test_no_runner_pre_start_step_runs_under_a_directory_the_runner_hides() -> None:
    units = runner_units()
    assert len(units) >= 5, "the runner drop-in dirs were not found"
    for name, dirs in units.items():
        assert pre_start_paths_under_hidden_dir(dirs) == [], name
    # fleet-ci-3 hides /run/user/1000 whole while the shared fleet-ci drop-in makes dirs in it (2026-10-23).
    ci3 = units["actions.runner.Nishfleet.netcup-fleet-ci-3.service.d"]
    assert FLEET_CI_DIR in ci3
    assert merged_values(ci3, "ExecStartPre") == []
    assert any("/run/user/1000" in [t.lstrip("-+") for t in v.split()] for v in merged_values(ci3, "InaccessiblePaths"))


def test_gate_fails_when_a_pre_start_mkdir_sits_under_a_hidden_parent(tmp_path: Path) -> None:
    shared = tmp_path / "x-.service.d"
    own = tmp_path / "x-3.service.d"
    shared.mkdir()
    own.mkdir()
    (shared / "10.conf").write_text("[Service]\nExecStartPre=/usr/bin/mkdir -p -m 0700 /run/user/1000/a\n")
    (own / "30.conf").write_text("[Service]\nInaccessiblePaths=-/run/user/1000\n")
    assert pre_start_paths_under_hidden_dir([shared, own]) == [
        "ExecStartPre=/usr/bin/mkdir -p -m 0700 /run/user/1000/a needs /run/user/1000/a, below hidden /run/user/1000"
    ]
    # Hiding the target itself is fine (it exists, so mkdir -p finds it), and an empty ExecStartPre= clears the shared line.
    (own / "30.conf").write_text("[Service]\nInaccessiblePaths=-/run/user/1000/a\n")
    assert pre_start_paths_under_hidden_dir([shared, own]) == []
    (own / "30.conf").write_text("[Service]\nInaccessiblePaths=-/run/user/1000\nExecStartPre=\n")
    assert pre_start_paths_under_hidden_dir([shared, own]) == []


@pool
def test_runner_starts_after_the_user_manager(start_conf: Path, lockdown_conf: Path) -> None:
    assert starts_after_user_manager(start_conf.read_text()) == []


@pool
def test_late_runtime_dirs_exist_before_the_runner_starts(start_conf: Path, lockdown_conf: Path) -> None:
    names = masked_user_run_names(lockdown_conf.read_text()) & set(runtime_dirs_of_user_units(USER_UNIT_DIRS))
    assert len(names) >= 2, "the hidden runtime dirs made by user services were not found"
    assert uncovered(lockdown_conf.read_text(), start_conf.read_text(), USER_UNIT_DIRS) == []


@pool
def test_the_pre_create_line_does_not_run_as_root(start_conf: Path, lockdown_conf: Path) -> None:
    lines = values(start_conf.read_text(), "ExecStartPre")
    assert lines, "no ExecStartPre= pre-create line"
    # Check every drop-in of the pool: a "+" line anywhere would run outside the sandbox, as root.
    for conf in {start_conf, lockdown_conf}:
        assert not any(line.startswith("+") for line in values(conf.read_text(), "ExecStartPre")), conf.name


def test_every_runner_drop_in_that_hides_user_runtime_paths_is_covered() -> None:
    """A new runner pool that hides /run/user/1000/ paths must be added to POOLS, not skipped."""
    hiding = set()
    for conf in SYSTEM.glob("actions.runner.*.service.d/*.conf"):
        if masked_user_run_names(conf.read_text()) & set(runtime_dirs_of_user_units(USER_UNIT_DIRS)):
            hiding.add(conf)
    covered = {conf for pair in POOLS.values() for conf in pair}
    assert hiding <= covered, sorted(str(c.relative_to(ROOT)) for c in hiding - covered)


def _fixture(tmp_path: Path, mode: str = "0700", preserve: str = "RuntimeDirectoryPreserve=yes\n") -> list[Path]:
    units = tmp_path / "systemd"
    units.mkdir()
    (units / "x.service").write_text(f"[Service]\nRuntimeDirectory=late-dir\nRuntimeDirectoryMode={mode}\n{preserve}")
    return [units]


LOCK = "[Service]\nInaccessiblePaths=-/run/user/1000/bus -/run/user/1000/late-dir\n"
GOOD = "[Service]\nExecStartPre=/usr/bin/mkdir -p -m 0700 /run/user/1000/late-dir\n"


def test_gate_fails_when_a_late_dir_is_not_pre_created(tmp_path: Path) -> None:
    assert uncovered(LOCK, "[Service]\n", _fixture(tmp_path)) == ["late-dir: not created before start"]


def test_gate_fails_on_a_mode_mismatch_and_on_a_root_line(tmp_path: Path) -> None:
    units = _fixture(tmp_path)
    wrong = "[Service]\nExecStartPre=/usr/bin/mkdir -p -m 0755 /run/user/1000/late-dir\n"
    assert uncovered(LOCK, wrong, units) == ["late-dir: mode 0755 differs from the service's 0700"]
    root = GOOD.replace("ExecStartPre=", "ExecStartPre=+")
    assert uncovered(LOCK, root, units) == ["late-dir: not created before start"]


def test_gate_fails_when_the_service_does_not_keep_its_dir(tmp_path: Path) -> None:
    units = _fixture(tmp_path, preserve="")
    assert uncovered(LOCK, GOOD, units) == ["late-dir: the service does not set RuntimeDirectoryPreserve=yes"]


def test_gate_fails_when_the_start_order_is_missing() -> None:
    both = "[Unit]\nAfter=user@1000.service\nWants=user@1000.service\n"
    assert starts_after_user_manager(both) == []
    assert starts_after_user_manager("[Service]\nNoNewPrivileges=yes\n") == [
        "[Unit] After=user@1000.service",
        "[Unit] Wants=user@1000.service",
    ]
    assert starts_after_user_manager(both.replace("Wants=", "Requires=")) == ["[Unit] Wants=user@1000.service"]
    # Right key, wrong section: a [Service] line is not an ordering.
    assert starts_after_user_manager("[Service]\nAfter=user@1000.service\nWants=user@1000.service\n") == [
        "[Unit] After=user@1000.service",
        "[Unit] Wants=user@1000.service",
    ]


def test_gate_accepts_a_pre_created_dir(tmp_path: Path) -> None:
    assert uncovered(LOCK, GOOD, _fixture(tmp_path)) == []


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
@pool
def test_systemd_analyze_finds_no_syntax_error_in_the_dropins(tmp_path: Path, start_conf: Path, lockdown_conf: Path) -> None:
    (tmp_path / "standin.service").write_text("[Service]\nExecStart=/usr/bin/true\n")
    (tmp_path / "standin.service.d").mkdir()
    for conf in {start_conf, lockdown_conf}:
        (tmp_path / "standin.service.d" / conf.name).write_text(conf.read_text())
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", "./standin.service"], cwd=tmp_path, capture_output=True, text=True, check=False
    )
    out = proc.stdout + proc.stderr
    # Syntax only: user@1000.service does not exist on a CI host, so the dependency itself is not resolved here.
    assert not re.search(r"Unknown key|Unknown section|Failed to parse|Invalid|Executable", out), out


def test_runner_jails_are_allowlists_that_hide_no_home_path() -> None:
    """Home is an empty tmpfs and only bound paths show, so no runner drop-in hides a path under home (fleet-ops#10453).

    The assertions name the tail of a path, not its absolute form: a credential path spelled out in a test is the public-repo detail this issue removes.
    """
    units = runner_units()
    for name, dirs in units.items():
        hidden = [t.lstrip("-+") for v in merged_values(dirs, "InaccessiblePaths") for t in shlex.split(v)]
        assert [p for p in hidden if p.startswith("/home/")] == [], name
        assert "/etc/restic" in hidden, name
    agent = units["actions.runner.Nishfleet.netcup-agent-.service.d"]
    assert [v for v in merged_values(agent, "TemporaryFileSystem")] == ["/home/nish:mode=0700,uid=1000,gid=1000,size=512M", "/home/nish/.config/cloudflare:ro"]  # the empty mount point the worker jail masks (#10934)
    bound = " " + " ".join(merged_values(agent, "BindReadOnlyPaths")) + " " + " ".join(merged_values(agent, "BindPaths")) + " "
    # pi's library tree, the App key dir and the seat token files the unjailed steps read.
    for tail in ("/.local/lib", "/.config/fleet-worker", "/seats", "/.local/bin"):
        assert tail in bound, tail


def fleet_config_bind_names(dirs: list[Path]) -> set[str]:
    """Names the runner binds under the fleet config dir, with no absolute path spelled out."""
    names: set[str] = set()
    for key in ("BindReadOnlyPaths", "BindPaths"):
        for value in merged_values(dirs, key):
            for token in shlex.split(value):
                match = re.fullmatch(r"/home/[^/]+/\.config/fleet-ops/(.+)", token.lstrip("-+"))
                if match:
                    names.add(match.group(1))
    return names


def test_the_agent_pool_binds_no_fleet_config_path_no_job_reads() -> None:
    """A runner bind with no reader is exposure for nothing (fleet-ops#10826).

    A path under the fleet config dir is bound because a job reads it before the engine jail
    starts, so the names the drop-in binds and the names the workflows read are one set. The
    eval pool's one bind is not checked: the drive eval container reads it, not a step, and
    cutting it needs a credential moved (#10957).
    """
    readers: set[str] = set()
    workflows = sorted((ROOT / ".github").rglob("*.yml")) + sorted((ROOT / ".github").rglob("*.yaml"))
    for path in workflows:
        readers |= set(re.findall(r"(?:\$HOME|%h|~|/home/[^/\" ]+)/\.config/fleet-ops/([A-Za-z0-9_.*-]+)", path.read_text()))
    bound = fleet_config_bind_names(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"])
    assert bound <= readers, f"bound with no job reading it: {sorted(bound - readers)}"


def test_the_agent_pool_reads_a_repo_config_from_the_clone_it_binds() -> None:
    """A file the repo ships is read from the deploy clone, not from the host config dir (fleet-ops#10826).

    The clone is bound whole, so a job that needs config/litellm-proxy.yaml or config/intake-repos.json
    has the file already. Binding the host copy as well puts a repo file inside the credential-named
    directory, which is what made a whole-directory bind look like the smaller change.
    """
    bound = fleet_config_bind_names(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"])
    shipped = sorted(name for name in bound if (ROOT / "config" / name).exists())
    assert not shipped, f"read from the deploy clone instead: {shipped}"
