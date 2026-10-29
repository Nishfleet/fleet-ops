"""The hourly sweeps act as the nishfleet-worker App, never the owner login (fleet-ops#10453, #10601)."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "systemd"
PR_SWEEP = SYSTEMD / "fleet-pr-sweep@.service"
LATER_SWEEP = SYSTEMD / "later-sweep.service"
TOKEN_UNIT = SYSTEMD / "fleet-worker-github-token@.service"
ACTIONS_INSTANCE = "fleet-worker-github-token@actions:%i.service"
ACTIONS_ENV = "%t/fleet-worker-github-token/actions:%i.env"


def keys(path: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for line in path.read_text().replace("\\\n", "").splitlines():
        if line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        found.setdefault(key, []).append(value)
    return found


def test_pr_sweep_mints_and_loads_the_app_token() -> None:
    unit = keys(PR_SWEEP)
    assert ACTIONS_INSTANCE in unit["Requires"]
    assert ACTIONS_INSTANCE in unit["After"]
    assert unit["EnvironmentFile"] == [ACTIONS_ENV]
    assert unit["ExecStartPre"] == ['/bin/sh -c \'test -n "$$GH_TOKEN"\'']
    assert not any("env -u GH_TOKEN" in value for values in unit.values() for value in values)


def test_later_sweep_mints_a_token_per_repo_and_never_falls_back() -> None:
    program = keys(LATER_SWEEP)["ExecStart"]
    assert len(program) == 1
    mint = 'systemctl --user start "fleet-worker-github-token@$$repo.service"'
    assert program[0].count(mint) == 1
    assert "%t/fleet-worker-github-token/$$repo.env" in program[0]
    assert program[0].index(mint) < program[0].index("gh issue list") < program[0].index("gh issue edit")
    assert "env -u GH_TOKEN" not in program[0]
    assert "sweep-" not in program[0]


def test_only_the_actions_instance_asks_for_actions_write() -> None:
    program = keys(TOKEN_UNIT)["ExecStart"]
    assert len(program) == 1
    escaped_quote = chr(92) * 2 + '"'
    grant = json.dumps({"actions": "write"}, separators=(",", ":")).replace('"', escaped_quote)
    assert "repo=$${inst#actions:}" in program[0]
    assert program[0].count(grant) == 1
    assert f'[ "$$repo" = "$$inst" ] || perms="{grant}"' in program[0]


def test_no_worker_launch_line_asks_for_the_actions_instance() -> None:
    """No detached worker launch line names the Actions-only instance (its grant would let a fooled worker dispatch a run)."""
    files = [p for p in sorted(ROOT.rglob("*.md")) + sorted(ROOT.rglob("*.service")) if p.name != "fleet-pr-sweep@.service"]
    for path in files:
        assert "fleet-worker-github-token@actions:" not in path.read_text(), path
