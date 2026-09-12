#!/usr/bin/env python3
"""Gate-path arm guard (fleet-ops#5238).

Auto-merge must never be armed on a PR whose diff touches gate-owned
paths while the repo's `gate-integrity` check is anything but green on
the head. PR #5207 merged with `gate-integrity / gate-integrity:
FAILURE` because the check is advisory (not a required context) and
`gh pr merge --auto --squash` only waits on required checks.

Verdicts:

  arm     (exit 0)  no gate-owned path in the diff, the gate check is
                    green, or the repo runs no gate-integrity workflow
                    at all (fail-open — the same posture the reusable
                    arm workflow's freeze/quality gates take; a repo
                    without the gate cannot be judged by it)
  refuse  (exit 1)  a gate-owned path is touched AND the gate check
                    concluded non-success, is still pending past the
                    wait budget, or is missing on a repo that runs the
                    gate
  error   (exit 2)  usage / IO / gh failure — callers treat it as
                    fail-open warn-and-arm, never as a refuse

The check row is matched by last name segment so both the standalone
job name (`gate-integrity`, e.g. Nishfleet/0509) and the reusable-
workflow name (`gate-integrity / gate-integrity`, fleet-ops) resolve.

Subcommands:

  evaluate --input fixture.json
  evaluate --repo OWNER/NAME --pr N --globs-json '["…"]' \
      [--wait-seconds N] [--poll-seconds N]

Pure-eval bundle (fixture or emitted verdict context):

  {
    "files":  [{"filename": str, "previous_filename": str|null}]
              or [str, ...],
    "gate_globs": [str, ...],
    "checks": [{"name": str, "bucket": str, "state": str}]
              (gh pr checks row shape; check-runs API rows
               {name,status,conclusion} are accepted too),
    "repo_has_gate": bool
  }
"""

from __future__ import annotations

import argparse
import base64
import fnmatch
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Any

PROG = "fleet-gate-arm-guard"
GATE_CHECK_NAME = "gate-integrity"

# Same defaults as lib/gate-integrity-config.sh DEFAULTS["gate_globs"].
# Live evaluate may omit --globs-json (tier1 queue pass); the reusable
# arm workflow always passes the repo's resolved set.
DEFAULT_GLOBS = [
    ".github/workflows/**",
    ".github/scripts/**",
    ".github/CODEOWNERS",
    ".gitleaksignore",
    ".gitleaks.toml",
    ".semgrepignore",
    ".semgrep.yml",
    ".semgrep.yaml",
    ".fleet/**",
]

# Lazy probe target: presence of this file on the PR's base ref means the
# repo runs the gate and a missing check is a fault, not an absent feature.
GATE_WORKFLOW_PATH = ".github/workflows/gate-integrity.yml"


def _die(msg: str, code: int = 2) -> None:
    print(f"{PROG}: {msg}", file=sys.stderr)
    raise SystemExit(code)


def matches_gate(path: str, globs: list[str]) -> bool:
    """Same predicate as .github/scripts/gate-integrity.sh:matches_gate."""
    if not path:
        return False
    for pattern in globs:
        if fnmatch.fnmatch(path, pattern):
            return True
        # fnmatch's `*` crosses `/`; the prefix form keeps a bare `dir/**`
        # pattern working for the directory itself if one is ever added.
        if pattern.endswith("/**") and path.startswith(pattern[:-2]):
            return True
    return False


def gate_paths(files: list[Any], globs: list[str]) -> list[str]:
    """Paths in the PR diff that are gate-owned (both ends of a rename)."""
    matched: set[str] = set()
    for entry in files:
        if isinstance(entry, str):
            names = [entry]
        elif isinstance(entry, dict):
            names = [
                str(entry.get("filename") or ""),
                str(entry.get("previous_filename") or ""),
            ]
        else:
            continue
        for name in names:
            if matches_gate(name, globs):
                matched.add(name)
    return sorted(matched)


def is_gate_check(row: dict[str, Any]) -> bool:
    name = str(row.get("name") or "")
    return name.split(" / ")[-1].strip() == GATE_CHECK_NAME


def normalize_check(row: dict[str, Any]) -> dict[str, Any]:
    """Collapse gh-pr-checks and check-runs-API row shapes to one verdict.

    Returns {"green": bool, "pending": bool, "detail": str}.
    """
    if "bucket" in row or "state" in row:
        bucket = str(row.get("bucket") or "")
        state = str(row.get("state") or "")
        return {
            "green": bucket == "pass" or state == "SUCCESS",
            "pending": bucket == "pending" or state in ("PENDING", "QUEUED", "IN_PROGRESS"),
            "detail": state or bucket or "unknown",
        }
    status = str(row.get("status") or "")
    conclusion = str(row.get("conclusion") or "")
    return {
        "green": status == "completed" and conclusion == "success",
        "pending": status != "completed",
        "detail": conclusion or status or "unknown",
    }


def latest_gate_check(checks: list[Any]) -> dict[str, Any] | None:
    """Last matching gate row wins (check-runs arrive in created order)."""
    found = [row for row in checks if isinstance(row, dict) and is_gate_check(row)]
    if not found:
        return None
    row = dict(found[-1])
    row.update(normalize_check(row))
    return row


def decide(
    matched: list[str], check: dict[str, Any] | None, repo_has_gate: bool
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "matched_paths": matched,
        "check": check,
        "repo_has_gate": repo_has_gate,
    }
    if not matched:
        return out | {"verdict": "arm", "reason": "no-gate-paths"}
    if check is None:
        if repo_has_gate:
            return out | {"verdict": "refuse", "reason": "gate-check-missing"}
        return out | {"verdict": "arm", "reason": "no-gate-workflow"}
    if check["green"]:
        return out | {"verdict": "arm", "reason": "gate-green"}
    if check["pending"]:
        return out | {
            "verdict": "refuse",
            "reason": f"gate-pending:{check['detail']}",
        }
    return out | {
        "verdict": "refuse",
        "reason": f"gate-not-green:{check['detail']}",
    }


def emit(result: dict[str, Any]) -> int:
    print(json.dumps(result, sort_keys=True))
    return 0 if result["verdict"] == "arm" else 1


# --------------------------------------------------------------------------
# live (gh) mode
# --------------------------------------------------------------------------


def gh(args: list[str], *, tolerate_failure: bool = False) -> subprocess.CompletedProcess:
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True)
    except FileNotFoundError as exc:
        _die(f"gh not found: {exc}")
    if proc.returncode != 0 and not tolerate_failure:
        err = (proc.stderr or proc.stdout or "").strip()
        _die(f"gh {' '.join(args[:3])} failed: {err[:300]}")
    return proc


def gh_json(args: list[str], *, tolerate_failure: bool = False) -> Any:
    proc = gh(args, tolerate_failure=tolerate_failure)
    text = proc.stdout.strip()
    if not text:
        if tolerate_failure:
            return None
        _die(f"gh {' '.join(args[:3])} returned no output")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        if tolerate_failure:
            return None
        _die(f"gh {' '.join(args[:3])} returned unparseable JSON: {text[:200]}")


def fetch_pr(repo: str, pr: int) -> dict[str, str]:
    data = gh_json(
        ["pr", "view", str(pr), "-R", repo, "--json", "headRefOid,baseRefName"]
    )
    if not isinstance(data, dict):
        _die("pr view returned a non-object")
    return {
        "head": str(data.get("headRefOid") or ""),
        "base": str(data.get("baseRefName") or ""),
    }


def fetch_files(repo: str, pr: int) -> list[dict[str, Any]]:
    proc = gh(
        [
            "api",
            "--paginate",
            f"repos/{repo}/pulls/{pr}/files",
            "--jq",
            '.[] | [.filename, (.previous_filename // "")] | @tsv',
        ]
    )
    files = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        name, _, prev = line.partition("\t")
        files.append({"filename": name, "previous_filename": prev or None})
    return files


def fetch_checks(repo: str, pr: int) -> list[dict[str, Any]]:
    # `gh pr checks` exits nonzero when any check is pending/failing but
    # still prints the JSON report — always tolerate, parse stdout.
    data = gh_json(
        ["pr", "checks", str(pr), "-R", repo, "--json", "name,bucket,state"],
        tolerate_failure=True,
    )
    if isinstance(data, list):
        return data
    err = gh(
        ["pr", "checks", str(pr), "-R", repo], tolerate_failure=True
    ).stderr.strip()
    _die(f"gh pr checks unusable: {err[:300] or 'no JSON on stdout'}")
    return []  # unreachable


def probe_gate_workflow(repo: str, base_ref: str) -> bool:
    proc = gh(
        [
            "api",
            f"repos/{repo}/contents/{GATE_WORKFLOW_PATH}?ref={base_ref}",
            "--jq",
            ".sha",
        ],
        tolerate_failure=True,
    )
    if proc.returncode == 0:
        return True
    err = (proc.stderr or "").lower()
    if "404" in err or "not found" in err:
        return False
    # Unclassifiable error (auth/network): assume the gate exists — a
    # misjudged absence would silently arm past a missing verdict.
    return True


def _config_loader() -> str:
    env = os.environ.get("FLEET_GATE_INTEGRITY_CONFIG", "")
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    cand = os.path.join(here, "gate-integrity-config.sh")
    return cand if os.path.isfile(cand) else ""


def fetch_repo_globs(repo: str, base_ref: str) -> list[str]:
    """Load the PR base's .fleet/gate-integrity.yml through the shared loader.

    Missing file or loader -> the same defaults the loader itself uses.
    """
    proc = gh(
        [
            "api",
            f"repos/{repo}/contents/.fleet/gate-integrity.yml?ref={base_ref}",
            "--jq",
            ".content",
        ],
        tolerate_failure=True,
    )
    yml = ""
    if proc.returncode == 0 and proc.stdout.strip():
        try:
            yml = base64.b64decode(proc.stdout.strip()).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            yml = ""
    loader = _config_loader()
    if not loader:
        return list(DEFAULT_GLOBS)
    path = ""
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as fh:
            fh.write(yml)
            path = fh.name
        out = subprocess.run(
            ["bash", loader, path], capture_output=True, text=True
        )
        if out.returncode == 0:
            data = json.loads(out.stdout)
            globs = data.get("gate_globs")
            if isinstance(globs, list) and all(
                isinstance(g, str) and g for g in globs
            ):
                return list(globs)
    except (OSError, json.JSONDecodeError):
        pass
    finally:
        if path:
            try:
                os.unlink(path)
            except OSError:
                pass
    return list(DEFAULT_GLOBS)


def evaluate_live(args: argparse.Namespace) -> dict[str, Any]:
    repo, pr = args.repo, args.pr
    refs = fetch_pr(repo, pr)
    globs = parse_globs(args) or fetch_repo_globs(repo, refs["base"])
    matched = gate_paths(fetch_files(repo, pr), globs)
    if not matched:
        return decide(matched, None, False)

    deadline = time.monotonic() + max(0, args.wait_seconds)
    has_gate: bool | None = None
    while True:
        check = latest_gate_check(fetch_checks(repo, pr))
        if check is None and has_gate is None:
            has_gate = probe_gate_workflow(repo, refs["base"])
        result = decide(matched, check, bool(has_gate))
        if result["verdict"] == "arm" or result["reason"].startswith(
            "gate-not-green"
        ):
            return result
        # refuse only because the verdict is pending/missing — give the
        # ~15s gate check time to report before the final answer.
        if time.monotonic() >= deadline:
            return result
        time.sleep(max(1, args.poll_seconds))


def parse_globs(args: argparse.Namespace) -> list[str]:
    raw = args.globs_json
    if raw is None and args.globs_file:
        try:
            with open(args.globs_file, encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            _die(f"cannot read --globs-file {args.globs_file}: {exc}")
    if raw is None:
        return []
    try:
        globs = json.loads(raw)
    except json.JSONDecodeError as exc:
        _die(f"--globs-json is not JSON: {exc}")
    if not isinstance(globs, list) or not all(
        isinstance(g, str) and g for g in globs
    ):
        _die("--globs-json must be a JSON array of non-empty strings")
    return globs


def evaluate_input(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as fh:
            bundle = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        _die(f"cannot load --input {path}: {exc}")
    if not isinstance(bundle, dict):
        _die("--input must be a JSON object")
    globs = bundle.get("gate_globs") or []
    if not isinstance(globs, list):
        _die("bundle gate_globs is not an array")
    matched = gate_paths(bundle.get("files") or [], globs)
    check = latest_gate_check(bundle.get("checks") or [])
    return decide(matched, check, bool(bundle.get("repo_has_gate")))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog=PROG,
        description=(
            "Auto-merge arm criterion (fleet-ops#5238). Refuse to arm a PR "
            "whose diff touches gate-owned paths while gate-integrity is not "
            "green. Pure evaluator: no GitHub writes."
        ),
    )
    sub = ap.add_subparsers(dest="cmd")
    ev = sub.add_parser("evaluate", help="evaluate one PR / fixture")
    ev.add_argument("--input", help="fixture JSON (pure eval, no gh)")
    ev.add_argument("--repo", help="OWNER/NAME for live eval")
    ev.add_argument("--pr", type=int, help="PR number for live eval")
    ev.add_argument("--globs-json", help="JSON array of gate globs")
    ev.add_argument("--globs-file", help="file holding the JSON glob array")
    ev.add_argument(
        "--wait-seconds",
        type=int,
        default=0,
        help="poll budget while the gate check is pending/missing",
    )
    ev.add_argument("--poll-seconds", type=int, default=8)
    args = ap.parse_args(argv)

    if args.cmd != "evaluate":
        ap.print_help(sys.stderr)
        return 2
    if args.input:
        result = evaluate_input(args.input)
    else:
        if not args.repo or not args.pr:
            _die("live evaluate needs --repo and --pr")
        result = evaluate_live(args)
    return emit(result)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
