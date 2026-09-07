"""Create and run the deterministic local canary fixture."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .broker import ToolBroker
from .detectors import ACTION_RESTART_CLEAN, GovernedRun
from .evals import certify, verify_certificate
from .manifest import load_manifest
from .security import PathSecurityError, atomic_write_bytes, atomic_write_json, secure_root
from .trace import TraceStore


EXAMPLE_MANIFEST: dict[str, Any] = {
    "schema_version": 1,
    "policy_version": "agent-governor-policy-v1",
    "identity": {"id": "canary-agent", "version": "1.0.0"},
    "runner": {"path": "runner.py", "args": [], "timeout_seconds": 3},
    "allowed_tools": ["echo", "write_artifact"],
    "denied_tools": ["shell", "network", "read_secret"],
    "budgets": {"max_steps": 4, "max_cost": 1.0},
    "required_eval_score": 1.0,
    "autonomy_tier": "observe",
    "evals": {
        "public": ["evals/public.json"],
        "sealed": [".governance/sealed/evals.json"],
    },
    "governance": {"promotion_successes": 3, "recall_failures": 2, "no_progress_steps": 3},
    "certificate_path": ".governance/certificate.json",
    "trace_path": ".governance/traces.jsonl",
    "registry_path": ".governance/evidence.json",
    "recall_path": ".governance/recalls.jsonl",
    "harvest_path": ".governance/harvest/proposed.jsonl",
}

RUNNER_SOURCE = '''#!/usr/bin/env python3
import json
import sys


request = json.load(sys.stdin)
if request.get("op") == "sum":
    result = {"result": int(request["a"]) + int(request["b"])}
elif request.get("op") == "echo":
    result = {"echo": request["text"]}
else:
    result = {"error": "unknown operation"}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
'''

PUBLIC_EVALS = {
    "schema_version": 1,
    "cases": [
        {"id": "public-sum", "input": {"op": "sum", "a": 2, "b": 3}, "expected_output": {"result": 5}},
        {"id": "public-echo", "input": {"op": "echo", "text": "public"}, "expected_output": {"echo": "public"}},
    ],
}

SEALED_EVALS = {
    "schema_version": 1,
    "cases": [
        {"id": "sealed-sum", "input": {"op": "sum", "a": -4, "b": 9}, "expected_output": {"result": 5}},
        {"id": "sealed-echo", "input": {"op": "echo", "text": "sealed"}, "expected_output": {"echo": "sealed"}},
    ],
}


def init_example(root: str | Path, *, refuse_nonempty: bool = True) -> Path:
    raw_root = Path(root)
    if raw_root.exists() and raw_root.is_symlink():
        raise PathSecurityError("example root must not be a symlink")
    root_path = secure_root(root, create=True)
    if refuse_nonempty and any(root_path.iterdir()):
        raise PathSecurityError(f"refusing to initialize a non-empty directory: {root_path}")
    # Directory creation is performed by the safe atomic writers as needed.
    atomic_write_json(root_path, "manifest.json", EXAMPLE_MANIFEST, mode=0o600)
    atomic_write_bytes(root_path, "runner.py", RUNNER_SOURCE.encode("utf-8"), mode=0o700)
    atomic_write_json(root_path, "evals/public.json", PUBLIC_EVALS, mode=0o600)
    atomic_write_json(root_path, ".governance/sealed/evals.json", SEALED_EVALS, mode=0o600)
    return root_path


def run_canary(root: str | Path) -> dict[str, Any]:
    root_path = init_example(root)
    manifest, _, _ = load_manifest(root_path)
    certification = certify(root_path)
    verification = verify_certificate(root_path, record_invalid=False)
    trace = TraceStore(root_path, manifest.trace_path)
    broker = ToolBroker(manifest, trace=trace)
    allowed = broker.decide("echo", {"text": "canary"})
    denied = broker.decide("shell", {"command": "echo unsafe"})
    governed_run = GovernedRun(
        manifest,
        trace=trace,
        state={
            "task_artifacts": {"canary": "kept"},
            "tool_artifacts": {"result": 5},
            "assistant_narration": ["discarded"],
            "reasoning": ["discarded"],
        },
    )
    governed_run.step(action="read", observation="unchanged", progress=False)
    governed_run.step(action="read", observation="unchanged", progress=False)
    loop_action = governed_run.step(action="read", observation="unchanged", progress=False)
    trace_summary = trace.summary()
    restart_state = governed_run.state
    checks = {
        "certification_passed": certification.passed,
        "certificate_verified": verification.valid,
        "broker_allow": allowed.allowed and allowed.reason == "allowlisted",
        "broker_deny": not denied.allowed and denied.reason == "hard_denylist",
        "trace_valid": trace_summary["chain_valid"],
        "restart_clean": (
            loop_action == ACTION_RESTART_CLEAN
            and restart_state.get("task_artifacts") == {"canary": "kept"}
            and restart_state.get("tool_artifacts") == {"result": 5}
            and restart_state.get("assistant_narration") == []
            and restart_state.get("reasoning") == []
            and restart_state.get("restart_count") == 1
        ),
    }
    return {
        "root": str(root_path),
        "certification": certification.to_dict(),
        "verification": verification.to_dict(),
        "broker": {"allowed": allowed.to_dict(), "denied": denied.to_dict()},
        "trajectory_action": loop_action,
        "trace": trace_summary,
        "checks": checks,
        "valid": all(checks.values()),
    }
