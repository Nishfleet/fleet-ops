"""Versioned manifest parsing and validation."""

from __future__ import annotations

from dataclasses import dataclass
import math
from pathlib import Path
from typing import Any, Mapping

from .security import PathSecurityError, ValidationError, read_json, safe_path, secure_root


AUTONOMY_TIERS = ("observe", "dry_run", "bounded_act", "act")
SCHEMA_VERSION = 1


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValidationError(f"{field} must be a non-empty string")
    return value


def _relative_string(value: Any, field: str) -> str:
    value = _string(value, field)
    candidate = Path(value)
    if (
        candidate == Path(".")
        or candidate.is_absolute()
        or value.startswith("~")
        or any(part == ".." for part in candidate.parts)
    ):
        raise ValidationError(f"{field} must be a safe relative path")
    return value


def _string_list(value: Any, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or any(
        not isinstance(item, str) or not item or "\x00" in item for item in value
    ):
        raise ValidationError(f"{field} must be a list of non-empty strings")
    if len(set(value)) != len(value):
        raise ValidationError(f"{field} must not contain duplicates")
    return tuple(value)


@dataclass(frozen=True)
class Manifest:
    schema_version: int
    policy_version: str
    agent_id: str
    agent_version: str
    runner_path: str
    runner_args: tuple[str, ...]
    runner_timeout_seconds: float
    allowed_tools: frozenset[str]
    denied_tools: frozenset[str]
    max_steps: int
    max_cost: float
    required_eval_score: float
    autonomy_tier: str
    public_eval_paths: tuple[str, ...]
    sealed_eval_paths: tuple[str, ...]
    certificate_path: str
    trace_path: str
    registry_path: str
    recall_path: str
    harvest_path: str
    promotion_successes: int
    recall_failures: int
    no_progress_steps: int

    @property
    def eval_paths(self) -> tuple[tuple[str, str], ...]:
        return tuple(("public", path) for path in self.public_eval_paths) + tuple(
            ("sealed", path) for path in self.sealed_eval_paths
        )

    @property
    def runner(self) -> str:
        return self.runner_path

    @classmethod
    def from_dict(cls, document: Mapping[str, Any]) -> "Manifest":
        if not isinstance(document, Mapping):
            raise ValidationError("manifest must be a JSON object")
        schema_version = document.get("schema_version")
        if isinstance(schema_version, bool) or schema_version != SCHEMA_VERSION:
            raise ValidationError(f"schema_version must be {SCHEMA_VERSION}")
        policy_version = _string(document.get("policy_version"), "policy_version")

        identity = document.get("identity")
        if not isinstance(identity, Mapping):
            raise ValidationError("identity must be an object")
        agent_id = _string(identity.get("id"), "identity.id")
        agent_version = _string(identity.get("version"), "identity.version")

        runner = document.get("runner")
        if not isinstance(runner, Mapping):
            raise ValidationError("runner must be an object")
        runner_path = _relative_string(runner.get("path"), "runner.path")
        runner_args = _string_list(runner.get("args", []), "runner.args")
        runner_timeout = runner.get("timeout_seconds", 5.0)
        if isinstance(runner_timeout, bool) or not isinstance(runner_timeout, (int, float)):
            raise ValidationError("runner.timeout_seconds must be a positive number")
        if not math.isfinite(float(runner_timeout)) or runner_timeout <= 0 or runner_timeout > 300:
            raise ValidationError("runner.timeout_seconds must be in (0, 300]")

        allowed = frozenset(_string_list(document.get("allowed_tools", []), "allowed_tools"))
        denied = frozenset(_string_list(document.get("denied_tools", []), "denied_tools"))
        if allowed & denied:
            raise ValidationError("a tool cannot be both allowed and denied")

        budgets = document.get("budgets")
        if not isinstance(budgets, Mapping):
            raise ValidationError("budgets must be an object")
        max_steps = budgets.get("max_steps")
        if isinstance(max_steps, bool) or not isinstance(max_steps, int) or max_steps < 1:
            raise ValidationError("budgets.max_steps must be a positive integer")
        max_cost = budgets.get("max_cost")
        if (
            isinstance(max_cost, bool)
            or not isinstance(max_cost, (int, float))
            or not math.isfinite(float(max_cost))
            or max_cost < 0
        ):
            raise ValidationError("budgets.max_cost must be a non-negative number")

        required_score = document.get("required_eval_score")
        if isinstance(required_score, bool) or not isinstance(required_score, (int, float)):
            raise ValidationError("required_eval_score must be a number")
        if not math.isfinite(float(required_score)) or not 0 <= required_score <= 1:
            raise ValidationError("required_eval_score must be between 0 and 1")
        autonomy_tier = _string(document.get("autonomy_tier"), "autonomy_tier")
        if autonomy_tier not in AUTONOMY_TIERS:
            raise ValidationError(f"autonomy_tier must be one of {AUTONOMY_TIERS}")

        evals = document.get("evals")
        if not isinstance(evals, Mapping):
            raise ValidationError("evals must be an object with public and sealed lists")
        public = _string_list(evals.get("public", []), "evals.public")
        sealed = _string_list(evals.get("sealed", []), "evals.sealed")
        if not public or not sealed:
            raise ValidationError("both public and sealed eval suites are required")
        if set(public) & set(sealed):
            raise ValidationError("an eval file cannot be both public and sealed")
        for field, paths in (("evals.public", public), ("evals.sealed", sealed)):
            for path in paths:
                _relative_string(path, f"{field} path")

        governance = document.get("governance", {})
        if not isinstance(governance, Mapping):
            raise ValidationError("governance must be an object")

        def positive_int(name: str, default: int) -> int:
            value = governance.get(name, default)
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise ValidationError(f"governance.{name} must be a positive integer")
            return value

        return cls(
            schema_version=schema_version,
            policy_version=policy_version,
            agent_id=agent_id,
            agent_version=agent_version,
            runner_path=runner_path,
            runner_args=runner_args,
            runner_timeout_seconds=float(runner_timeout),
            allowed_tools=allowed,
            denied_tools=denied,
            max_steps=max_steps,
            max_cost=float(max_cost),
            required_eval_score=float(required_score),
            autonomy_tier=autonomy_tier,
            public_eval_paths=public,
            sealed_eval_paths=sealed,
            certificate_path=_relative_string(
                document.get("certificate_path", ".governance/certificate.json"), "certificate_path"
            ),
            trace_path=_relative_string(
                document.get("trace_path", ".governance/traces.jsonl"), "trace_path"
            ),
            registry_path=_relative_string(
                document.get("registry_path", ".governance/evidence.json"), "registry_path"
            ),
            recall_path=_relative_string(
                document.get("recall_path", ".governance/recalls.jsonl"), "recall_path"
            ),
            harvest_path=_relative_string(
                document.get("harvest_path", ".governance/harvest/proposed.jsonl"), "harvest_path"
            ),
            promotion_successes=positive_int("promotion_successes", 3),
            recall_failures=positive_int("recall_failures", 3),
            no_progress_steps=positive_int("no_progress_steps", 3),
        )


def load_manifest(root: str | Path, relative: str = "manifest.json") -> tuple[Manifest, dict[str, Any], bytes]:
    root_path = secure_root(root)
    document, raw = read_json(root_path, relative)
    if not isinstance(document, dict):
        raise ValidationError("manifest must be a JSON object")
    manifest = Manifest.from_dict(document)
    # Resolve all configured governed files now, before any runner or eval work.
    manifest_file = safe_path(root_path, relative, must_exist=True, expect="file")
    runner_file = safe_path(root_path, manifest.runner_path, must_exist=True, expect="file")
    input_files = {manifest_file, runner_file}
    for _, eval_path in manifest.eval_paths:
        eval_file = safe_path(root_path, eval_path, must_exist=True, expect="file")
        input_files.add(eval_file)
    output_paths = (
        manifest.certificate_path,
        manifest.trace_path,
        manifest.registry_path,
        manifest.recall_path,
        manifest.harvest_path,
        f"{manifest.trace_path}.lock",
    )
    normalized_outputs: set[Path] = set()
    for output in output_paths:
        output_path = (root_path / output).resolve(strict=False)
        if not output_path.is_relative_to(root_path):
            raise ValidationError(f"configured output path escapes the governance root: {output}")
        if output_path in input_files:
            raise ValidationError(f"configured output path overlaps a governed input: {output}")
        if output_path in normalized_outputs:
            raise ValidationError(f"configured output paths overlap: {output}")
        normalized_outputs.add(output_path)
    return manifest, document, raw
