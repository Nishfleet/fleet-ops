#!/usr/bin/env python3
"""Per-role quality-gate audit (fleet-ops#457).

Enumerates every catalogued fleet role, verifies its gate still exists
on disk, runs the named bypass checks, and flags prompts/units that
appeared without a catalog row. Heartbeat runs this every tick so a
new role cannot ship gateless.

Usage:
  python3 lib/role-quality-gates.py audit --repo-root DIR --catalog C.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

# Prompts that are variants of a parent role, not a new role.
REPAIR_PROMPT_SUFFIX = "-repair.md"

# Units that are product-specific, recovery drills, or escalation plumbing,
# not judging/building roles. fleet-resilience / resilience-drill landed
# with fleet-ops#575; they are recovery cycles, not a new work-producing role.
# interactive-session-reap (fleet-ops#592) reaps idle scopes; it is not a
# work-producing role. vault-conflict-resolver (fleet-ops#529 / #636) is the
# Syncthing freeze handler; vault-knowledge-format is the daily lint timer
# for vault shape (fleet-ops#525). Both are plumbing, same class.
# fleet-metrics-export (fleet-ops#1180) is the periodic Prometheus textfile
# exporter (writes /var/lib/prometheus/node-exporter/fleet.prom every 5m);
# it is observability plumbing, not a judging/building role.
# fleet-aeo-probe (fleet-ops#1236) is the weekly 0509 citation probe; it
# writes fleet-aeo.prom. Same plumbing class as the metrics exporter.
NON_ROLE_UNIT_PREFIXES = (
    "siterep-",
    "oomd-",
    "stop-escalation",
    "unit-escalation",
    "escalation-daily",
    "intake-reconcile",
    "fleet-restore",
    "fleet-resilience",
    "resilience-drill",
    "fleet-bare-metal-rebuild",
    "fleet-console",
    "fleet-heartbeat-failed-notify",
    "fleet-deploy-check",
    "fleet-seat-recovery",
    "interactive-session-reap",
    "agent-cron-",
    "app-pi",
    "vault-conflict",
    "vault-knowledge-format",
    "fleet-metrics-export",
    # fleet-ops#1152: standing-rules-render is a file-render maintenance
    # unit (canonical -> marked regions of CLAUDE.md/AGENTS.md). It runs
    # no model, owns no prompt and produces no work items, so it has no
    # role gate; its own gate is the drift --check plus
    # tests/standing-rules-drift.test.sh.
    "standing-rules-render",
    "fleet-aeo",
    # fleet-ops#1149: asset census is observability plumbing, not a
    # work-producing role. It enumerates the VPS and diffs against a
    # versioned guard map before the Weekly Fleet Review.
    "fleet-asset-census",
    # fleet-ops#1464: the gh-webhook push channel is dumb transport
    # (HMAC verify + forward) plus a synthetic-canary dead-man's switch.
    # It runs no model, owns no prompt and produces no work items, so it
    # has no role gate; its own gate is the receiver HMAC test, the
    # canary round-trip test, and the absent() heartbeat rule.
    "gh-webhook-",
)


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be an object")
    return data


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def _missing_proofs(repo: Path, proofs: list[str]) -> list[str]:
    missing = []
    for rel in proofs:
        if not (repo / rel).exists():
            missing.append(rel)
    return missing


def check_scout_agent_ready_product(repo: Path, _role: dict[str, Any]) -> str | None:
    """Product scouts must apply scout-candidate, not blank agent-ready."""
    text = _read(repo / "prompts" / "scout.md")
    if not text:
        return "prompts/scout.md missing"
    if "scout-candidate" not in text:
        return "prompts/scout.md never applies scout-candidate (admission bypass)"
    # The product path must not tell scouts to stamp agent-ready as the
    # default. fleet-ops is the documented control-plane exception.
    if re.search(
        r"Apply `agent-ready` only within `label_budget`",
        text,
    ):
        return (
            "prompts/scout.md still stamps agent-ready as the default product "
            "path (admission bypass)"
        )
    return None


def check_sweep_blank_approval(repo: Path, _role: dict[str, Any]) -> str | None:
    """#376 sweep must not blank-approve product-repo issues."""
    text = _read(repo / "bin" / "lifecycle-label-sweep")
    if not text:
        return "bin/lifecycle-label-sweep missing"
    if "scout-candidate" not in text:
        return (
            "lifecycle-label-sweep never emits scout-candidate "
            "(#376 sweep is a judging bypass)"
        )
    return None


def check_intake_lists_agent_ready_only(repo: Path, _role: dict[str, Any]) -> str | None:
    text = _read(repo / "prompts" / "intake.md")
    if not text:
        return "prompts/intake.md missing"
    if "-l agent-ready" not in text and "--label agent-ready" not in text:
        return "prompts/intake.md does not list agent-ready (intake gate missing)"
    return None


def check_builder_ci_and_auto_revert(repo: Path, _role: dict[str, Any]) -> str | None:
    ci = repo / ".github" / "workflows" / "ci.yml"
    revert = repo / ".github" / "workflows" / "auto-revert.yml"
    missing = []
    if not ci.exists():
        missing.append(".github/workflows/ci.yml")
    if not revert.exists():
        missing.append(".github/workflows/auto-revert.yml")
    if missing:
        return "builder gate missing: " + ", ".join(missing)
    return None


def check_reviewer_attestation_gate(repo: Path, _role: dict[str, Any]) -> str | None:
    if not (repo / "lib" / "attest-identity-gate.py").exists():
        return "lib/attest-identity-gate.py missing (attestation separation)"
    return None


def check_senior_cannot_self_admit(repo: Path, _role: dict[str, Any]) -> str | None:
    tally = _read(repo / "bin" / "pi-audit-tally")
    if "2-of-3" not in tally and "pass" not in tally.lower():
        return "bin/pi-audit-tally does not enforce 2-of-3 admission"
    return None


def check_orchestrator_verdict_guard(repo: Path, _role: dict[str, Any]) -> str | None:
    if not (repo / "lib" / "guard_pi_packet.py").exists():
        return "lib/guard_pi_packet.py missing"
    return None


def check_audit_has_panel(repo: Path, _role: dict[str, Any]) -> str | None:
    if not (repo / "lib" / "blind-audit-panel.py").exists():
        return "lib/blind-audit-panel.py missing"
    return None


def check_researcher_delta_contract(repo: Path, _role: dict[str, Any]) -> str | None:
    """Researcher deltas must pass the contract validator before filing."""
    if not (repo / "lib" / "researcher-delta.py").exists():
        return "lib/researcher-delta.py missing (delta contract validator)"
    return None


def check_weekly_fleet_review_output_contract(repo: Path, _role: dict[str, Any]) -> str | None:
    """WFR (fleet-ops#1146) must lock the 5-action cap + signal in the prompt.

    The prompt is the only output-contract surface — a worker that drops
    the cap or the `signal: wfr-action/...` attribution can flood the
    queue or break the rolling-ratio self-score. Gate-checked here so a
    hand-edit cannot bypass either. The 6th SECURITY lens (Nish 2026-08-27
    "are we doing everything" sweep) is also locked here — a prompt that
    drops it silently loses the standing security audit.
    """
    text = _read(repo / "prompts" / "weekly-fleet-review.md")
    if not text:
        return "prompts/weekly-fleet-review.md missing"
    if "Adopt \u2264 5" not in text and "Adopt <= 5" not in text and "Adopt \\u2264 5" not in text:
        return "prompts/weekly-fleet-review.md does not lock the Adopt \u2264 5 cap"
    if "signal: wfr-action/" not in text:
        return "prompts/weekly-fleet-review.md does not require signal: wfr-action/ attribution"
    if "claimed work only" not in text:
        return "prompts/weekly-fleet-review.md drops the 'claimed work only' output rule (no Nish report)"
    if "blind" not in text.lower():
        return "prompts/weekly-fleet-review.md drops the blind 6-lens structure"
    if "L6 SECURITY" not in text:
        return "prompts/weekly-fleet-review.md drops the L6 SECURITY lens (fleet-ops#1146 Nish addition)"
    if '"lens": "throughput|quality|machinery|truth|outside|security"' not in text:
        return "prompts/weekly-fleet-review.md lens enum does not include security"
    return None


def check_quality_ratchet_contract(repo: Path, _role: dict[str, Any]) -> str | None:
    """WFR (fleet-ops#1222) must lock the weekly quality ratchet.

    The ledger says gates that were consistently met tighten one notch per
    week and never loosen without Nish. The prompt is the WFR output
    contract; dropping it lets a weekly run skip the bar-raise.
    """
    text = _read(repo / "prompts" / "weekly-fleet-review.md")
    if not text:
        return "prompts/weekly-fleet-review.md missing"
    if "Quality ratchet" not in text:
        return "prompts/weekly-fleet-review.md drops the Quality ratchet phase"
    if "one notch" not in text:
        return "prompts/weekly-fleet-review.md does not lock one notch per week"
    if "last-ratchet.json" not in text:
        return "prompts/weekly-fleet-review.md does not require last-ratchet.json"
    if "never loosen" not in text.lower():
        return "prompts/weekly-fleet-review.md drops 'never loosen without Nish'"
    if not (repo / "lib" / "quality-ratchet.py").exists():
        return "lib/quality-ratchet.py missing (quality ratchet canary)"
    if not (repo / "config" / "quality-ratchet.json").exists():
        return "config/quality-ratchet.json missing (committed floors)"
    return None


BYPASS_CHECKS = {
    "scout_agent_ready_product": check_scout_agent_ready_product,
    "sweep_blank_approval": check_sweep_blank_approval,
    "intake_lists_agent_ready_only": check_intake_lists_agent_ready_only,
    "builder_ci_and_auto_revert": check_builder_ci_and_auto_revert,
    "reviewer_attestation_gate": check_reviewer_attestation_gate,
    "senior_cannot_self_admit": check_senior_cannot_self_admit,
    "orchestrator_verdict_guard": check_orchestrator_verdict_guard,
    "audit_has_panel": check_audit_has_panel,
    "researcher_delta_contract": check_researcher_delta_contract,
    "weekly_fleet_review_output_contract": check_weekly_fleet_review_output_contract,
    "quality_ratchet_contract": check_quality_ratchet_contract,
}


def _is_role_unit(name: str) -> bool:
    base = name
    if "-failed@" in base or base.endswith("-failed.service"):
        return False
    for prefix in NON_ROLE_UNIT_PREFIXES:
        if base.startswith(prefix):
            return False
    return base.endswith(".service")


def discover_prompts(repo: Path) -> set[str]:
    prompts_dir = repo / "prompts"
    found: set[str] = set()
    if not prompts_dir.is_dir():
        return found
    for path in prompts_dir.glob("*.md"):
        name = path.name
        if name.endswith(REPAIR_PROMPT_SUFFIX):
            continue
        if name.startswith("siterep-") or name.startswith("0509-"):
            continue
        found.add(name)
    return found


def discover_units(repo: Path) -> set[str]:
    units_dir = repo / "systemd"
    found: set[str] = set()
    if not units_dir.is_dir():
        return found
    for path in units_dir.glob("*.service"):
        name = path.name
        if _is_role_unit(name):
            found.add(name)
    return found


def audit_roles(
    repo: Path,
    catalog: dict[str, Any],
    *,
    extra_prompt: str | None = None,
    extra_unit: str | None = None,
) -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    covered_prompts: set[str] = set()
    covered_units: set[str] = set()

    for role in catalog.get("roles") or []:
        if not isinstance(role, dict):
            continue
        rid = str(role.get("id") or "").strip()
        if not rid:
            continue
        proofs = [str(p) for p in (role.get("proof") or [])]
        missing = _missing_proofs(repo, proofs)
        if missing:
            findings.append(
                {
                    "id": rid,
                    "kind": "missing-proof",
                    "detail": f"role {rid} gate proof missing: {', '.join(missing)}",
                }
            )
        for check_name in role.get("bypass_checks") or []:
            fn = BYPASS_CHECKS.get(str(check_name))
            if fn is None:
                findings.append(
                    {
                        "id": rid,
                        "kind": "unknown-check",
                        "detail": f"role {rid} names unknown bypass check {check_name}",
                    }
                )
                continue
            hit = fn(repo, role)
            if hit:
                findings.append(
                    {
                        "id": rid,
                        "kind": "bypass",
                        "detail": hit,
                    }
                )
        for name in role.get("prompts") or []:
            covered_prompts.add(str(name))
        for name in role.get("units") or []:
            covered_units.add(str(name))

    prompts = discover_prompts(repo)
    units = discover_units(repo)
    if extra_prompt:
        prompts.add(extra_prompt)
    if extra_unit:
        units.add(extra_unit)

    for name in sorted(prompts - covered_prompts):
        findings.append(
            {
                "id": f"prompt:{name}",
                "kind": "ungated-role",
                "detail": f"prompt {name} is not in the role-quality-gates catalog",
            }
        )
    for name in sorted(units - covered_units):
        findings.append(
            {
                "id": f"unit:{name}",
                "kind": "ungated-role",
                "detail": f"unit {name} is not in the role-quality-gates catalog",
            }
        )

    return {
        "findings": findings,
        "role_count": len(catalog.get("roles") or []),
        "ok": len(findings) == 0,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cmd", choices=["audit"])
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--extra-prompt", default="")
    parser.add_argument("--extra-unit", default="")
    args = parser.parse_args(argv)
    catalog = load_json(args.catalog)
    result = audit_roles(
        Path(args.repo_root),
        catalog,
        extra_prompt=args.extra_prompt or None,
        extra_unit=args.extra_unit or None,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
