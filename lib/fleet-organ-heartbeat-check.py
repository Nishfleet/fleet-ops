#!/usr/bin/env python3
"""fleet-organ-heartbeat-check — the organ-heartbeat invariant (fleet-ops#1010).

Standing pattern (Nish, 2026-08-27): every fleet organ (timer/exporter/guard/
canary) must export a heartbeat metric and ship an `absent(<heartbeat_metric>)`
rule in config/fleet_rules.yml in the same PR. An organ without an absent-rule
is an organ whose death is invisible; the alert-repair rail can only summon a
replacement builder if the absence is observable.

Two subcommands:

  verify (default)   Drill. Enumerate config/fleet-organs.json and assert each
                     organ's `absent_alert` exists in fleet_rules.yml with an
                     `expr` containing `absent(` AND the `heartbeat_metric`.
                     Exit 1 if any organ is missing its rule. This is the
                     mechanical invariant the nested-host CI drill runs.

  gate               PR-diff gate (the #366 mechanical-fix gate for this
                     class). Rejects a PR that adds/changes a fleet organ
                     without shipping/keeping its absent() rule.

                     Inputs:
                       --name-status FILE   git diff --name-status output
                       --rules FILE         current config/fleet_rules.yml
                       --rules-diff FILE    git diff of config/fleet_rules.yml
                       --body FILE          PR body (for the organ-heartbeat:
                                           marker on new candidate-organ files)
                       [--registry FILE]    default config/fleet-organs.json

                     Exit 0: no organ touched, or every touched organ ships/
                             keeps its absent() rule.
                     Exit 1: a touched organ is missing/deleting its absent()
                             rule, or a new candidate-organ file is neither
                             registered nor declared not-an-organ.
                     Exit 2: usage / IO error.

Pure evaluator. No git calls, no dispatch, no GitHub writes. Stdlib only
(no PyYAML): fleet_rules.yml is parsed line-by-line for `- alert: NAME` blocks
and their `expr:` line, which is all the invariant needs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

REGISTRY_DEFAULT = "config/fleet-organs.json"
RULES_DEFAULT = "config/fleet_rules.yml"

REQUIRED_ORGAN_FIELDS = ("name", "kind", "heartbeat_metric", "absent_alert", "files")
VALID_KINDS = {"timer", "exporter", "guard", "canary"}

# A new file matching one of these shapes is a CANDIDATE organ: the gate flags
# it and requires either a registry entry + absent() rule, or an
# `organ-heartbeat: not-an-organ: <reason>` body declaration. Status-A only —
# existing files are never flagged. Conservative on purpose: plain timers and
# generic bins are NOT organs by shape (not every timer exports a heartbeat
# metric); the registry is the contract that names an organ.
NEW_ORGAN_SHAPE_RES = [
    re.compile(r"^libexec/.*export.*\.py$"),
    re.compile(r"^libexec/.*-export\.py$"),
    re.compile(r"^libexec/.*canary.*$"),
    re.compile(r"^libexec/.*guard.*$"),
    re.compile(r"^bin/fleet-.*canary.*$"),
    re.compile(r"^bin/fleet-.*guard.*$"),
]

ALERT_RE = re.compile(r"^\s*-\s*alert:\s*(\S+)\s*$")
EXPR_RE = re.compile(r"^\s*expr:\s*(.+?)\s*$")


def _here() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def _repo_root() -> str:
    # lib/ -> repo root. Fall back to cwd if the path does not resolve
    # (tests pass absolute --registry/--rules paths).
    root = os.path.dirname(_here())
    if os.path.isdir(os.path.join(root, "config")):
        return root
    return os.getcwd()


def _resolve(path: str, default: str) -> str:
    if path:
        return path
    return os.path.join(_repo_root(), default)


def load_registry(path: str) -> list[dict[str, Any]]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    organs = data.get("organs") if isinstance(data, dict) else None
    if not isinstance(organs, list) or not organs:
        raise ValueError(f"registry {path}: missing non-empty 'organs' array")
    seen: set[str] = set()
    for o in organs:
        if not isinstance(o, dict):
            raise ValueError(f"registry {path}: organ entry is not an object")
        for f in REQUIRED_ORGAN_FIELDS:
            if f not in o:
                raise ValueError(f"registry {path}: organ missing field {f!r}: {o}")
        name = str(o["name"])
        if not name:
            raise ValueError(f"registry {path}: organ name is empty")
        if name in seen:
            raise ValueError(f"registry {path}: duplicate organ name {name!r}")
        seen.add(name)
        if str(o["kind"]) not in VALID_KINDS:
            raise ValueError(
                f"registry {path}: organ {name!r} kind {o['kind']!r} not in {sorted(VALID_KINDS)}"
            )
        if not str(o["heartbeat_metric"]):
            raise ValueError(f"registry {path}: organ {name!r} heartbeat_metric empty")
        if not str(o["absent_alert"]):
            raise ValueError(f"registry {path}: organ {name!r} absent_alert empty")
        if not isinstance(o["files"], list):
            raise ValueError(f"registry {path}: organ {name!r} files is not a list")
    return organs


def parse_rules_alerts(rules_text: str) -> dict[str, str]:
    """Map alert name -> expr string (raw, single-line). Multi-line exprs
    (none today) collapse to the first expr line; the invariant only needs
    the absent(...) fragment which lives on the expr line."""
    alerts: dict[str, str] = {}
    current: str | None = None
    for line in rules_text.splitlines():
        m = ALERT_RE.match(line)
        if m:
            current = m.group(1)
            alerts[current] = ""
            continue
        if current is not None:
            em = EXPR_RE.match(line)
            if em and alerts.get(current, "") == "":
                alerts[current] = em.group(1)
    return alerts


def organ_has_absent_rule(organ: dict[str, Any], alerts: dict[str, str]) -> bool:
    name = str(organ["absent_alert"])
    metric = str(organ["heartbeat_metric"])
    expr = alerts.get(name, "")
    if not expr:
        return False
    if "absent(" not in expr:
        return False
    return metric in expr


# --- verify (drill) --------------------------------------------------------

def cmd_verify(args: argparse.Namespace) -> int:
    registry_path = _resolve(args.registry, REGISTRY_DEFAULT)
    rules_path = _resolve(args.rules, RULES_DEFAULT)
    try:
        organs = load_registry(registry_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"verify: registry load failed: {exc}", file=sys.stderr)
        return 2
    try:
        with open(rules_path, encoding="utf-8") as fh:
            alerts = parse_rules_alerts(fh.read())
    except OSError as exc:
        print(f"verify: rules load failed: {exc}", file=sys.stderr)
        return 2

    missing: list[str] = []
    for o in organs:
        if organ_has_absent_rule(o, alerts):
            print(f"OK: organ {o['name']} -> {o['absent_alert']} absent({o['heartbeat_metric']})")
        else:
            missing.append(str(o["name"]))
            print(
                f"FAIL: organ {o['name']} missing absent() rule: "
                f"alert {o['absent_alert']!r} must have expr with absent( and "
                f"metric {o['heartbeat_metric']!r}",
                file=sys.stderr,
            )
    if missing:
        print(
            f"REJECT: {len(missing)} organ(s) missing their absent() heartbeat rule: "
            f"{', '.join(missing)}. Every fleet organ ships an absent() rule in the "
            f"same PR (fleet-ops#1010).",
            file=sys.stderr,
        )
        return 1
    print(f"OK: all {len(organs)} registered organs have an absent() heartbeat rule")
    return 0


# --- gate (PR-diff) --------------------------------------------------------

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
            # R100\told\tnew
            dest = parts[2] if len(parts) > 2 else (parts[1] if len(parts) > 1 else "")
            rows.append((letter, dest, parts[1] if len(parts) > 1 else ""))
        # else: ignore (e.g. T typechange, U unmerged)
    return rows


def is_new_organ_shape(path: str) -> bool:
    return any(rx.match(path) for rx in NEW_ORGAN_SHAPE_RES)


def _diff_added_lines(diff_text: str) -> list[str]:
    out: list[str] = []
    for line in diff_text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            out.append(line[1:])
    return out


def _diff_removed_lines(diff_text: str) -> list[str]:
    out: list[str] = []
    for line in diff_text.splitlines():
        if line.startswith("-") and not line.startswith("---"):
            out.append(line[1:])
    return out


def _diff_has_absent_for_metric(diff_text: str, metric: str, added: bool) -> bool:
    lines = _diff_added_lines(diff_text) if added else _diff_removed_lines(diff_text)
    return any("absent(" in ln and metric in ln for ln in lines)


def _body_organ_heartbeat_marker(body: str, path: str) -> str | None:
    """Return the organ-heartbeat: declaration for a path, or None.

    Accepted shapes:
      organ-heartbeat: <path> <metric> <alert>     (it IS an organ; register it)
      organ-heartbeat: <path> not-an-organ: <reason>
    The path may be omitted (the declaration applies to any candidate file
    in the diff); if present it must match.
    """
    for line in body.splitlines():
        s = line.strip()
        if not s.lower().startswith("organ-heartbeat:"):
            continue
        rest = s[len("organ-heartbeat:"):].strip()
        if not rest:
            continue
        # If the first token is a path that does not match, skip this line.
        first = rest.split()[0]
        if first and ("/" in first or first.endswith(".py") or first.endswith(".sh")):
            if first != path:
                continue
            rest = rest[len(first):].strip()
        if not rest:
            continue
        return rest
    return None


def cmd_gate(args: argparse.Namespace) -> int:
    registry_path = _resolve(args.registry, REGISTRY_DEFAULT)
    rules_path = _resolve(args.rules, RULES_DEFAULT)
    try:
        organs = load_registry(registry_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"gate: registry load failed: {exc}", file=sys.stderr)
        return 2
    try:
        with open(rules_path, encoding="utf-8") as fh:
            rules_text = fh.read()
    except OSError as exc:
        print(f"gate: rules load failed: {exc}", file=sys.stderr)
        return 2
    try:
        with open(args.name_status, encoding="utf-8") as fh:
            ns_text = fh.read()
    except OSError as exc:
        print(f"gate: name-status load failed: {exc}", file=sys.stderr)
        return 2
    rules_diff = ""
    if args.rules_diff:
        try:
            with open(args.rules_diff, encoding="utf-8") as fh:
                rules_diff = fh.read()
        except OSError as exc:
            print(f"gate: rules-diff load failed: {exc}", file=sys.stderr)
            return 2
    body = ""
    if args.body:
        try:
            with open(args.body, encoding="utf-8") as fh:
                body = fh.read()
        except OSError as exc:
            print(f"gate: body load failed: {exc}", file=sys.stderr)
            return 2

    alerts = parse_rules_alerts(rules_text)
    file_to_organs: dict[str, list[dict[str, Any]]] = {}
    for o in organs:
        for f in o["files"]:
            file_to_organs.setdefault(str(f), []).append(o)

    rows = parse_name_status(ns_text)
    registry_path_rel = os.path.relpath(registry_path, _repo_root())
    registry_touched = False
    touched_organ_files: list[tuple[str, dict[str, Any]]] = []
    new_candidate_files: list[str] = []

    for letter, path, _src in rows:
        if not path:
            continue
        if path == registry_path_rel or path == "config/fleet-organs.json":
            registry_touched = True
        if path in file_to_organs:
            for o in file_to_organs[path]:
                touched_organ_files.append((path, o))
        elif letter == "A" and is_new_organ_shape(path):
            new_candidate_files.append(path)

    if not touched_organ_files and not new_candidate_files and not registry_touched:
        print("SKIP: no fleet organ touched in the diff")
        return 0

    rejects: list[str] = []

    # Check A + C: touched registered organ must keep / ship its absent() rule.
    seen_organs: set[str] = set()
    for path, o in touched_organ_files:
        if o["name"] in seen_organs:
            continue
        seen_organs.add(o["name"])
        metric = str(o["heartbeat_metric"])
        rule_present = organ_has_absent_rule(o, alerts)
        if rule_present:
            # Must not be silently deleted in this diff (deleted and not re-added).
            if _diff_has_absent_for_metric(rules_diff, metric, added=False) and not _diff_has_absent_for_metric(
                rules_diff, metric, added=True
            ):
                rejects.append(
                    f"organ {o['name']!r}: PR touches {path} but the diff deletes its "
                    f"absent({metric}) rule from fleet_rules.yml without re-adding it. "
                    f"An organ whose absent() rule is removed is an organ whose death is "
                    f"invisible (fleet-ops#1010)."
                )
        else:
            # Rule missing from current rules: the diff must add it.
            if not _diff_has_absent_for_metric(rules_diff, metric, added=True):
                rejects.append(
                    f"organ {o['name']!r}: PR touches {path} but its absent({metric}) rule "
                    f"is missing from fleet_rules.yml and the diff does not add it. Ship "
                    f"the absent() rule in the same PR (fleet-ops#1010)."
                )

    # Check B: a new candidate-organ file must be registered + ruled, or
    # declared not-an-organ in the PR body.
    registered_paths = {f for o in organs for f in o["files"]}
    for path in new_candidate_files:
        if path in registered_paths:
            continue  # the registry already names it (added in this same diff)
        marker = _body_organ_heartbeat_marker(body, path)
        if marker is None:
            rejects.append(
                f"new candidate-organ file {path} is not registered in "
                f"config/fleet-organs.json. If it exports a heartbeat metric, "
                f"register it AND ship its absent() rule in fleet_rules.yml in "
                f"this PR. If it is NOT an organ (no heartbeat metric), add an "
                f"`organ-heartbeat: {path} not-an-organ: <reason>` line to the "
                f"PR body (fleet-ops#1010)."
            )
        elif marker.lower().startswith("not-an-organ:"):
            print(f"OK: {path} declared not-an-organ: {marker[len('not-an-organ:'):].strip()}")
        else:
            # Declared as an organ (<metric> <alert>): must be registered. The
            # matching absent() rule is then enforced by Check D below
            # (registry touched -> every organ has its rule or adds it).
            if path not in registered_paths:
                rejects.append(
                    f"new candidate-organ file {path}: PR body declares it an organ "
                    f"({marker!r}) but it is not in config/fleet-organs.json. Register "
                    f"it and ship its absent() rule (fleet-ops#1010)."
                )

    # Check D: registry touched -> every organ in the (post-edit) registry must
    # have its rule in current rules or add it in the diff. This catches a new
    # registry entry shipped without its absent() rule.
    if registry_touched:
        for o in organs:
            if organ_has_absent_rule(o, alerts):
                continue
            metric = str(o["heartbeat_metric"])
            if not _diff_has_absent_for_metric(rules_diff, metric, added=True):
                rejects.append(
                    f"registry adds/changes organ {o['name']!r} but its absent({metric}) "
                    f"rule is missing from fleet_rules.yml and the diff does not add it "
                    f"(fleet-ops#1010)."
                )

    if rejects:
        for r in rejects:
            print(f"REJECT: {r}", file=sys.stderr)
        print(
            "REJECT: organ-heartbeat invariant violated. Every fleet organ ships an "
            "absent() rule in the same PR (fleet-ops#1010).",
            file=sys.stderr,
        )
        return 1

    touched = sorted({o["name"] for _, o in touched_organ_files})
    print(
        f"OK: organ-heartbeat invariant holds "
        f"(touched organs: {', '.join(touched) if touched else 'none'}; "
        f"new candidates: {', '.join(new_candidate_files) if new_candidate_files else 'none'}; "
        f"registry touched: {registry_touched})"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fleet-organ-heartbeat-check",
        description="fleet-ops#1010 organ-heartbeat invariant (verify drill + PR gate).",
    )
    sub = p.add_subparsers(dest="cmd")

    v = sub.add_parser("verify", help="drill: assert every registered organ has an absent() rule")
    v.add_argument("--registry", default="", help=f"registry JSON (default {REGISTRY_DEFAULT})")
    v.add_argument("--rules", default="", help=f"fleet_rules.yml (default {RULES_DEFAULT})")
    v.set_defaults(func=cmd_verify)

    g = sub.add_parser("gate", help="PR-diff gate: reject an organ touch without its absent() rule")
    g.add_argument("--name-status", required=True, help="git diff --name-status output (file or -)")
    g.add_argument("--rules", default="", help=f"current fleet_rules.yml (default {RULES_DEFAULT})")
    g.add_argument("--rules-diff", default="", help="git diff of config/fleet_rules.yml (file)")
    g.add_argument("--body", default="", help="PR body file (for organ-heartbeat: marker)")
    g.add_argument("--registry", default="", help=f"registry JSON (default {REGISTRY_DEFAULT})")
    g.set_defaults(func=cmd_gate)
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        # Default subcommand: verify (drill).
        args = parser.parse_args(["verify"])
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
