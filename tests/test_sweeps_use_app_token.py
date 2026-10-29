"""The hourly sweeps act as the nishfleet-worker App, never the owner login (fleet-ops#10453, #10601)."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "systemd"


def test_pr_sweep_mints_and_loads_the_app_token() -> None:
    text = (SYSTEMD / "fleet-pr-sweep@.service").read_text()
    assert "Requires=fleet-worker-github-token@actions:%i.service" in text
    assert "After=fleet-worker-github-token@actions:%i.service" in text
    assert "EnvironmentFile=%t/fleet-tokens/worker/actions:%i.env" in text
    assert 'ExecStartPre=/bin/sh -c \'test -n "$$GH_TOKEN"\'' in text
    assert "env -u GH_TOKEN" not in text


def test_pr_sweep_revokes_its_token_before_the_next_sweep() -> None:
    text = (SYSTEMD / "fleet-pr-sweep@.service").read_text()
    stop = [line for line in text.splitlines() if line.startswith("ExecStopPost=")]
    assert len(stop) == 1
    assert "gh api -X DELETE installation/token" in stop[0]
    assert "rm -f %t/fleet-tokens/worker/actions:%i.env" in stop[0]
    assert stop[0].index("installation/token") < stop[0].index("rm -f")


def test_later_sweep_mints_a_token_per_repo_and_never_falls_back() -> None:
    text = (SYSTEMD / "later-sweep.service").read_text()
    assert 'systemctl --user start "fleet-worker-github-token@$$repo.service"' in text
    assert "%t/fleet-tokens/worker/$$repo.env" in text
    assert text.index("fleet-worker-github-token@") < text.index("gh issue list")
    assert text.index("fleet-worker-github-token@") < text.index("gh issue edit")
    assert "env -u GH_TOKEN" not in text
    assert "sweep-" not in text


def test_only_the_actions_instance_asks_for_actions_write() -> None:
    text = (SYSTEMD / "fleet-worker-github-token@.service").read_text()
    escaped_quote = chr(92) * 2 + '"'
    grant = json.dumps({"actions": "write"}, separators=(",", ":")).replace('"', escaped_quote)
    assert text.count(grant) == 1
    assert "repo=$${inst#actions:}" in text
    line = next(line for line in text.splitlines() if line.startswith('  [ "$$repo"'))
    assert '"$$repo" = "$$inst"' in line, line
    assert grant in line, line


def test_no_worker_launch_line_asks_for_the_actions_instance() -> None:
    """No detached worker launch line names the Actions-only instance (its grant would let a fooled worker dispatch a run)."""
    files = [p for p in sorted(ROOT.rglob("*.md")) + sorted(ROOT.rglob("*.service")) if p.name != "fleet-pr-sweep@.service"]
    for path in files:
        assert "fleet-worker-github-token@actions:" not in path.read_text(), path
