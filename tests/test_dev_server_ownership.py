"""Background dev servers are owned and killed by the sessions that start them (fleet-ops#11140).

Four orphaned `wrangler dev` stacks (PPID 1) held netcup-agent-19 at 4097M of its
4G MemoryHigh line for 20+ minutes on 2026-10-30: the session that started them
ended with no kill, and the stall backstop's only remaining move recycles the
whole runner unit. The run prompts carry the ownership rule, because the layers
behind it (the session step's process-group kill, the worker jail's PID
namespace) fire only when a session ends — a leaked server pressures the unit
the whole time the session works.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT_YML = ROOT / ".github/workflows/agent.yml"

RULE_PARTS = ("setsid", "kill -TERM -- -$pgid", "kill -KILL -- -$pgid")
RULED_PROMPTS = (ROOT / "prompts/worker.md", ROOT / "prompts/orchestrator-handoff.md")
JAIL = "--proc /proc --unshare-pid --die-with-parent"


def test_prompts_that_start_dev_servers_carry_the_ownership_rule():
    for path in RULED_PROMPTS:
        text = path.read_text()
        missing = [part for part in RULE_PARTS if part not in text]
        assert not missing, (
            f"{path.relative_to(ROOT)} lost the dev-server ownership rule "
            f"(fleet-ops#11140): {missing}"
        )


def test_worker_jails_keep_their_pid_namespace_backstop():
    count = len(re.findall(re.escape(JAIL), AGENT_YML.read_text()))
    assert count >= 4, (
        "agent.yml lost a worker jail's --unshare-pid --die-with-parent: the PID namespace is "
        "what kills a daemonized dev server when a jailed session ends (actions/runner#4601, "
        "fleet-ops#11140)"
    )
