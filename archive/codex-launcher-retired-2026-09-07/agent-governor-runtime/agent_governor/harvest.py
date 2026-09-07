"""Append-only proposed-eval harvesting, isolated from sealed suites."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .manifest import Manifest
from .security import ValidationError, append_jsonl, canonical_json_bytes, sha256_bytes, secure_root


def _validate_candidate(candidate: Any) -> dict[str, Any]:
    if not isinstance(candidate, dict):
        raise ValidationError("harvest candidate must be an object")
    if "id" not in candidate or "input" not in candidate or "expected_output" not in candidate:
        raise ValidationError("harvest candidate needs id, input, and expected_output")
    if not isinstance(candidate["id"], str) or not candidate["id"] or "\x00" in candidate["id"]:
        raise ValidationError("harvest candidate id must be a non-empty string")
    return {
        "id": candidate["id"],
        "input": candidate["input"],
        "expected_output": candidate["expected_output"],
    }


def harvest(
    root: str | Path,
    manifest: Manifest,
    candidate: Any,
    *,
    source: str = "machine",
) -> dict[str, Any]:
    """Queue a proposal; there is intentionally no suite mutation parameter."""

    root_path = secure_root(root)
    clean = _validate_candidate(candidate)
    proposal = {
        "schema_version": 1,
        "proposal_sha256": sha256_bytes(canonical_json_bytes(clean)),
        "agent_id": manifest.agent_id,
        "source": source[:128],
        "case": clean,
    }
    append_jsonl(root_path, manifest.harvest_path, proposal)
    return proposal
