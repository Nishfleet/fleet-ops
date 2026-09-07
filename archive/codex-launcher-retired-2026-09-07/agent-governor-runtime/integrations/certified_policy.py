"""Invoke the content-bound certified launch policy without prompt data."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Mapping

from agent_governor.evals import verify_certificate
from agent_governor.manifest import load_manifest


def evaluate_certified(root: Path, request: Mapping[str, Any]) -> dict[str, Any]:
    verification = verify_certificate(root)
    if not verification.valid:
        raise RuntimeError(f"certificate_invalid:{verification.reason}")
    manifest, _, _ = load_manifest(root)
    runner = (root / manifest.runner_path).resolve()
    completed = subprocess.run(
        ["/usr/bin/python3", str(runner)],
        input=json.dumps(dict(request), sort_keys=True, separators=(",", ":")),
        text=True,
        capture_output=True,
        timeout=manifest.runner_timeout_seconds,
        check=False,
        env={"PATH": "/usr/bin:/bin"},
    )
    if completed.returncode != 0:
        raise RuntimeError("certified_policy_failed")
    result = json.loads(completed.stdout)
    if not isinstance(result, dict) or not isinstance(result.get("allowed"), bool) or not isinstance(result.get("reason"), str):
        raise RuntimeError("certified_policy_invalid_output")
    return result
