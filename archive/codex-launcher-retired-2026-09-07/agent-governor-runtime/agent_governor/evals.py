"""Local runner certification and content-bound certificate verification."""

from __future__ import annotations

import json
import math
import os
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Mapping, Sequence

from .manifest import Manifest
from .registry import EvidenceRegistry
from .security import (
    GovernanceError,
    ValidationError,
    atomic_write_json,
    canonical_json_bytes,
    read_json,
    reject_nonfinite_json,
    safe_path,
    secure_root,
    sha256_bytes,
    sha256_file,
)
from .trace import TraceStore


CERTIFICATE_VERSION = 1
MAX_RUNNER_OUTPUT_BYTES = 1024 * 1024
_RUNNER_IO_CHUNK_BYTES = 64 * 1024
_PROCESS_CLEANUP_TIMEOUT_SECONDS = 1.0


class RunnerFailed(GovernanceError):
    """The configured local runner could not produce one JSON result."""

    def __init__(self, error_class: str, message: str) -> None:
        super().__init__(message)
        self.error_class = error_class


@dataclass(frozen=True)
class EvalCase:
    case_id: str
    input: Any
    expected_output: Any
    suite: str
    path: str


@dataclass(frozen=True)
class CertificationResult:
    certificate_path: str
    score: float
    passed_cases: int
    total_cases: int
    passed: bool
    runner_failures: int
    certificate_sha256: str
    evidence: Mapping[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "certificate_path": self.certificate_path,
            "score": self.score,
            "passed_cases": self.passed_cases,
            "total_cases": self.total_cases,
            "passed": self.passed,
            "runner_failures": self.runner_failures,
            "certificate_sha256": self.certificate_sha256,
            "evidence": dict(self.evidence),
        }


@dataclass(frozen=True)
class VerificationResult:
    valid: bool
    reason: str
    certificate_sha256: str | None = None
    score: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "reason": self.reason,
            "certificate_sha256": self.certificate_sha256,
            "score": self.score,
        }


def _cases_from_file(root: Path, suite: str, relative: str) -> list[EvalCase]:
    document, _ = read_json(root, relative)
    if isinstance(document, list):
        raw_cases = document
    elif isinstance(document, dict) and isinstance(document.get("cases"), list):
        raw_cases = document["cases"]
    else:
        raise ValidationError(f"eval suite {relative} must be a list or an object with cases")
    cases: list[EvalCase] = []
    for index, item in enumerate(raw_cases):
        if not isinstance(item, dict):
            raise ValidationError(f"eval case {relative}[{index}] must be an object")
        case_id = item.get("id")
        if not isinstance(case_id, str) or not case_id or "\x00" in case_id:
            raise ValidationError(f"eval case {relative}[{index}] has an invalid id")
        if "input" not in item or "expected_output" not in item:
            raise ValidationError(f"eval case {case_id!r} must have input and expected_output")
        cases.append(EvalCase(case_id, item["input"], item["expected_output"], suite, relative))
    return cases


def load_cases(root: Path, manifest: Manifest) -> list[EvalCase]:
    cases: list[EvalCase] = []
    seen: set[str] = set()
    for suite, relative in manifest.eval_paths:
        for case in _cases_from_file(root, suite, relative):
            if case.case_id in seen:
                raise ValidationError(f"duplicate eval case id: {case.case_id}")
            seen.add(case.case_id)
            cases.append(case)
    if not cases:
        raise ValidationError("at least one eval case is required")
    return cases


def eval_file_descriptors(root: Path, manifest: Manifest) -> list[dict[str, str]]:
    descriptors: list[dict[str, str]] = []
    for suite, relative in manifest.eval_paths:
        path = safe_path(root, relative, must_exist=True, expect="file")
        descriptors.append({"suite": suite, "path": relative, "sha256": sha256_file(path)})
    return descriptors


def eval_bundle_hash(descriptors: Sequence[Mapping[str, str]]) -> str:
    return sha256_bytes(canonical_json_bytes(list(descriptors)))


def _runner_environment() -> dict[str, str]:
    # Deliberately do not inherit PATH, HOME, proxy variables, provider keys,
    # or any other caller environment. The runner receives only this tiny set.
    return {
        "PATH": os.defpath,
        "PYTHONIOENCODING": "utf-8",
        "PYTHONPATH": "",
        "LC_ALL": "C",
        "LANG": "C",
    }


@contextmanager
def _staged_runner(runner_bytes: bytes) -> Iterator[Path]:
    """Stage a private, read-only runner copy outside the governed root."""

    stage_dir = Path(tempfile.mkdtemp(prefix="agent-governor-runner-"))
    try:
        staged_runner = stage_dir / "runner.py"
        with staged_runner.open("xb") as handle:
            handle.write(runner_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(staged_runner, stat.S_IRUSR)
        # The runner needs to read its file and use this directory as cwd, but
        # it has no normal write permission there. The owner can still change
        # permissions or inspect the wider filesystem; that is an honest
        # residual risk without an OS sandbox.
        os.chmod(stage_dir, stat.S_IRUSR | stat.S_IXUSR)
        yield staged_runner
    finally:
        try:
            os.chmod(stage_dir, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        except OSError:
            pass
        shutil.rmtree(stage_dir, ignore_errors=True)


def _terminate_process(process: subprocess.Popen[bytes]) -> None:
    """Kill the runner and its POSIX process group, then wait only briefly."""

    if process.poll() is None:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:  # pragma: no cover - exercised only on Windows.
                process.kill()
        except (OSError, ProcessLookupError):
            pass
    try:
        process.wait(timeout=_PROCESS_CLEANUP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=_PROCESS_CLEANUP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            pass


def _close_process_streams(process: subprocess.Popen[bytes]) -> None:
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def _run_bounded_process(
    command: Sequence[str],
    input_bytes: bytes,
    timeout: float,
    case_id: str,
    cwd: Path,
) -> tuple[int, bytes]:
    """Run a process while draining and bounding both output streams."""

    popen_kwargs: dict[str, Any] = {
        "stdin": subprocess.PIPE,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "cwd": str(cwd),
    }
    if os.name == "posix":
        popen_kwargs["start_new_session"] = True
    try:
        process = subprocess.Popen(
            list(command),
            env=_runner_environment(),
            bufsize=0,
            **popen_kwargs,
        )
    except OSError as exc:
        raise RunnerFailed("spawn_error", f"runner could not start for case {case_id}") from exc

    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr_size = 0
    stdin_pending = memoryview(input_bytes)
    try:
        assert process.stdin is not None
        assert process.stdout is not None
        assert process.stderr is not None
        os.set_blocking(process.stdin.fileno(), False)
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(process.stderr.fileno(), False)
        selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RunnerFailed("timeout", f"runner timed out for case {case_id}")
            events = selector.select(min(remaining, 0.1))
            for key, mask in events:
                stream = key.fileobj
                if key.data == "stdin" and mask & selectors.EVENT_WRITE:
                    if stdin_pending:
                        try:
                            written = os.write(stream.fileno(), stdin_pending[:_RUNNER_IO_CHUNK_BYTES])
                        except (BrokenPipeError, OSError):
                            stdin_pending = memoryview(b"")
                            written = 0
                        stdin_pending = stdin_pending[written:]
                    if not stdin_pending:
                        selector.unregister(stream)
                        stream.close()
                    continue
                if key.data not in {"stdout", "stderr"} or not mask & selectors.EVENT_READ:
                    continue
                try:
                    if key.data == "stdout":
                        current_size = len(stdout)
                    else:
                        current_size = stderr_size
                    read_size = min(_RUNNER_IO_CHUNK_BYTES, MAX_RUNNER_OUTPUT_BYTES - current_size + 1)
                    chunk = os.read(stream.fileno(), max(1, read_size))
                except BlockingIOError:
                    continue
                except OSError as exc:
                    raise RunnerFailed("io_error", f"runner output could not be read for case {case_id}") from exc
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                if current_size + len(chunk) > MAX_RUNNER_OUTPUT_BYTES:
                    raise RunnerFailed("output_too_large", f"runner output exceeded the limit for case {case_id}")
                if key.data == "stdout":
                    stdout.extend(chunk)
                else:
                    stderr_size += len(chunk)
        if process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RunnerFailed("timeout", f"runner timed out for case {case_id}")
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired as exc:
                raise RunnerFailed("timeout", f"runner timed out for case {case_id}") from exc
        return int(process.returncode), bytes(stdout)
    except RunnerFailed:
        _terminate_process(process)
        raise
    except (OSError, ValueError) as exc:
        _terminate_process(process)
        raise RunnerFailed("io_error", f"runner I/O failed for case {case_id}") from exc
    finally:
        try:
            selector.close()
        finally:
            _close_process_streams(process)


def _run_case(staged_runner: Path, manifest: Manifest, case: EvalCase) -> Any:
    command = [sys.executable, "-I", str(staged_runner), *manifest.runner_args]
    input_bytes = canonical_json_bytes(case.input) + b"\n"
    returncode, stdout = _run_bounded_process(
        command,
        input_bytes,
        manifest.runner_timeout_seconds,
        case.case_id,
        staged_runner.parent,
    )
    if returncode != 0:
        raise RunnerFailed("nonzero_exit", f"runner failed for case {case.case_id}")
    try:
        return json.loads(stdout.decode("utf-8"), parse_constant=reject_nonfinite_json)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise RunnerFailed("invalid_json", f"runner output was not one JSON value for case {case.case_id}") from exc


def _certificate_signature(payload: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes(dict(payload)))


def _certificate_hash(certificate: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes(dict(certificate)))


def _score_passes(passed_cases: int, total_cases: int, runner_failures: int, required_score: float) -> bool:
    """The one pass rule shared by certification and verification."""

    if total_cases < 1 or runner_failures != 0 or not 0 <= passed_cases <= total_cases:
        return False
    return passed_cases / total_cases >= required_score


def _bound_inputs_unchanged(
    root: Path,
    manifest_relative: str,
    manifest_raw: bytes,
    manifest: Manifest,
    runner_sha256: str,
    descriptors: Sequence[Mapping[str, str]],
) -> bool:
    """Check that the files used for certification still have their snapshots."""

    try:
        current_manifest = safe_path(root, manifest_relative, must_exist=True, expect="file").read_bytes()
        current_runner = safe_path(root, manifest.runner_path, must_exist=True, expect="file").read_bytes()
        current_descriptors = eval_file_descriptors(root, manifest)
    except (GovernanceError, OSError):
        return False
    return (
        current_manifest == manifest_raw
        and sha256_bytes(current_runner) == runner_sha256
        and list(current_descriptors) == list(descriptors)
    )


def _record_certification_outcome(
    root: Path,
    manifest: Manifest,
    *,
    passed: bool,
    score: float,
    total_cases: int,
    runner_failures: int,
    failure_classes: Sequence[str],
    record_evidence: bool,
) -> Mapping[str, Any]:
    trace = TraceStore(root, manifest.trace_path)
    if passed:
        trace.append(
            "certification_passed",
            agent_id=manifest.agent_id,
            details={"score": score, "total_cases": total_cases},
        )
    elif runner_failures:
        trace.append(
            "runner_failed",
            agent_id=manifest.agent_id,
            details={"failure_classes": sorted(failure_classes), "count": runner_failures},
        )
    else:
        trace.append(
            "eval_failed",
            agent_id=manifest.agent_id,
            details={"score": score, "required_score": manifest.required_eval_score},
        )

    evidence: Mapping[str, Any] = {"transition": "not_recorded"}
    if record_evidence:
        registry = EvidenceRegistry(root, manifest, trace=trace)
        update = registry.record_success() if passed else registry.record_failure(
            "runner_failed" if runner_failures else "eval_failed"
        )
        evidence = update.to_dict()
    return evidence


def certify(
    root: str | Path,
    manifest_relative: str = "manifest.json",
    *,
    record_evidence: bool = True,
) -> CertificationResult:
    if os.name != "posix":
        raise ValidationError("secure certification is supported only on POSIX runtimes")
    root_path = secure_root(root)
    manifest, _, manifest_raw = _load_manifest_for_certification(root_path, manifest_relative)
    runner_path = safe_path(root_path, manifest.runner_path, must_exist=True, expect="file")
    runner_bytes = runner_path.read_bytes()
    runner_sha256 = sha256_bytes(runner_bytes)
    descriptors = eval_file_descriptors(root_path, manifest)
    cases = load_cases(root_path, manifest)
    passed_cases = 0
    runner_failures = 0
    failure_classes: list[str] = []
    for case in cases:
        # Re-stage captured bytes for every case so a runner cannot rewrite
        # the executable used by later evaluations.
        with _staged_runner(runner_bytes) as staged_runner:
            try:
                actual = _run_case(staged_runner, manifest, case)
            except RunnerFailed as exc:
                runner_failures += 1
                failure_classes.append(exc.error_class)
                continue
            try:
                matches = canonical_json_bytes(actual) == canonical_json_bytes(case.expected_output)
            except ValidationError as exc:
                runner_failures += 1
                failure_classes.append("invalid_json")
                continue
            if matches:
                passed_cases += 1
    total = len(cases)
    score = passed_cases / total
    passed = _score_passes(passed_cases, total, runner_failures, manifest.required_eval_score)
    if not _bound_inputs_unchanged(
        root_path,
        manifest_relative,
        manifest_raw,
        manifest,
        runner_sha256,
        descriptors,
    ):
        runner_failures += 1
        failure_classes.append("governed_input_changed")
        passed = False
        evidence = _record_certification_outcome(
            root_path,
            manifest,
            passed=False,
            score=score,
            total_cases=total,
            runner_failures=runner_failures,
            failure_classes=failure_classes,
            record_evidence=record_evidence,
        )
        return CertificationResult(
            certificate_path=manifest.certificate_path,
            score=score,
            passed_cases=passed_cases,
            total_cases=total,
            passed=False,
            runner_failures=runner_failures,
            certificate_sha256="",
            evidence=evidence,
        )
    payload: dict[str, Any] = {
        "certificate_version": CERTIFICATE_VERSION,
        "manifest_sha256": sha256_bytes(manifest_raw),
        "runner_path": manifest.runner_path,
        "runner_sha256": runner_sha256,
        "eval_files": descriptors,
        "eval_bundle_sha256": eval_bundle_hash(descriptors),
        "policy_version": manifest.policy_version,
        "agent_id": manifest.agent_id,
        "score": score,
        "required_score": manifest.required_eval_score,
        "passed_cases": passed_cases,
        "total_cases": total,
        "runner_failures": runner_failures,
        "runner_failure_classes": sorted(failure_classes),
        "passed": passed,
    }
    certificate = {"payload": payload, "signature": _certificate_signature(payload)}
    certificate_path = atomic_write_json(root_path, manifest.certificate_path, certificate)
    certificate_hash = _certificate_hash(certificate)
    evidence = _record_certification_outcome(
        root_path,
        manifest,
        passed=passed,
        score=score,
        total_cases=total,
        runner_failures=runner_failures,
        failure_classes=failure_classes,
        record_evidence=record_evidence,
    )
    return CertificationResult(
        certificate_path=manifest.certificate_path,
        score=score,
        passed_cases=passed_cases,
        total_cases=total,
        passed=passed,
        runner_failures=runner_failures,
        certificate_sha256=certificate_hash,
        evidence=evidence,
    )


def _load_manifest_for_certification(root: Path, relative: str) -> tuple[Manifest, dict[str, Any], bytes]:
    from .manifest import load_manifest

    return load_manifest(root, relative)


def verify_certificate(
    root: str | Path,
    manifest_relative: str = "manifest.json",
    certificate_relative: str | None = None,
    *,
    record_invalid: bool = True,
) -> VerificationResult:
    root_path = secure_root(root)
    manifest, _, manifest_raw = _load_manifest_for_certification(root_path, manifest_relative)
    certificate_relative = certificate_relative or manifest.certificate_path
    try:
        certificate, _ = read_json(root_path, certificate_relative)
    except GovernanceError as exc:
        result = VerificationResult(False, f"certificate unreadable: {exc}")
        if record_invalid:
            _record_certificate_invalid(root_path, manifest, result.reason)
        return result
    if not isinstance(certificate, dict) or not isinstance(certificate.get("payload"), dict):
        result = VerificationResult(False, "certificate must contain a payload object")
        if record_invalid:
            _record_certificate_invalid(root_path, manifest, result.reason)
        return result
    payload = certificate["payload"]
    supplied_signature = certificate.get("signature")
    try:
        expected_signature = _certificate_signature(payload)
        cert_hash = _certificate_hash(certificate)
    except ValidationError as exc:
        result = VerificationResult(False, f"certificate is not canonical JSON: {exc}")
        if record_invalid:
            _record_certificate_invalid(root_path, manifest, result.reason)
        return result
    if supplied_signature != expected_signature:
        result = VerificationResult(False, "certificate signature hash does not match", cert_hash)
        if record_invalid:
            _record_certificate_invalid(root_path, manifest, result.reason)
        return result
    try:
        descriptors = eval_file_descriptors(root_path, manifest)
        cases = load_cases(root_path, manifest)
        runner = safe_path(root_path, manifest.runner_path, must_exist=True, expect="file")
        total_cases = payload.get("total_cases")
        passed_cases = payload.get("passed_cases")
        runner_failures = payload.get("runner_failures")
        score = payload.get("score")
        counts_are_integers = all(
            isinstance(value, int) and not isinstance(value, bool)
            for value in (total_cases, passed_cases, runner_failures)
        )
        score_is_finite_number = False
        if isinstance(score, (int, float)) and not isinstance(score, bool):
            try:
                score_is_finite_number = math.isfinite(float(score)) and 0 <= score <= 1
            except (OverflowError, ValueError):
                score_is_finite_number = False
        counts_match = (
            counts_are_integers
            and total_cases == len(cases)
            and total_cases > 0
            and 0 <= passed_cases <= total_cases
            and runner_failures >= 0
        )
        score_matches_counts = (
            counts_match
            and score_is_finite_number
            and score == passed_cases / total_cases
        )
        expected_pass = (
            counts_match
            and _score_passes(passed_cases, total_cases, runner_failures, manifest.required_eval_score)
        )
        checks = {
            "certificate_version": payload.get("certificate_version") == CERTIFICATE_VERSION,
            "manifest_sha256": payload.get("manifest_sha256") == sha256_bytes(manifest_raw),
            "runner_path": payload.get("runner_path") == manifest.runner_path,
            "runner_sha256": payload.get("runner_sha256") == sha256_bytes(runner.read_bytes()),
            "eval_files": payload.get("eval_files") == descriptors,
            "eval_bundle_sha256": payload.get("eval_bundle_sha256") == eval_bundle_hash(descriptors),
            "policy_version": payload.get("policy_version") == manifest.policy_version,
            "agent_id": payload.get("agent_id") == manifest.agent_id,
            "required_score": payload.get("required_score") == manifest.required_eval_score,
            "counts": counts_match,
            "score": score_matches_counts,
            "runner_failure_classes": payload.get("runner_failure_classes") == []
            if counts_are_integers and runner_failures == 0
            else False,
            "passed": payload.get("passed") is True and expected_pass,
        }
    except (GovernanceError, OSError, OverflowError, ValueError) as exc:
        checks = {"current_inputs": False}
        reason = f"current governed inputs are invalid: {exc}"
    else:
        reason = "ok" if all(checks.values()) else "certificate inputs or score do not match"
    valid = all(checks.values())
    score_value = payload.get("score")
    try:
        score_value_valid = (
            isinstance(score_value, (int, float))
            and not isinstance(score_value, bool)
            and math.isfinite(float(score_value))
            and 0 <= score_value <= 1
        )
    except (OverflowError, ValueError):
        score_value_valid = False
    if not score_value_valid:
        score_value = None
    result = VerificationResult(valid, reason, cert_hash, score_value)
    if not valid and record_invalid:
        _record_certificate_invalid(root_path, manifest, reason)
    return result


def _record_certificate_invalid(root: Path, manifest: Manifest, reason: str) -> None:
    trace = TraceStore(root, manifest.trace_path)
    trace.append(
        "certificate_invalid",
        agent_id=manifest.agent_id,
        details={"reason": reason},
    )
    registry = EvidenceRegistry(root, manifest, trace=trace)
    registry.record_failure("certificate_invalid")
