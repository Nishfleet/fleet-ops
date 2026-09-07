"""Machine evidence, autonomy transitions, and an append-only recall registry."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import os
import threading
from pathlib import Path
from typing import Any

try:
    import fcntl
except ImportError:
    fcntl = None

from .manifest import AUTONOMY_TIERS, Manifest
from .security import (
    PathSecurityError,
    atomic_write_json,
    read_json,
    read_jsonl,
    append_jsonl,
    ensure_directory,
    safe_path,
    sha256_bytes,
    secure_root,
)
from .trace import TraceStore

_REGISTRY_LOCKS: dict[str, threading.RLock] = {}
_REGISTRY_LOCKS_GUARD = threading.Lock()

def _registry_lock_for(key: str) -> threading.RLock:
    with _REGISTRY_LOCKS_GUARD:
        return _REGISTRY_LOCKS.setdefault(key, threading.RLock())


@dataclass(frozen=True)
class EvidenceUpdate:
    agent_id: str
    tier: str
    successes: int
    failures: int
    consecutive_failures: int
    recalled: bool
    transition: str
    demoted: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "agent_id": self.agent_id,
            "tier": self.tier,
            "successes": self.successes,
            "failures": self.failures,
            "consecutive_failures": self.consecutive_failures,
            "recalled": self.recalled,
            "transition": self.transition,
            "demoted": self.demoted,
        }


class EvidenceRegistry:
    """Keep automatic evidence separate from the signed manifest."""

    def __init__(
        self,
        root: str | Path,
        manifest: Manifest,
        *,
        trace: TraceStore | None = None,
    ) -> None:
        self.root = secure_root(root)
        self.manifest = manifest
        self.trace = trace
        if fcntl is None:
            raise ValueError("secure evidence registry requires POSIX flock")
        self._thread_lock = _registry_lock_for(f"{self.root}\0{manifest.registry_path}")


    @contextmanager
    def _locked(self):
        with self._thread_lock:
            parent = str(Path(self.manifest.registry_path).parent)
            if parent != ".":
                ensure_directory(self.root, parent)
            lock_path = safe_path(self.root, f"{self.manifest.registry_path}.lock", reject_symlink=True)
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def _document(self) -> dict[str, Any]:
        try:
            value, _ = read_json(self.root, self.manifest.registry_path)
        except PathSecurityError as exc:
            if "does not exist" in str(exc):
                return {"schema_version": 1, "agents": {}}
            raise
        if not isinstance(value, dict) or value.get("schema_version") != 1:
            raise ValueError("evidence registry has an unsupported format")
        agents = value.get("agents")
        if not isinstance(agents, dict):
            raise ValueError("evidence registry agents must be an object")
        return value

    def _save(self, document: dict[str, Any]) -> None:
        atomic_write_json(self.root, self.manifest.registry_path, document)

    def _append_recall_record(self, reason: str) -> None:
        recalls = read_jsonl(self.root, self.manifest.recall_path)
        if reason in {"certificate_invalid", "eval_failed", "runner_failed", "recalled"}:
            safe_reason: Any = reason
        else:
            safe_reason = {"sha256": sha256_bytes(reason.encode("utf-8")), "length": len(reason)}
        append_jsonl(
            self.root,
            self.manifest.recall_path,
            {
                "schema_version": 1,
                "sequence": len(recalls) + 1,
                "agent_id": self.manifest.agent_id,
                "reason": safe_reason,
            },
        )

    def _entry(self, document: dict[str, Any]) -> dict[str, Any]:
        agents = document.setdefault("agents", {})
        entry = agents.setdefault(
            self.manifest.agent_id,
            {
                "tier": self.manifest.autonomy_tier,
                "successes": 0,
                "failures": 0,
                "consecutive_failures": 0,
                "recalled": False,
                "demoted": False,
            },
        )
        if not isinstance(entry, dict):
            raise ValueError("evidence registry entry must be an object")
        if entry.get("tier") not in AUTONOMY_TIERS:
            raise ValueError("evidence registry entry has an invalid autonomy tier")
        entry.setdefault("demoted", False)
        for field in ("recalled", "demoted"):
            if not isinstance(entry.get(field), bool):
                raise ValueError(f"evidence registry entry field {field} must be boolean")
        return entry

    def status(self) -> dict[str, Any]:
        document = self._document()
        entry = self._entry(document)
        return {"schema_version": 1, **entry, "agent_id": self.manifest.agent_id}

    def _record(self, *, success: bool, failure_state: str | None = None) -> EvidenceUpdate:
        with self._locked():
            return self._record_locked(success=success, failure_state=failure_state)

    def _record_locked(self, *, success: bool, failure_state: str | None = None) -> EvidenceUpdate:
        document = self._document()
        entry = self._entry(document)
        old_recalled = bool(entry.get("recalled", False))
        entry.setdefault("successes", 0)
        entry.setdefault("failures", 0)
        entry.setdefault("consecutive_failures", 0)
        transition = "none"

        if old_recalled:
            transition = "recalled"
        elif success:
            entry["successes"] += 1
            entry["consecutive_failures"] = 0
            entry["demoted"] = False
            if entry["successes"] >= self.manifest.promotion_successes:
                current = AUTONOMY_TIERS.index(entry["tier"])
                if current < len(AUTONOMY_TIERS) - 1:
                    entry["tier"] = AUTONOMY_TIERS[current + 1]
                    transition = "promoted"
                entry["successes"] = 0
        else:
            entry["failures"] += 1
            entry["successes"] = 0
            entry["consecutive_failures"] += 1
            entry["demoted"] = True
            current = AUTONOMY_TIERS.index(entry["tier"])
            if current > 0:
                entry["tier"] = AUTONOMY_TIERS[current - 1]
                transition = "demoted"
            if failure_state in {"certificate_invalid", "recalled"} or entry["consecutive_failures"] >= self.manifest.recall_failures:
                entry["recalled"] = True
                entry["tier"] = "observe"
                transition = "recalled"

        self._save(document)
        if transition == "recalled" and not old_recalled:
            self._append_recall_record(failure_state or "machine_evidence")
        update = EvidenceUpdate(
            agent_id=self.manifest.agent_id,
            tier=str(entry["tier"]),
            successes=int(entry["successes"]),
            failures=int(entry["failures"]),
            consecutive_failures=int(entry["consecutive_failures"]),
            recalled=bool(entry.get("recalled", False)),
            transition=transition,
            demoted=bool(entry.get("demoted", False)),
        )
        if self.trace and transition in {"promoted", "demoted"}:
            self.trace.append(
                "autonomy_changed",
                agent_id=self.manifest.agent_id,
                details={"transition": transition, "tier": update.tier, "source": failure_state or "certification"},
            )
        if self.trace and transition == "recalled":
            self.trace.append(
                "recalled",
                agent_id=self.manifest.agent_id,
                details={"reason": failure_state or "machine_evidence"},
            )
        return update

    def record_success(self) -> EvidenceUpdate:
        return self._record(success=True)

    def record_failure(self, state: str) -> EvidenceUpdate:
        return self._record(success=False, failure_state=state)

    def recall(self, reason: str) -> EvidenceUpdate:
        with self._locked():
            return self._recall_locked(reason)

    def _recall_locked(self, reason: str) -> EvidenceUpdate:
        document = self._document()
        entry = self._entry(document)
        already_recalled = bool(entry.get("recalled", False))
        entry["recalled"] = True
        entry["demoted"] = False
        entry["tier"] = "observe"
        entry["successes"] = 0
        entry["consecutive_failures"] = max(1, int(entry.get("consecutive_failures", 0)))
        self._save(document)
        if not already_recalled:
            self._append_recall_record(reason)
        if self.trace and not already_recalled:
            self.trace.append("recalled", agent_id=self.manifest.agent_id, details={"reason": reason})
        return EvidenceUpdate(
            agent_id=self.manifest.agent_id,
            tier="observe",
            successes=0,
            failures=int(entry.get("failures", 0)),
            consecutive_failures=int(entry["consecutive_failures"]),
            recalled=True,
            transition="recalled",
            demoted=False,
        )
