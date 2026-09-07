"""Path, JSON, and atomic-file helpers used by the governance layer."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, Mapping, NoReturn


class GovernanceError(Exception):
    """Base error for expected governance failures."""


class PathSecurityError(GovernanceError):
    """A governed path was absolute, traversed, or escaped its root."""


class ValidationError(GovernanceError):
    """A governed JSON document did not satisfy its schema."""


def reject_nonfinite_json(value: str) -> NoReturn:
    """Reject JavaScript-style non-finite numbers accepted by ``json``."""

    raise ValueError(f"non-finite JSON number is not allowed: {value}")


def canonical_json_bytes(value: Any) -> bytes:
    """Return the one JSON representation used for hashes and comparisons."""

    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"value is not canonical JSON: {exc}") from exc
    return text.encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _reject_bad_relative(relative: str) -> None:
    if not isinstance(relative, str) or not relative or "\x00" in relative:
        raise PathSecurityError("governed paths must be non-empty strings without NUL")
    candidate = Path(relative)
    if candidate.is_absolute() or relative.startswith("~"):
        raise PathSecurityError("governed paths must be relative to the governance root")
    if any(part == ".." for part in candidate.parts):
        raise PathSecurityError("path traversal is not allowed")


def secure_root(root: str | os.PathLike[str], *, create: bool = False) -> Path:
    """Resolve a root directory without accepting a symlinked root."""

    raw = Path(os.path.abspath(os.fspath(root)))
    if "\x00" in str(raw):
        raise PathSecurityError("root contains NUL")
    # Walk every component instead of using mkdir(parents=True): a symlinked
    # parent must not silently redirect creation outside the caller's root.
    current = Path(raw.anchor)
    for part in raw.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise PathSecurityError(f"governance root component must not be a symlink: {current}")
        if current.exists() and not current.is_dir():
            raise PathSecurityError(f"governance root component is not a directory: {current}")
        if create and not current.exists():
            current.mkdir(mode=0o700)
    if not raw.exists() or not raw.is_dir():
        raise PathSecurityError(f"governance root is not a directory: {root}")
    resolved = raw.resolve(strict=True)
    if not resolved.is_dir():
        raise PathSecurityError(f"governance root is not a directory: {root}")
    return resolved


def _inside(root: Path, path: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _resolve_existing_parent(root: Path, path: Path) -> Path:
    parent = path.parent
    try:
        resolved_parent = parent.resolve(strict=True)
    except FileNotFoundError as exc:
        raise PathSecurityError(f"governed parent directory does not exist: {parent}") from exc
    if not _inside(root, resolved_parent):
        raise PathSecurityError("governed path escapes its root through a symlink")
    return resolved_parent


def ensure_directory(root: Path, relative: str) -> Path:
    """Create a relative directory, rejecting symlinked path components."""

    _reject_bad_relative(relative)
    parts = Path(relative).parts
    current = root
    for part in parts:
        current = current / part
        if current.exists() or current.is_symlink():
            if current.is_symlink():
                raise PathSecurityError(f"governed directory component is a symlink: {current}")
            if not current.is_dir():
                raise PathSecurityError(f"governed path component is not a directory: {current}")
        else:
            current.mkdir(mode=0o700)
    resolved = current.resolve(strict=True)
    if not _inside(root, resolved):
        raise PathSecurityError("governed directory escapes its root")
    return resolved


def safe_path(
    root: Path,
    relative: str,
    *,
    must_exist: bool = False,
    expect: str = "file",
    reject_symlink: bool = False,
) -> Path:
    """Resolve a path below ``root`` and prove it remains below ``root``."""

    _reject_bad_relative(relative)
    candidate = root / relative
    exists_or_link = candidate.exists() or candidate.is_symlink()
    if reject_symlink and candidate.is_symlink():
        raise PathSecurityError(f"governed file must not be a symlink: {relative}")

    if exists_or_link:
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError as exc:
            raise PathSecurityError(f"governed path is a dangling symlink: {relative}") from exc
    else:
        resolved_parent = _resolve_existing_parent(root, candidate)
        resolved = resolved_parent / candidate.name

    if not _inside(root, resolved):
        raise PathSecurityError("governed path escapes its root through a symlink")
    if must_exist and not exists_or_link:
        raise PathSecurityError(f"governed path does not exist: {relative}")
    if must_exist:
        if expect == "file" and not resolved.is_file():
            raise PathSecurityError(f"governed path is not a file: {relative}")
        if expect == "dir" and not resolved.is_dir():
            raise PathSecurityError(f"governed path is not a directory: {relative}")
    return resolved


def read_bytes(root: Path, relative: str) -> bytes:
    path = safe_path(root, relative, must_exist=True, expect="file")
    return path.read_bytes()


def read_json(root: Path, relative: str) -> tuple[Any, bytes]:
    raw = read_bytes(root, relative)
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=reject_nonfinite_json), raw
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise ValidationError(f"invalid JSON in {relative}: {exc}") from exc


def _prepare_write_target(root: Path, relative: str) -> Path:
    _reject_bad_relative(relative)
    target = root / relative
    parent_relative = str(Path(relative).parent)
    if parent_relative == ".":
        parent = root
    else:
        parent = ensure_directory(root, parent_relative)
    if target.exists() and target.is_symlink():
        raise PathSecurityError(f"governed write target must not be a symlink: {relative}")
    if target.exists() and not target.is_file():
        raise PathSecurityError(f"governed write target is not a file: {relative}")
    if not _inside(root, parent.resolve(strict=True)):
        raise PathSecurityError("governed write target escapes its root")
    return target


def atomic_write_bytes(root: Path, relative: str, content: bytes, *, mode: int = 0o600) -> Path:
    """Write a file through a same-directory temporary and atomic replace."""

    target = _prepare_write_target(root, relative)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=str(target.parent),
            prefix=f".{target.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, target)
        temporary_name = None
        directory_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
    return target


def atomic_write_json(root: Path, relative: str, value: Any, *, mode: int = 0o600) -> Path:
    return atomic_write_bytes(root, relative, canonical_json_bytes(value) + b"\n", mode=mode)


def append_jsonl(root: Path, relative: str, value: Mapping[str, Any], *, mode: int = 0o600) -> Path:
    """Append exactly one canonical JSON record to a safe, append-only file."""

    target = _prepare_write_target(root, relative)
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target, flags | nofollow, mode)
    try:
        os.fchmod(fd, mode)
        payload = canonical_json_bytes(dict(value)) + b"\n"
        offset = 0
        while offset < len(payload):
            offset += os.write(fd, payload[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    return target


def read_jsonl(root: Path, relative: str) -> list[dict[str, Any]]:
    try:
        raw = read_bytes(root, relative)
    except PathSecurityError as exc:
        if "does not exist" in str(exc):
            return []
        raise
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line, parse_constant=reject_nonfinite_json)
        except (json.JSONDecodeError, ValueError) as exc:
            raise ValidationError(f"invalid JSONL record at {relative}:{line_number}") from exc
        if not isinstance(value, dict):
            raise ValidationError(f"JSONL record at {relative}:{line_number} is not an object")
        records.append(value)
    return records


def file_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def relative_string(root: Path, path: Path) -> str:
    try:
        return path.resolve(strict=True).relative_to(root).as_posix()
    except ValueError as exc:
        raise PathSecurityError("path is outside the governance root") from exc
