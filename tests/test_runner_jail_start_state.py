"""Runner jail: a token dir stays covered when it is made after the start, and no step runs under a hidden path (fleet-ops#10886).

InaccessiblePaths= is applied once, against the directory that exists then, and the pre-start
mkdir that used to make these dirs ran after it, so the directory it made was never covered.
The two token dirs are therefore covered by a TemporaryFileSystem= mount: systemd makes the
mount point and mounts it before the runner runs, so a directory the mint creates later is
already covered, nothing has to pre-create these dirs, and a mount that cannot be made stops
the unit instead of leaving a job readable. A mount sits on the directory it was made on, so
a delete-and-recreate from the host is as uncovered as a replaced mask, which is why the
mints keep these dirs (RuntimeDirectoryPreserve=yes). runner-probe checks inside the job that
every mount is live. The last two tests below run the real manager, on CI or a host that has
one, and prove the mount point is made for an absent path and that a file written there
later stays hidden from the job.

A path may sit on one list or the other, never both: at one path systemd applies the more
restrictive entry and drops the other, and InaccessiblePaths= sorts before
TemporaryFileSystem= (namespace.c: mount_path_compare, then drop_duplicates), so a path on
both lists is masked and the mount never happens.

The paths still masked by inode (the user bus, the user systemd dir, podman, the user gpg
dir) are made by the user manager itself, so every runner drop-in is ordered after it
(fleet-ops#10081).
"""

import os
import re
import shlex
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
AGENT_DIR = SYSTEM / "actions.runner.Nishfleet.netcup-agent-.service.d"
FLEET_CI_DIR = SYSTEM / "actions.runner.Nishfleet.netcup-fleet-ci-.service.d"
VAULT_DIR = SYSTEM / "actions.runner.nish3451-nish-vault.netcup-vault-1.service.d"
# pool -> the drop-in with the start order and the lockdown
POOLS = {
    "agent": (AGENT_DIR / "10-agent.conf", AGENT_DIR / "20-lockdown.conf"),
    "fleet-ci": (FLEET_CI_DIR / "10-fleet-ci.conf", FLEET_CI_DIR / "20-lockdown.conf"),
    # The vault runner has one drop-in, so the start order and the lockdown are the same file.
    "vault": (VAULT_DIR / "20-lockdown.conf", VAULT_DIR / "20-lockdown.conf"),
}
pool = pytest.mark.parametrize("start_conf,lockdown_conf", POOLS.values(), ids=POOLS.keys())
USER_RUN = "/run/user/1000/"
# The runtime dirs the user token mints write their App tokens into (systemd/fleet-worker-github-token@.service,
# systemd/fleet-grafana-github-token.service). A job that can read one reads a minted token.
TOKEN_DIRS = (USER_RUN + "fleet-worker-github-token", USER_RUN + "fleet-grafana-github-token")
IN_CI = bool(os.environ.get("GITHUB_ACTIONS"))
SUDO = ["sudo", "-n"] if IN_CI else []
SCOPE = [] if IN_CI else ["--user"]


def manager_usable() -> bool:
    """A transient unit starts here, which a jail or a session with no user bus forbids."""
    if shutil.which("systemd-run") is None:
        return False
    return subprocess.run([*SUDO, "systemd-run", *SCOPE, "--scope", "--quiet", "--", "true"], capture_output=True).returncode == 0


needs_manager = pytest.mark.skipif(not manager_usable(), reason="no systemd manager starts a unit here")


def values(text: str, key: str) -> list[str]:
    """Every `key=value` line of a drop-in, in file order (comments skipped)."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            out.append(line.removeprefix(key + "="))
    return out


def paths_of(text: str, key: str) -> set[str]:
    """Every path one `key=` list names, with the mount options of a TemporaryFileSystem= entry stripped."""
    out = set()
    for value in values(text, key):
        for token in shlex.split(value):
            out.add(token.split(":", 1)[0].lstrip("-+"))
    return out


def masked_paths(text: str) -> set[str]:
    return paths_of(text, "InaccessiblePaths")


def mounted_paths(text: str) -> set[str]:
    return paths_of(text, "TemporaryFileSystem")


def masked_user_run_names(text: str) -> set[str]:
    return {p.removeprefix(USER_RUN).split("/")[0] for p in masked_paths(text) if p.startswith(USER_RUN)}


def hidden_token_dirs(text: str) -> set[str]:
    """The token dirs a drop-in hides, masked or mounted."""
    return (masked_paths(text) | mounted_paths(text)) & set(TOKEN_DIRS)


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


def merged_paths(dirs: list[Path], key: str) -> set[str]:
    text = "\n".join(f"{key}={value}" for value in merged_values(dirs, key))
    return paths_of(text, key)


def both_lists(dirs: list[Path]) -> set[str]:
    """Paths on InaccessiblePaths= and on TemporaryFileSystem= at once: systemd keeps the more
    restrictive of the two at one path, InaccessiblePaths= sorts first, so these mounts never happen."""
    return merged_paths(dirs, "InaccessiblePaths") & merged_paths(dirs, "TemporaryFileSystem")


def pre_start_paths_under_hidden_dir(dirs: list[Path]) -> list[str]:
    """Paths an unprivileged ExecStartPre= touches that sit under a directory the unit hides whole.

    InaccessiblePaths= also applies to ExecStartPre= (same mount namespace), so a mkdir below a hidden
    parent fails with "Permission denied" and the runner never starts. A directory the unit covers
    with a mount hides its whole subtree too: a step under one writes into the empty tmpfs and never
    reaches the host. Hiding the target itself is fine: the mount point exists already.
    """
    hidden = merged_paths(dirs, "InaccessiblePaths") | merged_paths(dirs, "TemporaryFileSystem")
    bad = []
    for value in merged_values(dirs, "ExecStartPre"):
        for arg in shlex.split(value.lstrip("-@:!")):
            if arg.startswith("/") and hidden & {str(parent) for parent in Path(arg).parents}:
                bad.append(f"ExecStartPre={value} needs {arg}, below hidden {sorted(hidden & {str(parent) for parent in Path(arg).parents})[0]}")
    return bad


def test_no_runner_pre_start_step_runs_under_a_directory_the_runner_hides() -> None:
    units = runner_units()
    assert len(units) >= 5, "the runner drop-in dirs were not found"
    for name, dirs in units.items():
        assert pre_start_paths_under_hidden_dir(dirs) == [], name
    # fleet-ci-3 hides /run/user/1000 whole while the shared fleet-ci drop-in once made dirs in it (2026-10-23).
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
    # Hiding the target itself is fine (the mount point or the dir exists), and an empty ExecStartPre= clears the shared line.
    (own / "30.conf").write_text("[Service]\nInaccessiblePaths=-/run/user/1000/a\n")
    assert pre_start_paths_under_hidden_dir([shared, own]) == []
    (own / "30.conf").write_text("[Service]\nInaccessiblePaths=-/run/user/1000\nExecStartPre=\n")
    assert pre_start_paths_under_hidden_dir([shared, own]) == []


@pool
def test_runner_starts_after_the_user_manager(start_conf: Path, lockdown_conf: Path) -> None:
    assert starts_after_user_manager(start_conf.read_text()) == []


@pool
def test_every_token_dir_is_covered_by_a_mount(start_conf: Path, lockdown_conf: Path) -> None:
    """The mint makes its dir after the runner started, so the path is covered by a mount and not by a mask (fleet-ops#10886)."""
    text = lockdown_conf.read_text()
    covered = mounted_paths(text)
    for name in TOKEN_DIRS:
        assert name in covered, f"{lockdown_conf.name}: {name} is masked by inode, not covered by a mount"


def test_no_path_is_masked_and_mounted_at_once() -> None:
    units = runner_units()
    assert len(units) >= 5, "the runner drop-in dirs were not found"
    for name, dirs in units.items():
        assert both_lists(dirs) == set(), f"{name}: {sorted(both_lists(dirs))} sit on both lists, so their mounts never happen"


def test_gate_fails_when_a_path_sits_on_both_lists(tmp_path: Path) -> None:
    d = tmp_path / "x-.service.d"
    d.mkdir()
    (d / "20.conf").write_text(
        "[Service]\nInaccessiblePaths=-/run/user/1000/fleet-worker-github-token\n"
        "TemporaryFileSystem=/run/user/1000/fleet-worker-github-token\n"
    )
    assert both_lists([d]) == {"/run/user/1000/fleet-worker-github-token"}
    (d / "20.conf").write_text(
        "[Service]\nInaccessiblePaths=-/run/user/1000/gnupg\nTemporaryFileSystem=/run/user/1000/fleet-worker-github-token\n"
    )
    assert both_lists([d]) == set()
    # Options are part of the value, not the path: a mode on the mount is the same path.
    (d / "20.conf").write_text("[Service]\nTemporaryFileSystem=/run/user/1000/fleet-worker-github-token:mode=0700\n")
    assert both_lists([d]) == set()
    assert merged_paths([d], "TemporaryFileSystem") == {"/run/user/1000/fleet-worker-github-token"}


def test_every_runner_drop_in_that_hides_a_token_dir_is_covered() -> None:
    """A new runner pool that hides a token dir, masked or mounted, must be added to POOLS, not skipped."""
    hiding = set()
    for conf in SYSTEM.glob("actions.runner.*.service.d/*.conf"):
        if hidden_token_dirs(conf.read_text()):
            hiding.add(conf)
    covered = {conf for pair in POOLS.values() for conf in pair}
    assert hiding <= covered, sorted(str(c.relative_to(ROOT)) for c in hiding - covered)


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_finds_no_syntax_error_in_every_runner_dropin(tmp_path: Path) -> None:
    """One standin unit per runner unit dir, carrying every drop-in that applies to it (fleet-ops#10886).

    The dependency on user@1000.service is not resolved here: that unit does not exist on a CI
    host. The pilot runner starts a script in a root-only directory, so its "is not executable"
    line is this host's permissions, not a syntax error.
    """
    (tmp_path / "standin.service").write_text("[Service]\nExecStart=/usr/bin/true\nUser=nish\n")
    dropins = tmp_path / "standin.service.d"
    units = runner_units()
    assert len(units) >= 5, "the runner drop-in dirs were not found"
    for name, dirs in units.items():
        shutil.rmtree(dropins, ignore_errors=True)
        dropins.mkdir()
        files = {}
        for d in dirs:  # prefix dirs first, so the unit's own dir wins on a same name
            files.update({conf.name: conf for conf in d.glob("*.conf")})
        for conf_name, conf in files.items():
            (dropins / conf_name).write_text(conf.read_text())
        proc = subprocess.run(
            ["systemd-analyze", "verify", "--man=no", "./standin.service"], cwd=tmp_path, capture_output=True, text=True, check=False
        )
        bad = [
            line
            for line in (proc.stdout + proc.stderr).splitlines()
            if re.search(r"Unknown key|Unknown section|Failed to parse|Invalid|Executable", line) and "is not executable" not in line
        ]
        assert bad == [], f"{name}: {bad}"


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
    assert [v for v in merged_values(agent, "TemporaryFileSystem")] == [
        "/home/nish:mode=0700,uid=1000,gid=1000,size=512M",
        "/home/nish/.config/cloudflare:ro",  # the empty mount point the worker jail masks (#10934)
        "/run/user/1000/fleet-worker-github-token:ro",
        "/run/user/1000/fleet-grafana-github-token:ro",
    ]
    bound = " " + " ".join(merged_values(agent, "BindReadOnlyPaths")) + " " + " ".join(merged_values(agent, "BindPaths")) + " "
    # pi's library tree, the App key dir and the seat token files the unjailed steps read.
    for tail in ("/.local/lib", "/.config/fleet-worker", "/seats", "/.local/bin"):
        assert tail in bound, tail


def transient_run(properties: list[str], script: str) -> list[str]:
    """A one-shot unit, so the manager builds the mount namespace exactly as it does for a runner."""
    return [
        *SUDO,
        "systemd-run",
        *SCOPE,
        "--collect",
        "--quiet",
        "--wait",
        "--pipe",
        *[arg for prop in properties for arg in ("-p", prop)],
        "--",
        "/bin/sh",
        "-c",
        script,
    ]


def await_file(path: Path, what: str) -> None:
    deadline = time.monotonic() + 60
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert path.exists(), f"the transient unit never {what}"


@needs_manager
def test_systemd_makes_the_mount_point_when_the_path_is_absent_at_start(tmp_path: Path) -> None:
    """The mint may create its dir after the runner started, so the mount point cannot wait for a pre-start mkdir (fleet-ops#10886)."""
    absent = tmp_path / "absent"
    assert not absent.exists()
    script = f"awk -v m={shlex.quote(str(absent))} '$5 == m {{ f = 1 }} END {{ exit !f }}' /proc/self/mountinfo"
    proc = subprocess.run(transient_run([f"TemporaryFileSystem={absent}:ro"], script), capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert absent.is_dir(), "the unit started, but the host has no mount point where systemd mounted"


@needs_manager
def test_an_existing_mount_point_keeps_its_owner_and_mode(tmp_path: Path) -> None:
    """A mount point that exists already is not re-owned: systemd makes an absent one as root (fleet-ops#10886).

    rootfs/etc/tmpfiles.d/fleet-runner-token-dirs.conf makes the two token dirs nish-owned mode 0700
    at boot, so the mount point is there with the owner the mint needs and systemd never makes one.
    """
    token_dir = tmp_path / "token"
    token_dir.mkdir()
    os.chown(token_dir, 1000, 1000)
    os.chmod(token_dir, 0o700)
    script = f"test -d {token_dir} && stat -c %u:%g:%a {token_dir}"
    proc = subprocess.run(transient_run([f"TemporaryFileSystem={token_dir}:ro"], script), capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "1000:1000:700", "the mount point changed owner or mode, so the mint cannot write its token there"


@needs_manager
def test_an_absent_mount_point_is_made_root_owned(tmp_path: Path) -> None:
    """The cause a boot-time creator fixes: systemd makes the mount point itself, as root (fleet-ops#10886)."""
    absent = tmp_path / "absent"
    assert not absent.exists()
    proc = subprocess.run(transient_run([f"TemporaryFileSystem={absent}:ro"], "true"), capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert absent.is_dir(), "the unit started, but the host has no mount point where systemd mounted"
    owner = absent.stat().st_uid
    assert owner == 0, f"systemd made the mount point as uid {owner}, so the root-owned mount point has another cause"


@needs_manager
def test_a_dir_made_at_the_covered_path_after_the_start_stays_hidden(tmp_path: Path) -> None:
    """A file the mint writes after the runner started lands inside the mount, so a job reading that path reads nothing (fleet-ops#10886)."""
    token_dir = tmp_path / "token"
    started, go = tmp_path / "started", tmp_path / "go"
    script = f"touch {started}\nwhile [ ! -e {go} ]; do sleep 0.1; done\nls -A {token_dir}"
    unit = subprocess.Popen(
        transient_run([f"TemporaryFileSystem={token_dir}:ro"], script), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    try:
        await_file(started, "started")
        assert token_dir.is_dir(), "systemd did not make the mount point on the host"
        # The manager creates the mount point as root, so the host write needs the same hand in CI.
        subprocess.run([*SUDO, "touch", str(token_dir / "drive.env")], check=True)
        go.touch()
        out, err = unit.communicate(timeout=120)
    finally:
        go.touch()
        unit.kill()
        unit.wait()
    assert unit.returncode == 0, err
    assert out == "", f"the job read {out!r} through the path the unit covers: {err}"


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
>>>>>>> origin/main
