"""fleet-sync's retired fleet-pr-sweep@ step removes every link the stop line stops (fleet-ops#11544).

The guard rerun after the rm line is the whole proof: rm -f is a no-op success on
an absent path, so only the guard passing again shows the dangling links were
what got cleaned.
"""

import os
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"

STOP_MARKER = "systemctl --user stop fleet-pr-sweep@"
RM_MARKER = "rm -f %h/.config/systemd/user/fleet-pr-sweep@"
GUARD_MARKER = "LINK-GUARD live symlink -> dead target"


def expand(raw: str, home: Path) -> str:
    return raw.replace("%%", "\x00").replace("%h", str(home)).replace("\x00", "%")


def exec_raw(marker: str) -> str:
    for raw in UNIT.read_text().splitlines():
        if raw.startswith("ExecStart=") and marker in raw:
            return raw[len("ExecStart="):]
    raise AssertionError(f"no {marker!r} line found in systemd/fleet-sync.service")


def argv_for(marker: str, home: Path) -> list[str]:
    argv = shlex.split(expand(exec_raw(marker), home))
    if argv[0].startswith("-"):
        argv[0] = argv[0][1:]
    return argv


def stopped_instances() -> list[str]:
    argv = argv_for(STOP_MARKER, Path("/home/x"))
    stop = argv.index("stop")
    units = [a for a in argv[stop + 1:] if a.startswith("fleet-pr-sweep@")]
    assert units
    return units


def guard_roots(home: Path) -> list[str]:
    argv = argv_for(GUARD_MARKER, home)
    roots = []
    for arg in argv[1:]:
        if arg.startswith("-"):
            break
        roots.append(arg)
    assert roots
    return roots


def rm_command(home: Path) -> list[str]:
    return argv_for(RM_MARKER, home)


def guard_command(home: Path) -> list[str]:
    return argv_for(GUARD_MARKER, home)


def run(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, check=False)


def dangling_links(home: Path, clone: Path) -> dict[str, Path]:
    target = clone / "systemd" / "fleet-pr-sweep@.timer"
    links = {
        "fleet-pr-sweep@.service": target,
        "fleet-pr-sweep@.timer": target,
    }
    for instance in stopped_instances():
        links[instance] = target
        links[f"timers.target.wants/{instance}"] = target
    return links


def test_rm_line_names_every_link_the_stop_line_stops():
    stopped = set(stopped_instances())
    assert stopped == {
        "fleet-pr-sweep@fleet-ops.timer",
        "fleet-pr-sweep@0509.timer",
        "fleet-pr-sweep@drive.timer",
        "fleet-pr-sweep@aiconverter-app.timer",
        "fleet-pr-sweep@TinyStudio.io-public.timer",
        "fleet-pr-sweep@siterep-public.timer",
        "fleet-pr-sweep@rera-report-card.timer",
        "fleet-pr-sweep@seo-fix-kit.timer",
    }
    home = "/home/x"
    argv = argv_for(RM_MARKER, Path(home))
    user = home + "/.config/systemd/user/"
    paths = {p.replace(user, "", 1) for p in argv if p.startswith(user)}
    expected = set(stopped) | {"fleet-pr-sweep@.service", "fleet-pr-sweep@.timer"}
    expected |= {f"timers.target.wants/{name}" for name in stopped}
    assert paths == expected, (paths, expected)


def test_retired_links_dangle_the_guard_fails_then_the_rm_line_heals(tmp_path):
    home = tmp_path / "home"
    for root in guard_roots(home):
        Path(root).mkdir(parents=True)
    clone = tmp_path / "clone"
    clone.mkdir()
    (home / ".config/systemd/user/timers.target.wants").mkdir()
    for name, to in dangling_links(home, clone).items():
        os.symlink(to, home / ".config/systemd/user" / name)

    before = run(guard_command(home))
    assert before.returncode != 0
    assert GUARD_MARKER in before.stdout
    assert "fleet-pr-sweep@" in before.stdout + before.stderr

    proc = run(rm_command(home))
    assert proc.returncode == 0, proc.stderr

    after = run(guard_command(home))
    assert after.returncode == 0, after.stdout + after.stderr
    assert GUARD_MARKER not in after.stdout
