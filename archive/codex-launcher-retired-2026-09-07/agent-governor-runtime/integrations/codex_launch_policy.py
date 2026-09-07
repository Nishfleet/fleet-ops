#!/usr/bin/env python3
"""Deterministic policy shared by Codex launch wrappers and evals."""

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, Mapping

LUNA_MODEL = "gpt-5.6-luna"
SOL_MODEL = "gpt-5.6-sol"
LUNA_PROVIDER = "openai"
LUNA_ROLE = "executor_luna"
APPROVED_MODELS = frozenset({LUNA_MODEL, SOL_MODEL})
# Sol's efforts, allow-listed rather than pinned to a single value.
#
# `medium` remains the orchestrator identity: Sol at medium orchestrates,
# integrates, reviews and proves, and performs no implementation edits. That
# rule is unchanged.
#
# `xhigh` is added 2026-08-09 on Nish's explicit instruction ("move the
# burnover to GPT five point six Sol Xhigh") so the recurring fleet burn -
# product scouts and improvement loops, via implementation-worker-sol-xhigh -
# can move off the Grok lane. Both of that lane's legs (SuperGrok and Cursor)
# are Grok 4.5 and so share one pool: measured that day, 71 consecutive runs
# fell through to Cursor and took it 38% -> 2% with nobody choosing it.
#
# Widening the allow-list is the in-band change. The alternative - calling
# libexec/codex-real directly to dodge the wrapper - is a policy violation,
# because the wrapper and the managed PreToolUse hook are complementary
# fail-closed controls.
SOL_EFFORTS = frozenset({"medium", "xhigh"})
CERTIFIED_ROLE_DEFAULTS: dict[str, list[str | None]] = {}


def _role_defaults(agent_type: str | None, agents_dir: Path | None) -> tuple[str | None, str | None, bool]:
    if not agent_type:
        return None, None, agent_type is None
    if re.fullmatch(r"[A-Za-z0-9_-]+", agent_type) is None:
        return None, None, False
    if CERTIFIED_ROLE_DEFAULTS:
        values = CERTIFIED_ROLE_DEFAULTS.get(agent_type)
        if values is None:
            return None, None, False
        return values[0], values[1], values[0] is not None
    if agents_dir is None:
        return None, None, False
    role_path = agents_dir / f"{agent_type}.toml"
    if not role_path.is_file():
        return None, None, False
    try:
        document = tomllib.loads(role_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None, None, False
    model = document.get("model")
    effort = document.get("model_reasoning_effort")
    valid_model = model if isinstance(model, str) else None
    valid_effort = effort if isinstance(effort, str) else None
    return valid_model, valid_effort, valid_model is not None


def evaluate_launch(request: Mapping[str, Any], agents_dir: Path | None = None) -> dict[str, Any]:
    agent_type = request.get("agent_type") if isinstance(request.get("agent_type"), str) else None
    explicit_model = request.get("model") if isinstance(request.get("model"), str) else None
    explicit_effort = request.get("reasoning_effort") if isinstance(request.get("reasoning_effort"), str) else None
    provider = request.get("provider") if isinstance(request.get("provider"), str) else None
    fork_turns = request.get("fork_turns")
    role_model, role_effort, role_valid = _role_defaults(agent_type, agents_dir)

    if not role_valid:
        return {"allowed": False, "reason": "role_unresolved"}

    if explicit_model and role_model and explicit_model != role_model:
        return {"allowed": False, "reason": "role_model_override"}
    model = explicit_model or role_model
    effort = explicit_effort or role_effort
    if model is None:
        return {"allowed": False, "reason": "model_unresolved"}
    if "terra" in model.lower():
        return {"allowed": False, "reason": "terra_denied"}
    if model not in APPROVED_MODELS:
        return {"allowed": False, "reason": "model_unapproved"}
    if model == SOL_MODEL:
        if effort not in SOL_EFFORTS:
            return {"allowed": False, "reason": "sol_effort_unapproved"}
        if provider != LUNA_PROVIDER:
            return {"allowed": False, "reason": "sol_requires_openai_provider"}
    if model == LUNA_MODEL:
        if effort != "max":
            return {"allowed": False, "reason": "luna_requires_max"}
        if fork_turns != "none":
            return {"allowed": False, "reason": "luna_requires_fork_none"}
        # Missing provider/role is a denial for Luna, not an allow.
        if provider != LUNA_PROVIDER:
            return {"allowed": False, "reason": "luna_requires_openai_provider"}
        if agent_type != LUNA_ROLE:
            return {"allowed": False, "reason": "luna_requires_executor_luna"}
    return {"allowed": True, "reason": "policy_allow"}


def main() -> int:
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        agents_dir = Path(os.environ.get("CODEX_AGENTS_DIR", "/home/nish/.codex/agents"))
        result = evaluate_launch(request, agents_dir)
    except Exception:
        result = {"allowed": False, "reason": "invalid_request"}
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
