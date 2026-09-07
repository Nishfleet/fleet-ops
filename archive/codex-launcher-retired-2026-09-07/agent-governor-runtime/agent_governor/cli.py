"""Command-line interface for the local governance primitives."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Sequence

from .broker import ToolBroker
from .example import init_example, run_canary
from .evals import certify, verify_certificate
from .harvest import harvest
from .manifest import load_manifest
from .registry import EvidenceRegistry
from .security import (
    GovernanceError,
    PathSecurityError,
    read_json,
    read_jsonl,
    reject_nonfinite_json,
    safe_path,
    secure_root,
)
from .trace import TraceStore


def _json_output(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False))


def _root_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", default=".", help="governance root directory")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agent-governor", description="Machine-gated local agent governance")
    commands = parser.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init-example", help="create a local public/sealed canary fixture")
    _root_argument(init)

    certify_parser = commands.add_parser("certify", help="run public and sealed evals and issue a certificate")
    _root_argument(certify_parser)
    certify_parser.add_argument("--manifest", default="manifest.json")
    certify_parser.add_argument("--no-record-evidence", action="store_true")

    verify = commands.add_parser("verify", help="verify certificate inputs, hash, and required score")
    _root_argument(verify)
    verify.add_argument("--manifest", default="manifest.json")
    verify.add_argument("--certificate")

    broker = commands.add_parser("broker", help="make one auditable external-tool decision")
    _root_argument(broker)
    broker.add_argument("--manifest", default="manifest.json")
    broker.add_argument("--tool", required=True)
    broker.add_argument("--args-json", default="null")

    inspect = commands.add_parser("inspect", help="inspect manifest, evidence, trace, and certificate status")
    _root_argument(inspect)
    inspect.add_argument("--manifest", default="manifest.json")

    recall = commands.add_parser("recall", help="machine-record a recall for an agent")
    _root_argument(recall)
    recall.add_argument("--manifest", default="manifest.json")
    recall.add_argument("--reason", required=True)

    harvest_parser = commands.add_parser("harvest", help="append a proposed eval case to the harvest queue")
    _root_argument(harvest_parser)
    harvest_parser.add_argument("--manifest", default="manifest.json")
    source = harvest_parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--case-json")
    source.add_argument("--case-file")
    harvest_parser.add_argument("--source", default="machine")

    canary = commands.add_parser("canary", help="run the end-to-end local governed canary")
    _root_argument(canary)
    return parser


def _load(root: str, manifest_relative: str):
    return load_manifest(root, manifest_relative)


def _parse_json_value(raw: str, label: str) -> Any:
    try:
        return json.loads(raw, parse_constant=reject_nonfinite_json)
    except (json.JSONDecodeError, ValueError) as exc:
        raise GovernanceError(f"{label} must be valid JSON: {exc}") from exc


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "init-example":
            root = init_example(args.root)
            _json_output({"initialized": True, "root": str(root)})
            return 0
        if args.command == "canary":
            result = run_canary(args.root)
            _json_output(result)
            return 0 if result["valid"] else 1

        manifest, document, _ = _load(args.root, args.manifest)
        root = secure_root(args.root)
        if args.command == "certify":
            result = certify(root, args.manifest, record_evidence=not args.no_record_evidence)
            _json_output(result.to_dict())
            return 0 if result.passed else 1
        if args.command == "verify":
            result = verify_certificate(root, args.manifest, args.certificate)
            _json_output(result.to_dict())
            return 0 if result.valid else 1
        if args.command == "broker":
            arguments = _parse_json_value(args.args_json, "--args-json")
            trace = TraceStore(root, manifest.trace_path)
            decision = ToolBroker(manifest, trace=trace, manifest_relative=args.manifest).decide(args.tool, arguments)
            _json_output(decision.to_dict())
            return 0 if decision.allowed else 1
        if args.command == "inspect":
            verification = verify_certificate(root, args.manifest, record_invalid=False)
            safe_path(root, manifest.registry_path, must_exist=True, expect="file", reject_symlink=True)
            evidence = EvidenceRegistry(root, manifest).status()
            trace = TraceStore(root, manifest.trace_path)
            trace_summary = trace.summary()
            _json_output(
                {
                    "manifest": {
                        "schema_version": manifest.schema_version,
                        "policy_version": manifest.policy_version,
                        "agent_id": manifest.agent_id,
                        "agent_version": manifest.agent_version,
                        "autonomy_tier": manifest.autonomy_tier,
                        "allowed_tools": sorted(manifest.allowed_tools),
                        "denied_tools": sorted(manifest.denied_tools),
                        "budgets": {"max_steps": manifest.max_steps, "max_cost": manifest.max_cost},
                        "required_eval_score": manifest.required_eval_score,
                    },
                    "evidence": evidence,
                    "certificate": verification.to_dict(),
                    "trace": trace_summary,
                }
            )
            return 0 if verification.valid and trace_summary["chain_valid"] else 1
        if args.command == "recall":
            trace = TraceStore(root, manifest.trace_path)
            update = EvidenceRegistry(root, manifest, trace=trace).recall(args.reason)
            _json_output(update.to_dict())
            return 0
        if args.command == "harvest":
            if args.case_json is not None:
                candidate = _parse_json_value(args.case_json, "--case-json")
            else:
                case_path = safe_path(root, args.case_file, must_exist=True, expect="file")
                try:
                    candidate = json.loads(case_path.read_text(encoding="utf-8"), parse_constant=reject_nonfinite_json)
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    raise GovernanceError(f"could not read --case-file: {exc}") from exc
            _json_output(harvest(root, manifest, candidate, source=args.source))
            return 0
    except (GovernanceError, OSError, ValueError) as exc:
        print(f"agent-governor: {exc}", file=sys.stderr)
        return 2
    parser.error("unreachable command")
    return 2
