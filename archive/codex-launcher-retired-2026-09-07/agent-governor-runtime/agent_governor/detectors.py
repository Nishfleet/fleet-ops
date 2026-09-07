"""Deterministic trajectory detectors and run-control actions."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from typing import Any, Mapping, Sequence

from .manifest import Manifest
from .registry import EvidenceRegistry
from .security import ValidationError, canonical_json_bytes, sha256_bytes
from .trace import TraceStore


ACTION_CONTINUE = "continue"
ACTION_RESTART_CLEAN = "restart_clean"
ACTION_DEMOTE = "demote"
ACTION_RECALL = "recall"

DETECTOR_SAME_ACTION_OBSERVATION = "same_action_observation"
DETECTOR_SAME_ERROR_CLASS = "same_error_class"
DETECTOR_PING_PONG = "alternating_ping_pong"
DETECTOR_WRITE_FAIL = "repeated_write_fail"
DETECTOR_NO_PROGRESS = "no_progress"


@dataclass(frozen=True)
class DetectorFinding:
    name: str
    evidence_sha256: str
    message: str

    def to_dict(self) -> dict[str, str]:
        return {"name": self.name, "evidence_sha256": self.evidence_sha256, "message": self.message}


def _evidence(value: Any) -> str:
    return sha256_bytes(canonical_json_bytes(value))


def _finding(name: str, events: Sequence[Mapping[str, Any]], message: str) -> DetectorFinding:
    return DetectorFinding(name, _evidence(list(events)), message)


def detect_trajectory(
    events: Sequence[Mapping[str, Any]], *, no_progress_steps: int = 3
) -> tuple[DetectorFinding, ...]:
    """Return at most one finding for each deterministic detector.

    Event fields are intentionally small: ``action``, ``observation``,
    ``error_class``, ``write_key``, ``write_succeeded``, and ``progress``.
    A write/fail cycle is two failed writes for the same key without an
    intervening successful write. No-progress requires explicit
    ``progress: false`` values, so missing telemetry is not treated as proof
    of failure.
    """

    if no_progress_steps < 1:
        raise ValidationError("no_progress_steps must be positive")
    normalized = [dict(event) for event in events]
    findings: list[DetectorFinding] = []

    for start in range(0, max(0, len(normalized) - 2)):
        window = normalized[start : start + 3]
        pairs = [(item.get("action"), item.get("observation")) for item in window]
        if (
            all("action" in item and "observation" in item for item in window)
            and pairs[0][0] is not None
            and pairs[0] == pairs[1] == pairs[2]
        ):
            findings.append(
                _finding(
                    DETECTOR_SAME_ACTION_OBSERVATION,
                    window,
                    "the same action and observation occurred three times",
                )
            )
            break

    for start in range(0, max(0, len(normalized) - 2)):
        window = normalized[start : start + 3]
        errors = [item.get("error_class") for item in window]
        if errors[0] is not None and errors[0] != "" and errors[0] == errors[1] == errors[2]:
            findings.append(
                _finding(DETECTOR_SAME_ERROR_CLASS, window, "the same error class occurred three times")
            )
            break

    for start in range(0, max(0, len(normalized) - 3)):
        window = normalized[start : start + 4]
        actions = [item.get("action") for item in window]
        if (
            all(item.get("action") is not None for item in window)
            and actions[0] != actions[1]
            and actions == [actions[0], actions[1], actions[0], actions[1]]
        ):
            findings.append(
                _finding(DETECTOR_PING_PONG, window, "two actions alternated for four steps")
            )
            break

    failed_writes: dict[str, list[Mapping[str, Any]]] = {}
    successful_write_indexes: dict[str, int] = {}
    for index, event in enumerate(normalized):
        key = event.get("write_key")
        if not isinstance(key, str) or not key:
            continue
        write_succeeded = event.get("write_succeeded")
        if write_succeeded is None and event.get("action") in {"write", "write_artifact"}:
            write_succeeded = event.get("success")
        if write_succeeded is True:
            successful_write_indexes[key] = index
            failed_writes[key] = []
        elif write_succeeded is False:
            if index > successful_write_indexes.get(key, -1):
                failed_writes.setdefault(key, []).append(event)
    repeated = next(((key, values) for key, values in failed_writes.items() if len(values) >= 2), None)
    if repeated is not None:
        key, values = repeated
        findings.append(
            _finding(
                DETECTOR_WRITE_FAIL,
                values,
                f"the write/fail cycle repeated for key {key!r}",
            )
        )

    for start in range(0, max(0, len(normalized) - no_progress_steps + 1)):
        window = normalized[start : start + no_progress_steps]
        if all(item.get("progress") is False for item in window):
            findings.append(
                _finding(
                    DETECTOR_NO_PROGRESS,
                    window,
                    f"no progress was reported for {no_progress_steps} steps",
                )
            )
            break
    return tuple(findings)


@dataclass
class Budget:
    max_steps: int
    max_cost: Decimal | float | int
    steps: int = 0
    cost: Decimal = field(default_factory=lambda: Decimal("0"))

    def __post_init__(self) -> None:
        if self.max_steps < 1:
            raise ValidationError("max_steps must be positive")
        try:
            self.max_cost = Decimal(str(self.max_cost))
        except (InvalidOperation, ValueError) as exc:
            raise ValidationError("max_cost must be numeric") from exc
        if self.max_cost < 0:
            raise ValidationError("max_cost must be non-negative")

    def consume(self, cost: Decimal | float | int = 0) -> bool:
        try:
            amount = Decimal(str(cost))
        except (InvalidOperation, ValueError) as exc:
            raise ValidationError("step cost must be numeric") from exc
        if amount < 0:
            raise ValidationError("step cost must be non-negative")
        if self.steps + 1 > self.max_steps or self.cost + amount > self.max_cost:
            return False
        self.steps += 1
        self.cost += amount
        return True

    @property
    def exhausted(self) -> bool:
        return self.steps >= self.max_steps or self.cost >= self.max_cost


def choose_action(
    findings: Sequence[DetectorFinding],
    *,
    restart_count: int = 0,
    failure_count: int = 0,
    budget_exhausted: bool = False,
    certificate_valid: bool = True,
    recalled: bool = False,
) -> str:
    """Select a machine action with no human-escalation branch."""

    if recalled or not certificate_valid:
        return ACTION_RECALL
    if failure_count >= 3:
        return ACTION_RECALL
    if findings:
        if restart_count <= 0:
            return ACTION_RESTART_CLEAN
        if restart_count == 1:
            return ACTION_DEMOTE
        return ACTION_RECALL
    if budget_exhausted:
        return ACTION_DEMOTE
    return ACTION_CONTINUE


def restart_clean(state: Mapping[str, Any]) -> dict[str, Any]:
    """Keep task/tool artifacts while dropping assistant narration and reasoning."""

    return {
        "task_artifacts": deepcopy(state.get("task_artifacts", {})),
        "tool_artifacts": deepcopy(state.get("tool_artifacts", {})),
        "assistant_narration": [],
        "reasoning": [],
        "restart_count": int(state.get("restart_count", 0)) + 1,
    }


@dataclass
class GovernedRun:
    """A small local run controller suitable for adapters and the canary."""

    manifest: Manifest
    trace: TraceStore | None = None
    state: dict[str, Any] = field(default_factory=dict)
    events: list[dict[str, Any]] = field(default_factory=list)
    registry: EvidenceRegistry | None = None
    budget: Budget = field(init=False)
    failure_count: int = 0

    def __post_init__(self) -> None:
        self.budget = Budget(self.manifest.max_steps, self.manifest.max_cost)
        if self.registry is None and self.trace is not None:
            self.registry = EvidenceRegistry(self.trace.root, self.manifest)
        self.state.setdefault("task_artifacts", {})
        self.state.setdefault("tool_artifacts", {})
        self.state.setdefault("assistant_narration", [])
        self.state.setdefault("reasoning", [])
        self.state.setdefault("restart_count", 0)

    def _apply_machine_action(self, action: str, reason: str) -> None:
        if action == ACTION_DEMOTE:
            update = self.registry.record_failure(reason) if self.registry is not None else None
            if self.trace is not None and (self.registry is None or self.registry.trace is None):
                if update is not None and update.recalled:
                    self.trace.append(
                        "recalled",
                        agent_id=self.manifest.agent_id,
                        details={"reason": "machine_evidence"},
                    )
                else:
                    self.trace.append(
                        "autonomy_changed",
                        agent_id=self.manifest.agent_id,
                        details={"action": ACTION_DEMOTE, "reason": reason},
                    )
        elif action == ACTION_RECALL:
            if self.registry is not None:
                self.registry.recall(reason)
            if self.trace is not None and (self.registry is None or self.registry.trace is None):
                self.trace.append(
                    "recalled",
                    agent_id=self.manifest.agent_id,
                    details={"reason": reason},
                )

    def step(
        self,
        *,
        action: str,
        observation: Any = None,
        cost: Decimal | float | int = 0,
        error_class: str | None = None,
        write_key: str | None = None,
        write_succeeded: bool | None = None,
        progress: bool | None = None,
    ) -> str:
        if not self.budget.consume(cost):
            self.failure_count += 1
            if self.trace:
                self.trace.append(
                    "budget_exhausted",
                    agent_id=self.manifest.agent_id,
                    details={"steps": self.budget.steps, "cost": str(self.budget.cost)},
                )
            action_taken = choose_action([], failure_count=self.failure_count, budget_exhausted=True)
            self._apply_machine_action(action_taken, "budget_exhausted")
            return action_taken
        event: dict[str, Any] = {"action": action}
        if observation is not None:
            event["observation"] = observation
        if error_class is not None:
            event["error_class"] = error_class
        if write_key is not None:
            event["write_key"] = write_key
            event["write_succeeded"] = write_succeeded
        if progress is not None:
            event["progress"] = progress
        self.events.append(event)
        findings = detect_trajectory(self.events, no_progress_steps=self.manifest.no_progress_steps)
        if findings:
            self.failure_count += 1
            action_taken = choose_action(
                findings,
                restart_count=int(self.state.get("restart_count", 0)),
                failure_count=self.failure_count,
            )
            if self.trace:
                self.trace.append(
                    "loop_detected",
                    agent_id=self.manifest.agent_id,
                    details={
                        "detectors": [finding.to_dict() for finding in findings],
                        "action": action_taken,
                    },
                )
            if action_taken == ACTION_RESTART_CLEAN:
                self.state = restart_clean(self.state)
                self.events.clear()
            elif action_taken in {ACTION_DEMOTE, ACTION_RECALL}:
                self._apply_machine_action(action_taken, "trajectory_detector")
            return action_taken
        return ACTION_CONTINUE
