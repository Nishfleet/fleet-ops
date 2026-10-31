"""Run prompts own and kill the dev servers they start (fleet-ops#11140).

Four orphaned `wrangler dev` stacks held netcup-agent-19 at 4097M of its 4G
MemoryHigh line for 20+ minutes on 2026-10-30; the detail is in the prompt rule
itself. The worker jails' `--unshare-pid` is the layer that kills a daemonized
server when a jailed session ends (actions/runner#4601).
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT_YML = ROOT / ".github/workflows/agent.yml"

RULE_PARTS = ("setsid", "kill -TERM -- -$pgid", "kill -KILL -- -$pgid")
RULED_PROMPTS = (ROOT / "prompts/worker.md", ROOT / "prompts/orchestrator-handoff.md")


def test_prompts_that_start_dev_servers_carry_the_ownership_rule():
    for path in RULED_PROMPTS:
        text = path.read_text()
        missing = [part for part in RULE_PARTS if part not in text]
        assert not missing, (
            f"{path.relative_to(ROOT)} lost the dev-server ownership rule "
            f"(fleet-ops#11140): {missing}"
        )


def jail_lines():
    lines = [
        line
        for line in AGENT_YML.read_text().splitlines()
        if re.search(r'="\$?bwrap --dev-bind / /', line)
    ]
    assert len(lines) >= 4, (
        f"agent.yml holds {len(lines)} bwrap jail definitions, so the per-jail "
        "assertion has no source to hold"
    )
    return lines


def test_every_worker_jail_keeps_the_pid_namespace_backstop():
    leaks = [
        f"line {n}"
        for n, line in enumerate(jail_lines(), 1)
        if "--unshare-pid" not in line or "--die-with-parent" not in line
    ]
    assert not leaks, (
        "a worker jail lost --unshare-pid or --die-with-parent: the PID namespace is "
        f"what kills a daemonized dev server when a jailed session ends ({', '.join(leaks)}; "
        "actions/runner#4601, fleet-ops#11140)"
    )
