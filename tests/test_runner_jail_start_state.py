"""Runner jail: the hide must survive the directory inode, and no step may run under a hidden path (fleet-ops#10886).

InaccessiblePaths= masks the inode that exists when the unit starts, so a directory a user
service recreates in its place is unmasked until the runner restarts. The two token dirs are
therefore covered by a TemporaryFileSystem= mount, which covers the path: the mint recreates
the directory, the mount stays, and a job cannot read the new tokens. systemd makes the mount
point itself when the path is absent at start (mount_tmpfs() creates it before it mounts), so
nothing has to pre-create these dirs, and a mount that cannot be made stops the unit instead
of leaving a job readable. runner-probe checks inside the job that every mount is live.

A path may sit on one list or the other, never both: at one path systemd applies the more
restrictive entry and drops the other, and InaccessiblePaths= sorts before
TemporaryFileSystem= (namespace.c: mount_path_compare, then drop_duplicates), so a path on
both lists is masked and the mount never happens.

The paths still masked by inode (the user bus, the user systemd dir, podman, the user gpg
dir) are made by the user manager itself, so every runner drop-in is ordered after it
(fleet-ops#10081).
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
    """A mount covers the path, so a directory the mint recreates in its place stays covered (fleet-ops#10886)."""
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
    assert merged_paths(agent, "TemporaryFileSystem") == {
        "/home/nish",
        "/run/user/1000/fleet-worker-github-token",
        "/run/user/1000/fleet-grafana-github-token",
    }
    assert [v for v in merged_values(agent, "TemporaryFileSystem") if v.startswith("/home/nish")] == [
        "/home/nish:mode=0700,uid=1000,gid=1000,size=512M"
    ]
    bound = " " + " ".join(merged_values(agent, "BindReadOnlyPaths")) + " " + " ".join(merged_values(agent, "BindPaths")) + " "
    # pi's library tree, the App key dir and the seat token files the unjailed steps read.
    for tail in ("/.local/lib", "/.config/fleet-worker", "/seats", "/.local/bin"):
        assert tail in bound, tail
