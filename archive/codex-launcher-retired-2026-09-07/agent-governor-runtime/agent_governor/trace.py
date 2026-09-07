"""Hash-chained, append-only JSONL traces."""

from __future__ import annotations

from datetime import datetime, timezone
from contextlib import contextmanager
import math
import os
from pathlib import Path
import threading
from typing import Any, Iterator, Mapping

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows uses the in-process lock.
    fcntl = None  # type: ignore[assignment]

from .security import (
    ValidationError,
    append_jsonl,
    canonical_json_bytes,
    ensure_directory,
    read_jsonl,
    safe_path,
    secure_root,
    sha256_bytes,
)


TRACE_VERSION = 1
FAILURE_STATES = frozenset(
    {
        "capability_denied",
        "eval_failed",
        "budget_exhausted",
        "loop_detected",
        "runner_failed",
        "certificate_invalid",
        "recalled",
    }
)
TRACE_STATES = FAILURE_STATES | frozenset(
    {"broker_allowed", "certification_passed", "run_completed", "autonomy_changed"}
)
_SENSITIVE_KEY_PARTS = (
    "secret",
    "token",
    "password",
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "credential",
    "private_key",
    "environment",
    "env",
)


_SAFE_DETAIL_KEYS = frozenset(
    {
        "action",
        "agent_id",
        "allowed",
        "certificate_valid",
        "count",
        "cost",
        "detectors",
        "evidence_sha256",
        "failure_classes",
        "length",
        "message",
        "name",
        "policy_version",
        "reason",
        "request_sha256",
        "score",
        "source",
        "state",
        "steps",
        "tier",
        "tool",
        "total_cases",
        "transition",
    }
)
_SAFE_ENUM_VALUES = frozenset(
    {
        "allowlisted",
        "bounded_act",
        "broker_allowed",
        "budget_exhausted",
        "capability_denied",
        "certificate_invalid",
        "certification",
        "certification_passed",
        "demote",
        "demoted",
        "dry_run",
        "eval_failed",
        "governed_input_changed",
        "hard_denylist",
        "invalid_json",
        "loop_detected",
        "manifest_denied",
        "nonzero_exit",
        "not_allowlisted",
        "output_too_large",
        "promoted",
        "recall",
        "recalled",
        "restart_clean",
        "runner_failed",
        "spawn_error",
        "timeout",
        "trace_invalid",
        "trajectory_detector",
    }
)


_TRACE_LOCKS: dict[str, threading.RLock] = {}
_TRACE_LOCKS_GUARD = threading.Lock()


def _thread_lock_for(key: str) -> threading.RLock:
    with _TRACE_LOCKS_GUARD:
        lock = _TRACE_LOCKS.get(key)
        if lock is None:
            lock = threading.RLock()
            _TRACE_LOCKS[key] = lock
        return lock


def _safe_string(value: str, *, key: str = "") -> Any:
    if key in {"action", "name", "source", "state", "transition"} and value in _SAFE_ENUM_VALUES:
        return value
    if key.endswith("_sha256") and len(value) == 64:
        try:
            int(value, 16)
        except ValueError:
            pass
        else:
            return value
    return {"sha256": sha256_bytes(value.encode("utf-8")), "length": len(value)}


def _safe_value(value: Any, *, key: str = "") -> Any:
    lowered = key.lower()
    if any(part in lowered for part in _SENSITIVE_KEY_PARTS):
        if isinstance(value, str):
            return {"sha256": sha256_bytes(value.encode("utf-8")), "length": len(value)}
        return {"type": "redacted"}
    if isinstance(value, Mapping):
        safe_mapping: dict[str, Any] = {}
        for raw_key, item in value.items():
            key_text = str(raw_key)
            if key_text in _SAFE_DETAIL_KEYS:
                safe_key = key_text
            else:
                safe_key = f"key_{sha256_bytes(key_text.encode('utf-8'))}"
            safe_mapping[safe_key] = _safe_value(item, key=key_text)
        return safe_mapping
    if isinstance(value, (list, tuple)):
        return [_safe_value(item, key=key) for item in value]
    if isinstance(value, str):
        return _safe_string(value, key=key)
    if isinstance(value, float) and not math.isfinite(value):
        return {"type": "non_finite_number"}
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return {"type": type(value).__name__}


class TraceError(ValidationError):
    """A trace is malformed or no longer hash-chain consistent."""


class TraceStore:
    """Write one hash-chained record at a time under a per-trace lock."""

    def __init__(self, root: str | Path, relative: str = ".governance/traces.jsonl") -> None:
        if fcntl is None:
            raise TraceError("secure trace locking requires POSIX flock")
        self.root = secure_root(root)
        self.relative = relative
        self._lock = _thread_lock_for(f"{self.root}\0{relative}")

    def _lock_path(self) -> Path:
        parent_relative = str(Path(self.relative).parent)
        if parent_relative != ".":
            ensure_directory(self.root, parent_relative)
        relative = f"{self.relative}.lock"
        return safe_path(self.root, relative, reject_symlink=True)

    @contextmanager
    def _locked(self) -> Iterator[None]:
        with self._lock:
            lock_fd: int | None = None
            try:
                if fcntl is not None:
                    lock_path = self._lock_path()
                    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
                    lock_fd = os.open(lock_path, flags, 0o600)
                    fcntl.flock(lock_fd, fcntl.LOCK_EX)
                yield
            finally:
                if lock_fd is not None:
                    try:
                        fcntl.flock(lock_fd, fcntl.LOCK_UN)
                    finally:
                        os.close(lock_fd)

    def records(self) -> list[dict[str, Any]]:
        with self._locked():
            return read_jsonl(self.root, self.relative)

    @staticmethod
    def _verify_records(records: list[dict[str, Any]]) -> tuple[bool, str]:
        previous = "0" * 64
        for expected_sequence, record in enumerate(records, 1):
            if record.get("schema_version") != TRACE_VERSION:
                return False, f"record {expected_sequence} has an unsupported schema version"
            if record.get("sequence") != expected_sequence:
                return False, f"record {expected_sequence} has a non-contiguous sequence"
            if record.get("previous_hash") != previous:
                return False, f"record {expected_sequence} has a broken previous hash"
            supplied = record.get("entry_hash")
            unsigned = dict(record)
            unsigned.pop("entry_hash", None)
            expected = sha256_bytes(canonical_json_bytes(unsigned))
            if supplied != expected:
                return False, f"record {expected_sequence} has an invalid entry hash"
            previous = expected
        return True, "ok"

    def verify(self) -> tuple[bool, str]:
        try:
            safe_path(self.root, self.relative, must_exist=True, expect="file", reject_symlink=True)
            with self._locked():
                return self._verify_records(read_jsonl(self.root, self.relative))
        except Exception as exc:  # convert parse/lock errors into an inspectable result
            return False, str(exc)

    def append(self, state: str, *, agent_id: str, details: Mapping[str, Any] | None = None) -> dict[str, Any]:
        if state not in TRACE_STATES:
            raise TraceError(f"unknown trace state: {state}")
        with self._locked():
            try:
                records = read_jsonl(self.root, self.relative)
            except Exception as exc:
                raise TraceError(f"refusing to append to an unreadable trace: {exc}") from exc
            valid, reason = self._verify_records(records)
            if not valid:
                raise TraceError(f"refusing to append to an invalid trace: {reason}")
            previous = records[-1]["entry_hash"] if records else "0" * 64
            unsigned: dict[str, Any] = {
                "schema_version": TRACE_VERSION,
                "sequence": len(records) + 1,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "agent_id": _safe_string(agent_id, key="agent_id"),
                "state": state,
                "details": _safe_value(dict(details or {})),
                "previous_hash": previous,
            }
            unsigned["entry_hash"] = sha256_bytes(canonical_json_bytes(unsigned))
            append_jsonl(self.root, self.relative, unsigned)
            return unsigned

    def summary(self) -> dict[str, Any]:
        try:
            safe_path(self.root, self.relative, must_exist=True, expect="file", reject_symlink=True)
            with self._locked():
                records = read_jsonl(self.root, self.relative)
                valid, reason = self._verify_records(records)
        except Exception as exc:
            records = []
            valid, reason = False, str(exc)
        states: dict[str, int] = {}
        for record in records:
            state = str(record.get("state", "unknown"))
            states[state] = states.get(state, 0) + 1
        return {
            "path": self.relative,
            "records": len(records),
            "states": dict(sorted(states.items())),
            "chain_valid": valid,
            "chain_message": reason,
        }
