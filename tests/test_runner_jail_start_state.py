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
    assert [v for v in merged_values(agent, "TemporaryFileSystem")] == ["/home/nish:mode=0700,uid=1000,gid=1000,size=512M", "/home/nish/.config/gh:ro", "/home/nish/.config/cloudflare:ro"]  # the empty mount points the worker jail masks (#10934, #11120)
    bound = " " + " ".join(merged_values(agent, "BindReadOnlyPaths")) + " " + " ".join(merged_values(agent, "BindPaths")) + " "
    # pi's library tree, the App key dir and the seat token files the unjailed steps read.
    for tail in ("/.local/lib", "/.config/fleet-worker", "/seats", "/.local/bin"):
        assert tail in bound, tail


JAIL_TMPFS = re.compile(r"--tmpfs \$HOME/([^\s\"]+)")


def jail_tmpfs_targets(workflows: dict[str, str]) -> set[str]:
    """Tails under home of every literal `--tmpfs $HOME/...` target in the jailed workflows.

    Variable targets (`--tmpfs $seat_a`, the claude_hides loop) are out of reach of a literal
    scan; every path they resolve to sits under a mount point this gate already covers.
    """
    targets: set[str] = set()
    for text in workflows.values():
        targets |= set(JAIL_TMPFS.findall(text))
    return targets


def jail_mount_point_tails(dirs: list[Path]) -> set[str]:
    """Paths under home the drop-in itself creates at start, as tails under the home tmpfs."""
    home = merged_values(dirs, "TemporaryFileSystem")[0].partition(":")[0]
    covered: set[str] = set()
    for key in ("TemporaryFileSystem", "BindPaths", "BindReadOnlyPaths"):
        for value in merged_values(dirs, key):
            for token in shlex.split(value):
                path = token.lstrip("-+").partition(":")[0]
                if path.startswith(home + "/"):
                    covered.add(path.removeprefix(home + "/"))
    return covered


def uncovered_jail_targets(targets: set[str], covered: set[str]) -> list[str]:
    return sorted(t for t in targets if not any(same_branch(t, c) for c in covered))


def test_every_path_the_worker_jail_masks_is_created_by_the_runner_drop_in() -> None:
    """A `--tmpfs $HOME/...` target must exist before the runner starts (fleet-ops#11120).

    The mount-point parents systemd makes on the home tmpfs are root-owned and the jail's bwrap
    runs as nish, so bwrap cannot mkdir a missing target and every jailed job dies at startup.
    #10934 fixed the one target then missing; #11000 then cut the gh bind whose side effect was
    the gh mount point, and no test saw it. The check reads the jail lines instead of naming
    targets, so the next target is covered when it lands.
    """
    jailed = {name: text for name, text in runner_workflows().items() if "bwrap --dev-bind" in text}
    targets = jail_tmpfs_targets(jailed)
    assert {".config/gh", ".config/cloudflare"} <= targets, "the jail lines moved; this gate reads the wrong thing"
    missing = uncovered_jail_targets(targets, jail_mount_point_tails(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"]))
    assert not missing, f"the jail masks {missing}, but the runner creates no mount point there"


def test_the_jail_mount_point_gate_sees_partial_coverage() -> None:
    assert uncovered_jail_targets({".config/gh"}, {".config"}) == []
    assert uncovered_jail_targets({".config/gh", ".config/cloudflare"}, {".config/cloudflare", ".config/fleet-ops"}) == [".config/gh"]
    assert uncovered_jail_targets(set(), {".config"}) == []


FLEET_CONFIG_READ = re.compile(r"(?:\$\{?HOME\}?[\"']?|%h|~|/home/[^/\"' ]+)/\.config/fleet-ops/([A-Za-z0-9_.*/-]+)")


def fleet_config_read_names(text: str) -> set[str]:
    """Names a text reads under the fleet config dir, with no absolute path spelled out.

    A pattern match on purpose, not a parser: it covers the reads this repo makes and it does not
    follow a `cd` or a repo script, so a read no pattern matches is a gap for the run's own tests.
    """
    return set(FLEET_CONFIG_READ.findall(text))


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


def runner_workflows() -> dict[str, str]:
    """Workflow name -> text, for the workflows whose jobs run on the runners.

    The other workflows run on GitHub's own runners, where no fleet config dir exists, and ci.yml
    plants a path under a simulated home to prove the engine jail hides it.
    """
    out = {}
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        lines = path.read_text().splitlines()
        if any("self-hosted" in line for line in lines if line.lstrip().startswith("runs-on:")):
            out[path.name] = "\n".join(lines)
    return out


def same_branch(a: str, b: str) -> bool:
    """True when two names sit on one path branch, so a narrower bind and a wider read match."""
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def test_the_agent_pool_binds_no_fleet_config_path_no_job_reads() -> None:
    """A runner bind with no reader is exposure for nothing (fleet-ops#10826).

    A path under the fleet config dir is bound because a job reads it before the engine jail
    starts. Only a workflow that runs on a runner can read it, so a hosted workflow's text never
    justifies a bind. The eval pool's one bind is not checked: the drive eval container reads it,
    not a step, and cutting it needs a credential moved (#10957).
    """
    readers: set[str] = set()
    for text in runner_workflows().values():
        readers |= fleet_config_read_names(text)
    bound = fleet_config_bind_names(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"])
    unread = sorted(name for name in bound if not any(same_branch(name, reader) for reader in readers))
    assert not unread, f"bound with no job reading it: {unread}"


def fleet_config_dir(dirs: list[Path]) -> str:
    """The fleet config dir as the drop-in spells it, read off a bind inside it.

    Read rather than written out: a literal home path in this file is a private detail, and the
    check then follows the path the drop-in binds, not the home this host happens to have.
    """
    for key in ("BindReadOnlyPaths", "BindPaths"):
        for value in merged_values(dirs, key):
            for token in shlex.split(value):
                head, sep, _ = token.lstrip("-+").partition("/.config/fleet-ops/")
                if sep:
                    return head + "/.config/fleet-ops"
    raise AssertionError("the agent pool binds nothing under the fleet config dir")


def test_the_agent_pool_binds_no_directory_that_holds_the_fleet_config() -> None:
    """A bind of the config dir or a parent of it exposes every credential in it (fleet-ops#10826).

    #10956 made this change by binding the whole directory, which took the two repo files off the
    named-path line instead of cutting them. The name scan cannot see that bind, because it matches
    a path inside the directory, so the regression gets its own check.
    """
    dirs = runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"]
    config = fleet_config_dir(dirs)
    wide: set[str] = set()
    for key in ("BindReadOnlyPaths", "BindPaths"):
        for value in merged_values(dirs, key):
            for token in shlex.split(value):
                token = token.lstrip("-+")
                if config == token or config.startswith(token + "/"):
                    wide.add(token)
    assert not wide, f"binds a directory that holds the fleet config: {sorted(wide)}"


def test_the_read_scan_sees_each_home_spelling_the_workflows_use() -> None:
    """`"$HOME"/.config/...` is a read like any other, and the scan has to see it (fleet-ops#10826).

    agent.yml quotes the variable on its `claude_hides` line. A pattern that expects the path right
    after `$HOME` misses that spelling, so a future read written that way passes the tripwire.
    """
    assert fleet_config_read_names('"$HOME"/.config/fleet-ops/litellm-proxy.yaml') == {"litellm-proxy.yaml"}
    assert fleet_config_read_names('$HOME/.config/fleet-ops/litellm-proxy.yaml') == {"litellm-proxy.yaml"}
    assert fleet_config_read_names('${HOME}/.config/fleet-ops/intake-repos.json') == {"intake-repos.json"}
    assert fleet_config_read_names('%h/.config/fleet-ops/litellm-proxy.yaml') == {"litellm-proxy.yaml"}


def test_no_runner_job_reads_a_fleet_config_path_the_agent_pool_does_not_bind() -> None:
    """A read of a path the jail does not bind fails the job when it runs, not here (fleet-ops#10826).

    The two places that count router slots read config/litellm-proxy.yaml from the deploy clone,
    which the jail binds whole. Reading the host copy instead names a path the jail no longer
    carries, and the job dies on "No such file or directory" on a runner, so the read side needs
    its own tripwire: this is the check a revert of that move fails.
    """
    bound = fleet_config_bind_names(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"])
    for name, text in runner_workflows().items():
        unbound = sorted(read for read in fleet_config_read_names(text) if not any(same_branch(read, b) for b in bound))
        assert not unbound, f"{name} reads a fleet config path the agent pool does not bind: {unbound}"


def test_the_agent_pool_binds_no_file_the_repo_ships() -> None:
    """A file the repo ships is read from the deploy clone, not from the host config dir (fleet-ops#10826).

    The clone is bound whole, so a job that needs config/litellm-proxy.yaml or config/intake-repos.json
    has the file already. Binding the host copy as well puts a repo file inside the credential-named
    directory, which is what made a whole-directory bind look like the smaller change.
    """
    bound = fleet_config_bind_names(runner_units()["actions.runner.Nishfleet.netcup-agent-.service.d"])
    shipped = sorted(name for name in bound if (ROOT / "config" / name).is_file())
    assert not shipped, f"read from the deploy clone instead: {shipped}"
