#!/usr/bin/env python3
"""Machinery-authorization gate (fleet-ops#1548 / audit Step 4).

Extends the #366 gate class: pure evaluator, no dispatch, no GitHub writes,
no retry. New machinery is default-DENIED unless allowlisted or carrying the
Nish-only authorization signal. Repairs and deletions stay ungated.

Subcommands:
  evaluate (default)  name-status diff + allowlist + PR body → verdict JSON
  hunt                live hand-placed units not on the allowlist → findings
  --ledger-line       print the decisions-ledger line verbatim
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

PROG = "fleet-machinery-authorization-gate"

# Verbatim decisions-ledger line (2026-08-28 machinery ban, clarified after
# the by-fiat build was VOID). Conference REJECT verdicts carry this text.
LEDGER_LINE = (
    "STANDING, NON-NEGOTIABLE: NEW machinery (unit files under systemd/**, "
    "MANIFEST lines that install those units) is default-DENIED. A PR that "
    "adds machinery must either (a) name a unit already on "
    "config/machinery-allowlist.json, or (b) carry the Nish-only body signal "
    "`authorized-by-nish: <reason>`. Repairs and deletions of existing "
    "machinery stay ungated. Live hand-placed units not on the allowlist are "
    "hunt findings for senior-conference adjudication (MECHANICAL-INSTEAD / "
    "EXCEPTION-APPROVED / NISH-RESERVED). Enforced mechanically at the senior "
    "conference + blind audit (fleet-ops #1548, extends #366). Origin: "
    "2026-08-28 machinery audit Step 4; Nish: 'Make it mechanically "
    "non-negotiable'."
)

# Body trailer that stands in for the VOID `nish-authorized-machinery` label.
# Agents can type it (residual honesty: nish3451 + sudo), so the gate makes
# violations deliberate and auditable, not cryptographically impossible.
AUTH_SIGNAL = re.compile(r"(?im)^[ \t]*authorized-by-nish:[ \t]*\S")

UNIT_SUFFIXES = (
    ".service",
    ".timer",
    ".path",
    ".slice",
    ".socket",
    ".target",
)

# Transient / runtime units systemd itself writes; not hand-placed machinery.
TRANSIENT_DIR_MARKERS = (
    "/run/systemd/transient/",
    "/run/user/",
)


def _die(msg: str, code: int = 2) -> None:
    print(f"{PROG}: {msg}", file=sys.stderr)
    raise SystemExit(code)


def parse_name_status(text: str) -> list[tuple[str, str, str]]:
    """Return [(status_letter, path, dest)] for A/M/D/R/C rows."""
    rows: list[tuple[str, str, str]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        col1 = parts[0]
        if not col1:
            continue
        letter = col1[0]
        if letter in ("A", "M", "D"):
            path = parts[1] if len(parts) > 1 else ""
            rows.append((letter, path, ""))
        elif letter in ("R", "C"):
            dest = parts[2] if len(parts) > 2 else (parts[1] if len(parts) > 1 else "")
            src = parts[1] if len(parts) > 1 else ""
            rows.append((letter, dest, src))
    return rows


def unit_basename(path: str) -> str | None:
    """Return the unit stem (with trailing @ for templates) or None."""
    name = Path(path.replace("\\", "/")).name
    for suf in UNIT_SUFFIXES:
        if name.endswith(suf):
            stem = name[: -len(suf)]
            return stem
    return None


def is_systemd_unit_path(path: str) -> bool:
    norm = path.replace("\\", "/")
    if not norm.startswith("systemd/"):
        return False
    if norm.rstrip("/").endswith("systemd") or norm.endswith("/"):
        return False
    return unit_basename(norm) is not None


def is_manifest_path(path: str) -> bool:
    norm = path.replace("\\", "/")
    return norm == "MANIFEST" or norm.endswith("/MANIFEST")


def load_allowlist(path: str | None = None, data: dict[str, Any] | None = None) -> set[str]:
    if data is None:
        if not path:
            _die("allowlist path required")
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    if not isinstance(data, dict):
        _die("allowlist root must be a JSON object")
    authorized = data.get("authorized")
    if not isinstance(authorized, list):
        _die("allowlist.authorized must be an array")
    out: set[str] = set()
    for row in authorized:
        if isinstance(row, dict):
            unit = str(row.get("unit") or "").strip()
        else:
            unit = str(row).strip()
        if unit:
            out.add(unit)
    return out


def allowlisted(unit: str, allowed: set[str]) -> bool:
    if unit in allowed:
        return True
    # Instance of an allowlisted template: pi-intake@fleet-ops matches pi-intake@
    if "@" in unit and not unit.endswith("@"):
        template = unit.split("@", 1)[0] + "@"
        if template in allowed:
            return True
    return False


def has_auth_signal(body: str) -> bool:
    return bool(AUTH_SIGNAL.search(body or ""))



def manifest_added_from_diff(diff_text: str) -> list[str]:
    """Pull newly-added MANIFEST lines out of a unified diff.

    Only lines added inside a MANIFEST file hunk count. This closes the
    MANIFEST-only gap when the conference feeds a normal PR JSON with
    `diff` but no separate manifest_added_lines list.
    """
    if not diff_text:
        return []
    out: list[str] = []
    in_manifest = False
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            in_manifest = " MANIFEST" in line or line.endswith("/MANIFEST") or (
                " a/MANIFEST " in line or line.endswith(" a/MANIFEST")
            ) or (" b/MANIFEST" in line)
            # Also match `diff --git a/MANIFEST b/MANIFEST`
            if "a/MANIFEST" in line and "b/MANIFEST" in line:
                in_manifest = True
            continue
        if line.startswith("+++ ") or line.startswith("--- "):
            # +++ b/MANIFEST
            if line[4:].strip().endswith("MANIFEST"):
                in_manifest = True
            continue
        if not in_manifest:
            continue
        if line.startswith("+") and not line.startswith("+++"):
            out.append(line[1:])
    return out


def new_machinery_from_name_status(
    name_status: str,
    manifest_added_lines: list[str] | None = None,
) -> list[dict[str, str]]:
    """Collect newly-added machinery paths/units from a name-status diff.

    Repairs (M) and deletions (D) are ignored. Renames/copies that introduce a
    new systemd/ unit path count as adds (dest).
    """
    found: list[dict[str, str]] = []
    seen: set[str] = set()

    for letter, path, _src in parse_name_status(name_status):
        if letter == "D":
            continue
        if letter == "M" and not is_manifest_path(path):
            # Repair of an existing unit file — ungated.
            continue
        if is_systemd_unit_path(path) and letter in ("A", "R", "C"):
            unit = unit_basename(path)
            if unit and path not in seen:
                seen.add(path)
                found.append({"kind": "systemd-file", "path": path, "unit": unit})

    # New MANIFEST lines that install a systemd/ unit.
    for line in manifest_added_lines or []:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) < 2:
            continue
        src = parts[0]
        if not is_systemd_unit_path(src):
            continue
        unit = unit_basename(src)
        key = f"MANIFEST:{src}"
        if unit and key not in seen:
            seen.add(key)
            found.append({"kind": "manifest-line", "path": src, "unit": unit})

    return found


def evaluate(payload: dict[str, Any]) -> dict[str, Any]:
    """Evaluate a PR-shaped payload.

    Accepted keys:
      name_status / name-status  — git diff --name-status text
      body                       — PR body
      allowlist / allowlist_path — inline object or path to JSON
      manifest_added_lines       — optional list of newly-added MANIFEST lines
      files                      — optional list of added paths (fallback)
    """
    name_status = str(
        payload.get("name_status")
        or payload.get("name-status")
        or payload.get("diff_name_status")
        or ""
    )
    body = str(payload.get("body") or "")
    allowlist_data = payload.get("allowlist")
    allowlist_path = payload.get("allowlist_path") or payload.get("allowlist-path")
    if isinstance(allowlist_data, dict):
        allowed = load_allowlist(data=allowlist_data)
    else:
        path = str(allowlist_path) if allowlist_path else None
        if not path and isinstance(allowlist_data, str):
            path = allowlist_data
        allowed = load_allowlist(path=path)

    manifest_added = payload.get("manifest_added_lines") or payload.get(
        "manifest-added-lines"
    )
    if manifest_added is None:
        manifest_added = []
    if not isinstance(manifest_added, list):
        _die("manifest_added_lines must be a list")
    # Close the MANIFEST-only gap: when the PR JSON carries a unified
    # `diff`, harvest newly-added MANIFEST lines from it.
    if not manifest_added:
        manifest_added = manifest_added_from_diff(str(payload.get("diff") or ""))

    # Fallback: files[] marked as added systemd paths when name_status empty.
    if not name_status and payload.get("files"):
        lines = []
        for entry in payload["files"]:
            if isinstance(entry, dict):
                status = str(entry.get("status") or "A")
                path = str(entry.get("path") or entry.get("filename") or "")
            else:
                status, path = "A", str(entry)
            if path:
                lines.append(f"{status[0]}\t{path}")
        name_status = "\n".join(lines)

    additions = new_machinery_from_name_status(name_status, list(manifest_added))
    if not additions:
        return {
            "verdict": "PASS",
            "reason": "no new systemd/** unit files or MANIFEST unit lines",
        }

    if has_auth_signal(body):
        return {
            "verdict": "PASS",
            "reason": "Nish-only authorization signal present (authorized-by-nish:)",
            "additions": additions,
        }

    rejected = [row for row in additions if not allowlisted(row["unit"], allowed)]
    if not rejected:
        return {
            "verdict": "PASS",
            "reason": "all new machinery units are on the allowlist",
            "additions": additions,
        }

    return {
        "verdict": "REJECT",
        "rule": LEDGER_LINE,
        "reason": (
            "new machinery is default-DENIED: unit(s) not on "
            "config/machinery-allowlist.json and no authorized-by-nish: "
            "signal (fleet-ops#1548)"
        ),
        "rejected": rejected,
        "additions": additions,
    }


def _is_hand_placed_fragment(path: str) -> bool:
    """True when the unit fragment is a real file under the user unit dir."""
    if not path:
        return False
    for marker in TRANSIENT_DIR_MARKERS:
        if marker in path:
            return False
    try:
        p = Path(path)
    except (TypeError, ValueError):
        return False
    if not p.is_file():
        return False
    # Symlink into the repo deploy-clone = sanctioned channel; ungated here.
    if p.is_symlink():
        return False
    return True


def _unit_stem_from_unit_file(name: str) -> str | None:
    """pi-intake@fleet-ops.service → pi-intake@fleet-ops; template files keep @."""
    for suf in UNIT_SUFFIXES:
        if name.endswith(suf):
            return name[: -len(suf)]
    return None


def hunt(payload: dict[str, Any]) -> dict[str, Any]:
    """Flag hand-placed (non-symlink) user units not on the allowlist.

    Payload keys:
      allowlist / allowlist_path
      unit_files — optional fixture list of
        {unit, path, symlink?}  (symlink true skips; path real-file required)
      unit_dir   — live scan root (default ~/.config/systemd/user)
    """
    allowlist_data = payload.get("allowlist")
    allowlist_path = payload.get("allowlist_path") or payload.get("allowlist-path")
    if isinstance(allowlist_data, dict):
        allowed = load_allowlist(data=allowlist_data)
    else:
        path = str(allowlist_path) if allowlist_path else None
        if not path and isinstance(allowlist_data, str):
            path = allowlist_data
        allowed = load_allowlist(path=path)

    findings: list[dict[str, Any]] = []
    rank = 80
    seen: set[str] = set()

    unit_files = payload.get("unit_files") or payload.get("unit-files")
    if unit_files is None:
        unit_dir = Path(
            str(
                payload.get("unit_dir")
                or payload.get("unit-dir")
                or Path.home() / ".config/systemd/user"
            )
        ).expanduser()
        unit_files = []
        if unit_dir.is_dir():
            for entry in sorted(unit_dir.iterdir()):
                if not entry.name.endswith(UNIT_SUFFIXES):
                    continue
                stem = _unit_stem_from_unit_file(entry.name)
                if not stem:
                    continue
                try:
                    is_link = entry.is_symlink()
                except OSError:
                    continue
                unit_files.append(
                    {
                        "unit": stem,
                        "path": str(entry),
                        "symlink": is_link,
                    }
                )

    for row in unit_files:
        if not isinstance(row, dict):
            continue
        unit = str(row.get("unit") or "").strip()
        path = str(row.get("path") or "").strip()
        if not unit:
            continue
        if row.get("symlink") is True:
            continue
        # Fixture may omit symlink and rely on path inspection.
        if row.get("symlink") is None and path:
            if not _is_hand_placed_fragment(path):
                continue
        elif row.get("symlink") is False and path:
            # Explicit hand-placed fixture: still require a real-looking path
            # unless the caller is a pure fixture (path may be synthetic).
            p = Path(path)
            if p.exists() and (p.is_symlink() or not p.is_file()):
                continue
        elif row.get("symlink") is not False:
            continue

        if allowlisted(unit, allowed):
            continue
        if unit in seen:
            continue
        seen.add(unit)
        findings.append(
            {
                "rank": rank,
                "title": f"hand-placed machinery not on allowlist: {unit}",
                "body": (
                    "A non-transient user unit fragment is a real file under "
                    "~/.config/systemd/user/ and is not on "
                    "config/machinery-allowlist.json. Automatic blind-audit "
                    "finding (fleet-ops#1548). Route to senior conference: "
                    "MECHANICAL-INSTEAD / EXCEPTION-APPROVED / NISH-RESERVED."
                ),
                "severity": "high",
                "evidence": f"unit={unit} path={path}",
                "unit": unit,
                "path": path,
            }
        )
        rank += 1

    return {"findings": findings}


def _read_text(path: str | None) -> str:
    if path in (None, "", "-"):
        return sys.stdin.read()
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _load_json(path: str | None) -> dict[str, Any]:
    raw = _read_text(path)
    if not raw.strip():
        raise SystemExit("empty input")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise SystemExit("input must be a JSON object")
    return data


def _default_allowlist_path() -> str:
    here = Path(__file__).resolve().parent
    candidates = [
        os.environ.get("MACHINERY_ALLOWLIST"),
        str(here.parent / "config" / "machinery-allowlist.json"),
        str(Path.home() / ".local/state/pi-packet/machinery-allowlist.json"),
    ]
    for cand in candidates:
        if cand and Path(cand).is_file():
            return cand
    return str(here.parent / "config" / "machinery-allowlist.json")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Machinery-authorization gate (fleet-ops#1548). Pure evaluator."
        )
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="evaluate",
        choices=["evaluate", "hunt"],
        help="evaluate a PR diff (default) or hunt hand-placed units",
    )
    parser.add_argument("--input", "-i", help="JSON file (default: stdin for JSON mode)")
    parser.add_argument(
        "--name-status",
        help="git diff --name-status output (file or -); evaluate mode",
    )
    parser.add_argument("--body", help="PR body file (evaluate mode)")
    parser.add_argument(
        "--allowlist",
        help="path to config/machinery-allowlist.json",
    )
    parser.add_argument(
        "--manifest-added",
        help="file of newly-added MANIFEST lines (one per line); evaluate mode",
    )
    parser.add_argument(
        "--unit-dir",
        help="live user unit dir for hunt (default ~/.config/systemd/user)",
    )
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="print the decisions-ledger line verbatim and exit 0",
    )
    args = parser.parse_args(argv)

    if args.ledger_line:
        sys.stdout.write(LEDGER_LINE + "\n")
        return 0

    allowlist = args.allowlist or _default_allowlist_path()

    if args.command == "hunt":
        if args.input:
            payload = _load_json(args.input)
            payload.setdefault("allowlist_path", allowlist)
            if args.unit_dir:
                payload["unit_dir"] = args.unit_dir
        else:
            payload = {"allowlist_path": allowlist}
            if args.unit_dir:
                payload["unit_dir"] = args.unit_dir
        result = hunt(payload)
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
        return 0

    # evaluate
    if args.name_status is not None or args.body is not None:
        ns = _read_text(args.name_status) if args.name_status is not None else ""
        body = _read_text(args.body) if args.body is not None else ""
        manifest_added: list[str] = []
        if args.manifest_added:
            manifest_added = _read_text(args.manifest_added).splitlines()
        payload = {
            "name_status": ns,
            "body": body,
            "allowlist_path": allowlist,
            "manifest_added_lines": manifest_added,
        }
    elif args.input or not sys.stdin.isatty():
        payload = _load_json(args.input)
        payload.setdefault("allowlist_path", allowlist)
    else:
        parser.error("evaluate needs --name-status/--body or --input JSON / stdin")

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
