"""A deny-by-default external-tool decision broker."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .manifest import AUTONOMY_TIERS, Manifest, load_manifest
from .registry import EvidenceRegistry
from .security import GovernanceError, ValidationError, canonical_json_bytes, safe_path, sha256_bytes
from .trace import TraceStore


HARD_DENYLIST = frozenset(
    {
        "shell",
        "exec",
        "subprocess",
        "network",
        "http",
        "https",
        "filesystem_write",
        "read_secret",
        "secrets",
        "credentials",
        "sudo",
        "delete",
    }
)
BROKER_POLICY_VERSION = "broker-v1"


@dataclass(frozen=True)
class BrokerDecision:
    tool: str
    allowed: bool
    reason: str
    request_sha256: str
    policy_version: str = BROKER_POLICY_VERSION

    def to_dict(self) -> dict[str, Any]:
        return {
            "tool": self.tool,
            "allowed": self.allowed,
            "reason": self.reason,
            "request_sha256": self.request_sha256,
            "policy_version": self.policy_version,
        }


class CapabilityDenied(ValidationError):
    """The broker rejected a tool call."""


class ToolBroker:
    """Mediate tool names without exposing raw arguments in audit records."""

    def __init__(
        self,
        manifest: Manifest,
        trace: TraceStore | None = None,
        *,
        manifest_relative: str = "manifest.json",
    ) -> None:
        self.manifest = manifest
        self.trace = trace
        self.manifest_relative = manifest_relative

    @staticmethod
    def _tool_name(tool: str) -> str:
        if not isinstance(tool, str) or not tool or "\x00" in tool or len(tool) > 128:
            raise ValidationError("tool name must be a short non-empty string")
        return tool

    @staticmethod
    def _request_hash(tool: str, arguments: Any) -> str:
        return sha256_bytes(canonical_json_bytes({"tool": tool, "arguments": arguments}))

    def _governance_gate(self) -> tuple[bool, str | None]:
        """Return the current authorization state, failing closed on uncertainty."""

        if self.trace is None:
            return False, "trace_unavailable"
        trace_valid, _ = self.trace.verify()
        if not trace_valid:
            return False, "trace_invalid"
        try:
            from .evals import verify_certificate

            certificate = verify_certificate(
                self.trace.root,
                self.manifest_relative,
                record_invalid=False,
            )
            if not certificate.valid:
                return False, "certificate_invalid"
            safe_path(self.trace.root, self.manifest.registry_path, must_exist=True, expect="file", reject_symlink=True)
            evidence = EvidenceRegistry(self.trace.root, self.manifest).status()
        except (GovernanceError, OSError, ValueError):
            return False, "evidence_invalid"
        if bool(evidence.get("recalled")):
            return False, "recalled"
        if bool(evidence.get("demoted")):
            return False, "demoted"
        effective_tier = evidence.get("tier")
        if effective_tier not in AUTONOMY_TIERS or AUTONOMY_TIERS.index(effective_tier) < AUTONOMY_TIERS.index(self.manifest.autonomy_tier):
            return False, "demoted"
        return True, None

    def _audit(self, decision: BrokerDecision) -> bool:
        if self.trace is None:
            return False
        try:
            valid, _ = self.trace.verify()
            if not valid:
                return False
            self.trace.append(
                "broker_allowed" if decision.allowed else "capability_denied",
                agent_id=self.manifest.agent_id,
                details=decision.to_dict(),
            )
        except (GovernanceError, OSError, ValueError):
            return False
        return True

    def decide(self, tool: str, arguments: Any = None) -> BrokerDecision:
        tool = self._tool_name(tool)
        request_hash = self._request_hash(tool, arguments)
        if self.trace is None:
            return BrokerDecision(tool, False, "trace_unavailable", request_hash)
        try:
            current_manifest, _, _ = load_manifest(self.trace.root, self.manifest_relative)
        except (GovernanceError, OSError, ValueError):
            return BrokerDecision(tool, False, "manifest_invalid", request_hash)
        if current_manifest != self.manifest:
            return BrokerDecision(tool, False, "manifest_mismatch", request_hash)
        self.manifest = current_manifest
        governance_allowed, governance_reason = self._governance_gate()
        if not governance_allowed:
            decision = BrokerDecision(tool, False, governance_reason or "governance_invalid", request_hash)
        else:
            lowered = tool.lower()
            if lowered in HARD_DENYLIST:
                reason = "hard_denylist"
                allowed = False
            elif tool in self.manifest.denied_tools:
                reason = "manifest_denied"
                allowed = False
            elif tool not in self.manifest.allowed_tools:
                reason = "not_allowlisted"
                allowed = False
            else:
                reason = "allowlisted"
                allowed = True
            decision = BrokerDecision(tool, allowed, reason, request_hash)
        if decision.allowed and not self._audit(decision):
            decision = BrokerDecision(tool, False, "trace_unavailable", request_hash)
        elif not decision.allowed:
            self._audit(decision)
        return decision

    def invoke(
        self,
        tool: str,
        arguments: Any = None,
        handlers: Mapping[str, Callable[[Any], Any]] | None = None,
    ) -> Any:
        decision = self.decide(tool, arguments)
        if not decision.allowed:
            raise CapabilityDenied(f"tool {tool!r} denied: {decision.reason}")
        if handlers is None or tool not in handlers:
            raise CapabilityDenied(f"tool {tool!r} has no registered local handler")
        return handlers[tool](arguments)
