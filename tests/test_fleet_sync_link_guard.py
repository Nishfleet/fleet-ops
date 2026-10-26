"""fleet-sync's LINK-GUARD: a dead skill-mirror link warns; dead wiring and throwaway targets still fail the unit (fleet-ops#9967)."""

import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"
WIRING_ROOTS = (".config/systemd/user", ".local/bin", ".pi/agent", "workspaces/tooling/nish-vault")
SKILLS = ".pi/agent/skills"


def expand(raw: str, home: Path) -> str:
    return raw.replace("%%", "\x00").replace("%h", str(home)).replace("\x00", "%")


def guard_commands(home: Path) -> dict[str, list[str]]:
    commands: dict[str, list[str]] = {}
    for raw in UNIT.read_text().splitlines():
        if not raw.startswith("ExecStart="):
            continue
        expanded = expand(raw[len("ExecStart=") :], home)
        if "/usr/bin/find" not in expanded:
            continue
        if "skill link dead" in expanded:
            commands["skill"] = shlex.split(expanded)
        elif "throwaway target" in expanded:
            commands["throwaway"] = shlex.split(expanded)
        elif "dead target" in expanded:
            commands["dead"] = shlex.split(expanded)
    assert set(commands) == {"skill", "throwaway", "dead"}, sorted(commands)
    return commands


def every_guard_command(home: Path) -> list[list[str]]:
    found = []
    for raw in UNIT.read_text().splitlines():
        if not raw.startswith("ExecStart="):
            continue
        expanded = expand(raw[len("ExecStart=") :], home)
        if "/usr/bin/find" in expanded and ("LINK-GUARD" in expanded or "skill link dead" in expanded):
            found.append(shlex.split(expanded))
    assert found, "no LINK-GUARD find line found in systemd/fleet-sync.service"
    return found


def run(commands: list[list[str]]) -> list[tuple[int, str]]:
    results = []
    for command in commands:
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
        results.append((proc.returncode, proc.stdout + proc.stderr))
    return results


def fleet_home(tmp_path: Path) -> Path:
    for relative in WIRING_ROOTS:
        (tmp_path / relative).mkdir(parents=True, exist_ok=True)
    (tmp_path / SKILLS).mkdir(parents=True, exist_ok=True)
    (tmp_path / ".claude/skills").mkdir(parents=True, exist_ok=True)
    return tmp_path


def test_a_skill_deleted_on_the_synced_source_warns_and_does_not_fail_the_unit(tmp_path: Path) -> None:
    home = fleet_home(tmp_path)
    (home / SKILLS / "zod").symlink_to("../../../.claude/skills/zod")
    results = run(every_guard_command(home))
    assert [code for code, _ in results] == [0] * len(results), [text for _, text in results]
    reporting = [text for _, text in results if text.strip()]
    assert len(reporting) == 1 and "skill link dead" in reporting[0]
    assert str(home / SKILLS / "zod") in reporting[0]


def test_a_dead_link_in_the_live_wiring_roots_still_fails_the_unit(tmp_path: Path) -> None:
    home = fleet_home(tmp_path)
    (home / ".local/bin/leviathan").symlink_to(home / ".local/share/leviathan/bin/leviathan")
    commands = guard_commands(home)
    results = run([commands["dead"], commands["skill"]])
    assert results[0][0] != 0
    assert "LINK-GUARD live symlink -> dead target" in results[0][1]
    assert results[1] == (0, "")


def test_a_throwaway_target_in_the_skill_mirror_still_fails_the_unit(tmp_path: Path) -> None:
    home = fleet_home(tmp_path)
    (home / "workspaces/agent-worktrees/w/skills").mkdir(parents=True)
    (home / SKILLS / "vite").symlink_to(str(home / "workspaces/agent-worktrees/w/skills/vite"))
    commands = guard_commands(home)
    results = run([commands["throwaway"], commands["dead"], commands["skill"]])
    assert results[0][0] != 0
    assert "LINK-GUARD live symlink -> throwaway target" in results[0][1]
    assert str(home / SKILLS / "vite") in results[0][1]
    assert results[1] == (0, "")
    assert results[2][0] == 0
    assert "skill link dead" in results[2][1]


def test_a_skill_link_whose_target_came_back_passes_silently(tmp_path: Path) -> None:
    home = fleet_home(tmp_path)
    (home / ".claude/skills/zod").mkdir()
    (home / SKILLS / "zod").symlink_to("../../../.claude/skills/zod")
    results = run(every_guard_command(home))
    assert all(result == (0, "") for result in results), results
