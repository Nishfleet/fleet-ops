#!/usr/bin/env python3
"""Senior-conference seriousness gate (fleet-ops#3756, ledger 2026-08-26).

A PR that trips the seriousness gate (large diff OR many files OR touches a
critical path) needs the senior-auditor conference before merge. The
`conference-approved` label is the mechanical bypass the conference stamps
when it APPROVES. This gate is the deterministic counterpart to the
"serious builds get the senior conference" ledger line: it reads PR JSON
(diff size, files, labels) and returns PASS (no conference needed, or
conference already approved) or REJECT (serious and not yet approved).

The gap this closes (fleet-ops#3756): 0509#1712 merged with 721 additions
across 10 files and no conference verdict, because the seriousness gate was
prose-only — nothing mechanically flagged the PR as serious. This evaluator
is the reusable core both the senior conference (as an automatic criterion)
and a CI status check call, so the "serious" classification is computed once,
deterministically.

Pure evaluator: no dispatch, no retry, no GitHub writes.

Input (PR JSON on stdin / --input), the shape `gh pr view --json` produces:
  {
    "additions": 721,
    "deletions": 10,
    "changedFiles": 10,            # optional; falls back to len(files)
    "files": [{"path": "src/a.ts", "filename": "src/a.ts"}, ...],
    "labels": [{"name": "conference-approved"}, ...]   # or ["conference-approved"]
  }

Optional bundle keys (override defaults; the CI check passes these so the
thresholds/globs live in one place):
  "lines_threshold": 500,          # additions+deletions > N trips "large diff"
  "files_threshold": 10,           # changed files > N trips "many files"
  "critical_path_globs": ["migrations/**", ...]   # any touched file trips "critical path"
  "bypass_label": "conference-approved"

Subcommands:
  evaluate (default)  PR JSON on stdin / --input -> verdict JSON; exit 0 PASS / 1 REJECT
  --ledger-line      print the decisions-ledger line verbatim and exit 0
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from typing import Any

# Verbatim decisions-ledger line (vault _system/shared-memory/decisions-ledger.md
# 2026-08-26). The senior conference REJECT verdict carries this text; the gate
# is the deterministic counterpart to the human auditor's reading of the rule.
LEDGER_LINE = (
    "2026-08-26 | serious builds get the senior conference | Multi-hour/serious "
    "builds are \"carefully evaluated and audited by senior escalation matrix "
    "conferring amongst themselves\" BEFORE merge — mechanically, automatically, "
    "for every build that trips the seriousness gate (control-plane scope, large "
    "diff, keystone spec). The panel verdict is a required check; automerge waits "
    "for it. | fleet-ops #223"
)

# Default seriousness thresholds. The 0509#1712 evidence was 721 additions
# across 10 files; lines>500 catches it (731 total > 500) and files>10 catches
# an 11-file diff. A PR that trips ANY one of the three is serious.
DEFAULT_LINES_THRESHOLD = 500
DEFAULT_FILES_THRESHOLD = 10
DEFAULT_BYPASS_LABEL = "conference-approved"

# Default critical-path globs. A PR touching ANY of these is serious regardless
# of size, because a small edit to a deploy/migration/security/branch-protection
# path can break the fleet the way a large diff can. Categories mirror the
# issue spec (fleet-ops#3756): deploy, migrations, security, branch-protection.
# The CI check may override these per-repo via the `critical_path_globs` bundle
# key; these defaults cover the fleet-ops control plane and the product repos
# (0509 D1 migrations, siterep deploy).
DEFAULT_CRITICAL_PATH_GLOBS = [
    # deploy — anything that ships a build to production
    "deploy/**",
    "**/deploy/**",
    "install.sh",
    "bin/*deploy*",
    "bin/siterep-deploy*",
    "bin/fleet-deploy*",
    ".github/workflows/*deploy*",
    # migrations — one-way D1/schema changes (D1 has no down-migrations)
    "migrations/**",
    "**/migrations/**",
    # security — auth posture and secret/scan config
    "**/security/**",
    "**/auth/**",
    ".gitleaksignore",
    ".gitleaks.toml",
    ".semgrep.yml",
    ".semgrep.yaml",
    ".semgrepignore",
    # branch-protection — the rules that govern who can merge what
    ".github/scripts/repo-standards-apply.mjs",
    ".github/scripts/repo-standards.lib.mjs",
    ".github/scripts/standards-exceptions.mjs",
    ".github/workflows/repo-standards-sync.yml",
]


def _coerce_int(value: Any, default: int) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _label_names(labels: Any) -> set[str]:
    """Normalise labels into a set of lowercased names.

    Accepts either a list of strings (["conference-approved"]) or a list of
    objects ({"name": "conference-approved"}), the two shapes `gh pr view
    --json labels` and a hand-built fixture both use.
    """
    out: set[str] = set()
    if not isinstance(labels, list):
        return out
    for entry in labels:
        if isinstance(entry, str):
            out.add(entry.strip().lower())
        elif isinstance(entry, dict):
            name = entry.get("name") or entry.get("label")
            if isinstance(name, str):
                out.add(name.strip().lower())
    return out


def _file_paths(files: Any) -> list[str]:
    """Normalise the files list into a list of paths.

    `gh pr view --json files` yields `path`; some fixtures use `filename`.
    Both are accepted. Non-dict entries are skipped.
    """
    paths: list[str] = []
    if not isinstance(files, list):
        return paths
    for entry in files:
        if isinstance(entry, dict):
            path = entry.get("path") or entry.get("filename")
            if isinstance(path, str) and path:
                paths.append(path)
        elif isinstance(entry, str) and entry:
            paths.append(entry)
    return paths


def _matches_any_glob(path: str, globs: list[str]) -> str | None:
    """Return the first glob that matches `path`, else None.

    Uses fnmatch (shell-style globs). A `**` segment matches across path
    separators the way a repo would expect for "anything under migrations/".
    """
    for glob in globs:
        if _fnmatch_path(path, glob):
            return glob
    return None


def _fnmatch_path(path: str, glob: str) -> bool:
    """fnmatch with `**` matching across separators.

    Standard fnmatch treats `*` as matching across `/` already (it does not
    special-case `/`), so `migrations/**` would match `migrations/a/b.sql`.
    The only gap is a leading `**/` segment: `**/migrations/**` should match
    `a/b/migrations/x.sql`. We translate `**/` to `*/` repeatedly is wrong;
    instead we translate `**` -> `*` for fnmatch (fnmatch's `*` already spans
    `/`), which gives the intended "match anywhere" semantics.
    """
    translated = glob.replace("**", "*")
    return fnmatch.fnmatchcase(path, translated)


def evaluate(pr: dict[str, Any]) -> dict[str, Any]:
    """Evaluate a PR's seriousness and the conference-approved bypass."""
    additions = _coerce_int(pr.get("additions"), 0)
    deletions = _coerce_int(pr.get("deletions"), 0)
    lines_changed = additions + deletions

    files = _file_paths(pr.get("files"))
    changed_files = _coerce_int(pr.get("changedFiles"), len(files))
    # Prefer the explicit count if present; else len(files) (some fixtures
    # omit changedFiles but list files).
    file_count = changed_files if changed_files else len(files)

    labels = _label_names(pr.get("labels"))
    bypass_label = str(pr.get("bypass_label") or DEFAULT_BYPASS_LABEL).lower()

    lines_threshold = _coerce_int(pr.get("lines_threshold"), DEFAULT_LINES_THRESHOLD)
    files_threshold = _coerce_int(pr.get("files_threshold"), DEFAULT_FILES_THRESHOLD)

    globs = pr.get("critical_path_globs")
    if not isinstance(globs, list) or not globs:
        globs = DEFAULT_CRITICAL_PATH_GLOBS

    reasons: list[str] = []
    if lines_changed > lines_threshold:
        reasons.append(f"lines_changed={lines_changed} > {lines_threshold}")
    if file_count > files_threshold:
        reasons.append(f"files_touched={file_count} > {files_threshold}")
    critical_hits: list[dict[str, str]] = []
    for path in files:
        hit = _matches_any_glob(path, globs)
        if hit is not None:
            critical_hits.append({"path": path, "glob": hit})
    if critical_hits:
        reasons.append(
            "critical_path: " + ", ".join(sorted({h["path"] for h in critical_hits}))
        )

    serious = bool(reasons)
    bypass = bypass_label in labels

    if serious and not bypass:
        return {
            "verdict": "REJECT",
            "rule": LEDGER_LINE,
            "reason": (
                "PR trips the seriousness gate (large diff / many files / "
                "critical path) and does not carry the `conference-approved` "
                "label; the senior-auditor conference must convene before merge "
                "(fleet-ops#3756, ledger 2026-08-26)"
            ),
            "serious": True,
            "reasons": reasons,
            "critical_path_hits": critical_hits,
            "label_bypass": False,
            "bypass_label": bypass_label,
            "thresholds": {"lines": lines_threshold, "files": files_threshold},
            "lines_changed": lines_changed,
            "files_touched": file_count,
        }
    if serious and bypass:
        return {
            "verdict": "PASS",
            "reason": (
                "PR trips the seriousness gate but carries the "
                f"`{bypass_label}` label; the senior conference has approved "
                "(fleet-ops#3756)"
            ),
            "serious": True,
            "reasons": reasons,
            "critical_path_hits": critical_hits,
            "label_bypass": True,
            "bypass_label": bypass_label,
            "thresholds": {"lines": lines_threshold, "files": files_threshold},
            "lines_changed": lines_changed,
            "files_touched": file_count,
        }
    return {
        "verdict": "PASS",
        "reason": (
            "PR does not trip the seriousness gate; no senior conference "
            "required (fleet-ops#3756)"
        ),
        "serious": False,
        "reasons": [],
        "critical_path_hits": [],
        "label_bypass": bypass in labels,
        "bypass_label": bypass_label,
        "thresholds": {"lines": lines_threshold, "files": files_threshold},
        "lines_changed": lines_changed,
        "files_touched": file_count,
    }


def _load_input(path: str | None) -> dict[str, Any]:
    if path in (None, "-", ""):
        raw = sys.stdin.read()
    else:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    if not raw.strip():
        raise SystemExit("empty input")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise SystemExit("input must be a JSON object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Senior-conference seriousness gate (fleet-ops#3756). "
            "Pure evaluator."
        )
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="evaluate",
        choices=["evaluate"],
        help="evaluate a PR's seriousness and conference-approved bypass",
    )
    parser.add_argument("--input", "-i", help="JSON file (default: stdin)")
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="print the decisions-ledger line verbatim and exit 0",
    )
    args = parser.parse_args(argv)

    if args.ledger_line:
        sys.stdout.write(LEDGER_LINE + "\n")
        return 0

    payload = _load_input(args.input)
    verdict = evaluate(payload)
    json.dump(verdict, sys.stdout)
    sys.stdout.write("\n")
    return 0 if verdict.get("verdict") == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except json.JSONDecodeError as exc:
        print(json.dumps({"verdict": "REJECT", "reason": f"invalid JSON: {exc}"}))
        raise SystemExit(2) from exc
