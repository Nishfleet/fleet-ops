"""The overdue-issue sweep acts as the nishfleet-worker App, never the owner login (fleet-ops#10453, #10601)."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "systemd"


def test_later_sweep_mints_a_token_per_repo_and_never_falls_back() -> None:
    text = (SYSTEMD / "later-sweep.service").read_text()
    assert 'systemctl --user start "fleet-worker-github-token@$$repo.service"' in text
    assert "%t/fleet-worker-github-token/$$repo.env" in text
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
    """No detached worker launch line names the Actions-only instance (its grant would let a fooled worker dispatch a run). The restore drill runs no model, so it may."""
    files = [p for p in sorted(ROOT.rglob("*.md")) + sorted(ROOT.rglob("*.service")) if p.name != "fleet-d1-restore-drill.service"]
    for path in files:
        assert "fleet-worker-github-token@actions:" not in path.read_text(), path
