#!/usr/bin/env python3
"""Managed PreToolUse hook for native Codex Agent/spawn_agent calls."""

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from agent_governor.broker import ToolBroker  # noqa: E402
from agent_governor.manifest import load_manifest  # noqa: E402
from agent_governor.trace import TraceStore  # noqa: E402
from integrations.certified_policy import evaluate_certified  # noqa: E402
from integrations.codex_launch_policy import LUNA_PROVIDER  # noqa: E402

DEFAULT_ROOT = Path("/home/nish/.local/share/agent-governor/codex-launch-v1")
AGENTS_DIR = Path("/home/nish/.codex/agents")
RESERVED_ROOT_ENV = "CODEX_AGENT_GOVERNOR_ROOT"


def _current_role(agent_type: str) -> tuple[str, str | None]:
    if re.fullmatch(r"[A-Za-z0-9_-]+", agent_type) is None:
        raise ValueError("invalid role")
    document = tomllib.loads((AGENTS_DIR / f"{agent_type}.toml").read_text(encoding="utf-8"))
    model = document.get("model")
    effort = document.get("model_reasoning_effort")
    if not isinstance(model, str):
        raise ValueError("role model unresolved")
    return model, effort if isinstance(effort, str) else None


def _output(allowed: bool, reason: str) -> None:
    decision = "allow" if allowed else "deny"
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}, sort_keys=True))


def main() -> int:
    try:
        # Caller root overrides fail closed; certified root is fixed.
        if RESERVED_ROOT_ENV in os.environ:
            _output(False, "agent governor: reserved root override denied")
            return 0
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict) or payload.get("hook_event_name") != "PreToolUse" or payload.get("tool_name") != "Agent":
            _output(False, "agent governor: unexpected hook input")
            return 0
        tool_input = payload.get("tool_input")
        if not isinstance(tool_input, dict):
            _output(False, "agent governor: missing Agent input")
            return 0
        sanitized: dict[str, Any] = {
            key: tool_input.get(key) for key in ("agent_type", "model", "reasoning_effort", "fork_turns")
        }
        # Certified Codex role surface always supplies the OpenAI provider.
        # Caller provider overrides fail closed.
        caller_provider = tool_input.get("provider")
        if caller_provider not in (None, LUNA_PROVIDER):
            _output(False, "agent governor: provider_override_denied")
            return 0
        sanitized["provider"] = LUNA_PROVIDER
        agent_type = sanitized.get("agent_type")
        if isinstance(agent_type, str):
            current_model, current_effort = _current_role(agent_type)
            if sanitized.get("model") not in (None, current_model):
                _output(False, "agent governor: live_role_model_override")
                return 0
            sanitized["model"] = current_model
            if sanitized.get("reasoning_effort") is None:
                sanitized["reasoning_effort"] = current_effort
        root = DEFAULT_ROOT
        manifest, _, _ = load_manifest(root)
        trace = TraceStore(root, manifest.trace_path)
        broker = ToolBroker(manifest, trace=trace)
        broker_decision = broker.decide("spawn_agent", sanitized)
        if not broker_decision.allowed:
            _output(False, f"agent governor: {broker_decision.reason}")
            return 0
        policy = evaluate_certified(root, sanitized)
        if not policy["allowed"]:
            trace.append("capability_denied", agent_id=manifest.agent_id, details={"reason": policy["reason"]})
            _output(False, f"agent governor: {policy['reason']}")
            return 0
        _output(True, "agent governor: certified launch")
    except Exception:
        _output(False, "agent governor: fail-closed launch error")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
