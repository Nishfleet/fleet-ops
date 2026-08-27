#!/usr/bin/env python3
"""Same-repo `Closes <owner>/<repo>#N` rejection gate (fleet-ops#695).

A PR body that references the same repo with the cross-repo reference syntax
(`Closes fleet-ops#567`) does NOT close the issue in that repo — GitHub's
auto-close only fires for `Closes #N` (or a fully qualified
`Closes Nishfleet/fleet-ops#567` whose `<owner>/<repo>` matches the PR's
target repo). The short owner-prefixed form `Closes fleet-ops#567` is the
visible "this will close" syntax a human reads, but on the same repo it is
a no-op reference: GitHub's GraphQL `closingIssuesReferences` returns empty,
the issue stays OPEN, and a future worker picks the same issue up again
(fleet-ops#567 was claimed after PR #591 already shipped the stub).

This is a pure evaluator: no dispatch, no retry, no GitHub writes.

Subcommands:
  evaluate (default)  PR JSON on stdin / --input → verdict JSON
  --ledger-line       print the decisions-ledger line verbatim
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

# Verbatim decisions-ledger line. The senior conference REJECT verdict
# carries this text; the gate is the deterministic counterpart to the
# human auditor's reading of the same rule.
LEDGER_LINE = (
    "STANDING, NON-NEGOTIABLE: when a PR closes a same-repo issue, the "
    "reference must be `Closes #N` (or `Closes Nishfleet/fleet-ops#N` with "
    "the full owner/repo matching the PR's base repo). The short "
    "`Closes <repo>#N` form on a same-repo PR is a cross-repo reference "
    "and does not auto-close; the issue stays OPEN and is re-claimed by a "
    "later worker. Reject the pattern, cite the closingIssuesReferences "
    "evidence, and require the body to use the same-repo `Closes #N` form "
    "(fleet-ops #695). Origin: 08-27 — PR #591 merged with "
    "`Closes fleet-ops#567` and `Closes fleet-ops#568`, both stayed open; "
    "#567 was re-claimed after the stub was already on main."
)

# Match a "closing keyword" followed by either:
#   1. #<digits>          — same-repo short form (PASSES)
#   2. <owner>/<repo>#<n> — cross-repo / fully-qualified form (only PASSES
#                           when the owner/repo matches the PR's base repo)
#   3. <repo>#<n>        — short owner-prefixed form (cross-repo syntax;
#                           REJECTED when the PR's base repo is <owner>/<repo>
#                           because GitHub treats it as a non-matching
#                           cross-repo reference and does not auto-close)
#
# We use line-start or whitespace anchoring and a negative-lookbehind for
# markdown link syntax `[...](...)` so embedded references inside link URLs
# do not match (none of the closing keywords is allowed inside a link
# target by GitHub's auto-close parser anyway).
CLOSING_KEYWORDS = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
# GitHub's auto-close parser requires the closing keyword to be at the
# start of a line (or, per the docs, after a space). In practice the
# platform is strict: PR #780's `Closes the loop. Closes fleet-ops#768.`
# mid-line produced `closingIssuesReferences: []`. We mirror that
# strictness for the bare `Closes #N` and fully-qualified forms (the
# gates' two PASS paths), but for the same-repo short-owner form we
# match anywhere in the body — that form is the failure-fix pattern
# (PR #591, #780, #582 all shipped the stub on main while the issue
# stayed OPEN because the body used the cross-repo syntax). Catching
# mid-line occurrences of the buggy form is the whole point; the prose
# false-positive risk is low because the short-owner form `Closes
# <repo>#<n>` is almost never used outside an intentional closing
# reference.
SHORT_OWNER_REF = re.compile(
    r"(?<![(\[\x60\"'>])"  # not inside parens / brackets / backticks / quotes / blockquotes
    + r"\b(?i:" + CLOSING_KEYWORDS + r")\b"
    + r"\s+"
    + r"(?P<short>[A-Za-z0-9_.-]+)\s*#\s*(?P<snum>\d+)",
    re.IGNORECASE,
)
# Bare / fully-qualified refs are still line-anchored so we don't
# mistake prose like "the body claims to close #567" for a closing
# reference, AND so we don't REJECT a PR whose body says "Closes
# the loop" mid-line as if it were a closing reference. GitHub's
# own parser is line-anchored for these forms; we mirror that.
LINE_PREFIX = r"(?:^|\n)[ \t>]*(?:[-*][ \t]+)?"
ISSUE_REF = re.compile(
    LINE_PREFIX
    + r"(?<![(\[])"
    + r"\b(?i:" + CLOSING_KEYWORDS + r")\b"
    + r"\s+"
    + r"("
    + r"(?P<fully>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*#\s*(?P<fnum>\d+)"
    + r"|"
    + r"(?P<short>[A-Za-z0-9_.-]+)\s*#\s*(?P<snum>\d+)"
    + r"|"
    + r"#\s*(?P<bare>\d+)"
    + r")",
    re.IGNORECASE | re.MULTILINE,
)
SAME_REPO_BARE = re.compile(r"^\s*#\s*\d+\s*$")
ALIAS_TOKENS = {"git": ".git", "http": "", "https": "", "ssh": ""}


def _normalize_repo(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip().strip("[]()")
    text = text.removesuffix(".git")
    text = text.replace("\\", "/")
    text = re.sub(r"https?://github\.com/", "", text, flags=re.IGNORECASE)
    text = re.sub(r"^git@github\.com:", "", text, flags=re.IGNORECASE)
    text = text.strip("/")
    if "/" not in text:
        return None
    owner, _, name = text.partition("/")
    owner = owner.strip()
    name = name.strip()
    if not owner or not name:
        return None
    if owner.lower() in ALIAS_TOKENS or name.lower() in ALIAS_TOKENS:
        return None
    return f"{owner.lower()}/{name.lower()}"


def base_repo_key(pr: dict[str, Any]) -> str | None:
    """Return the normalised `owner/name` key for the PR's base repo."""
    for key in ("base_repository", "baseRepository", "base_repo", "head_repository",
                "headRepository", "head_repo", "repository", "repo"):
        value = pr.get(key)
        if isinstance(value, dict):
            owner = value.get("owner") or {}
            name = value.get("name")
            if isinstance(owner, dict):
                owner_login = owner.get("login") or owner.get("name")
            else:
                owner_login = owner
            if owner_login and name:
                normalized = _normalize_repo(f"{owner_login}/{name}")
                if normalized:
                    return normalized
        else:
            normalized = _normalize_repo(value)
            if normalized:
                return normalized
    return None


def _issue_keys_from_closing(closing: Any) -> set[str]:
    """Normalise `closingIssuesReferences` into `owner/name#n` keys.

    GitHub's GraphQL returns `{number, repository: {owner: {login}, name}}`.
    If the repo is missing (it usually is for same-repo references) we
    cannot tell from this field alone — the gate relies on the body's
    reference syntax for that.
    """
    out: set[str] = set()
    if not isinstance(closing, list):
        return out
    for item in closing:
        if not isinstance(item, dict):
            continue
        number = item.get("number")
        repo = item.get("repository") or {}
        owner = repo.get("owner") or {}
        owner_login = (
            owner.get("login") if isinstance(owner, dict) else owner
        ) or None
        name = repo.get("name") if isinstance(repo, dict) else None
        if owner_login and name and number is not None:
            out.add(f"{owner_login.lower()}/{str(name).lower()}#{number}")
        elif number is not None:
            out.add(f"#?{number}")
    return out


def find_bad_references(
    body: str,
    base_key: str | None,
    closed_numbers: set[int] | None = None,
) -> list[dict[str, str]]:
    """Find same-repo `Closes <repo>#N` (short owner-prefixed) references.

    The short-owner form is the failure-fix pattern: a same-repo PR that
    writes `Closes fleet-ops#567` instead of `Closes #567` (or
    `Closes Nishfleet/fleet-ops#567`). GitHub parses the cross-repo
    short-owner form as a non-matching cross-repo reference, the issue
    stays OPEN, and a later worker re-claims it. We deliberately match
    this form anywhere in the body (not just at line start) because
    PR #780 / #582 both shipped the stub on main while the body used
    the cross-repo syntax mid-line.

    Cross-check: a short-owner mention whose number IS in
    `closed_numbers` is not flagged. The close already fired (via a
    sibling `Closes #N` or `Closes owner/repo#N` in the body) and the
    prose mention is benign. PR #594 has both
    `Close fleet-ops#480 now that ...` (prose) and `Closes #480.` (the
    real closing reference); without the cross-check, the prose mention
    would REJECT an otherwise-correctly-formed PR.

    Returns a list of offending references. Each entry carries:
      - `match`: the matched text (e.g. "Closes fleet-ops#567")
      - `owner`: "" (short form has no owner)
      - `repo`:  the parsed `<repo>` token
      - `number`: the issue number as a string
      - `form`:  "short-owner"
    """
    findings: list[dict[str, str]] = []
    if not isinstance(body, str) or not body:
        return findings
    if not base_key:
        return findings  # no base repo -> cannot tell same-repo from cross-repo
    base_name = base_key.split("/", 1)[1]
    for match in SHORT_OWNER_REF.finditer(body):
        owner_repo_token = match.group("short")
        try:
            number_int = int(match.group("snum"))
        except (TypeError, ValueError):
            continue
        if closed_numbers is not None and number_int in closed_numbers:
            # The platform already parsed this close via a sibling
            # bare / fully-qualified form; the prose mention is benign.
            continue
        if owner_repo_token.lower() == base_name:
            findings.append({
                "match": match.group(0).strip(),
                "owner": "",
                "repo": owner_repo_token,
                "number": str(number_int),
                "form": "short-owner",
            })
    return findings


def find_passing_closing_refs(body: str) -> dict[str, list[dict[str, str]]]:
    """Find line-anchored closing references that GitHub WILL auto-close.

    Two PASS paths:
      - `Closes #N` (bare same-repo form)
      - `Closes <owner>/<repo>#N` (fully-qualified form, regardless of
        whether it matches the PR's base repo; we only need to know the
        syntax is in scope of the platform's parser)

    The third branch of `ISSUE_REF` (short-owner) is also matched here
    so the missing-closes check can compare body claims vs parsed
    references; it is treated separately in `find_bad_references`.
    """
    out: dict[str, list[dict[str, str]]] = {"bare": [], "fully": [], "short": []}
    if not isinstance(body, str) or not body:
        return out
    for match in ISSUE_REF.finditer(body):
        matched = match.group(0).lstrip("\n").strip()
        groups = match.groupdict()
        if groups.get("bare"):
            out["bare"].append({
                "match": matched,
                "number": groups["bare"],
            })
        elif groups.get("fully"):
            out["fully"].append({
                "match": matched,
                "owner_repo": groups["fully"],
                "number": groups["fnum"],
            })
        elif groups.get("short"):
            out["short"].append({
                "match": matched,
                "repo": groups["short"],
                "number": groups["snum"],
            })
    return out


def evaluate(pr: dict[str, Any]) -> dict[str, Any]:
    body = str(pr.get("body") or "")
    base_key = base_repo_key(pr)
    closing = pr.get("closingIssuesReferences") or pr.get("closing_issues") or []
    closed_keys = _issue_keys_from_closing(closing)
    closed_numbers: set[int] = set()
    for key in closed_keys:
        if "#" in key:
            tail = key.rsplit("#", 1)[-1]
            try:
                closed_numbers.add(int(tail))
            except (TypeError, ValueError):
                continue
    # A short-owner mention whose number is in closingIssuesReferences
    # is benign (the close fired via a sibling bare/fully-qualified form);
    # see find_bad_references for the PR-594-style cross-check.
    bad = find_bad_references(body, base_key, closed_numbers=closed_numbers)
    base_prefix = f"{base_key}#" if base_key else None

    # Missing-closes check: body lists `Closes #N` (line-anchored, the
    # form that GitHub's parser actually auto-closes) but
    # `closingIssuesReferences` doesn't include that issue. The body LOOKS
    # like it closes the issue but the platform didn't parse it. The most
    # common cause is a same-repo short-owner form somewhere in the body
    # that displaced the parse, but the deterministic check here is
    # purely "body said #N is closing, GraphQL says it isn't." If we have
    # a base repo and any `Closes #N`-shaped reference in the body whose
    # bare number does not show up in `closingIssuesReferences` for the
    # same base, that is a hard REJECT.
    refs = find_passing_closing_refs(body)
    bare_refs = refs["bare"]
    fully_refs = refs["fully"]
    missing_closes: list[str] = []
    if base_prefix:
        # Same-repo bare references: `Closes #N` on a PR in owner/name.
        for entry in bare_refs:
            try:
                n = int(entry["number"])
            except (TypeError, ValueError):
                continue
            expected = f"{base_prefix}{n}"
            if expected not in closed_keys:
                if not closed_keys:
                    missing_closes.append(f"{entry['match']} (parsed-closes=[])")
                else:
                    missing_closes.append(f"{entry['match']} (parsed-closes=missing)")
        # Same-repo fully-qualified: `Closes Nishfleet/fleet-ops#N` on a
        # PR in Nishfleet/fleet-ops.
        for entry in fully_refs:
            normalized = _normalize_repo(entry["owner_repo"])
            if normalized == base_key:
                try:
                    n = int(entry["number"])
                except (TypeError, ValueError):
                    continue
                expected = f"{base_prefix}{n}"
                if expected not in closed_keys:
                    if not closed_keys:
                        missing_closes.append(
                            f"{entry['match']} (parsed-closes=[])"
                        )
                    else:
                        missing_closes.append(
                            f"{entry['match']} (parsed-closes=missing)"
                        )

    if bad:
        return {
            "verdict": "REJECT",
            "rule": LEDGER_LINE,
            "reason": (
                "PR body uses the cross-repo `Closes <repo>#N` syntax for a "
                "same-repo issue; GitHub does not auto-close in this form "
                "(fleet-ops#695)"
            ),
            "bad_references": bad,
        }
    if missing_closes:
        return {
            "verdict": "REJECT",
            "rule": LEDGER_LINE,
            "reason": (
                "PR body claims to close same-repo issues but "
                "closingIssuesReferences is empty / missing for them; the "
                "auto-close did not fire (fleet-ops#695)"
            ),
            "missing_closes": missing_closes,
        }
    return {
        "verdict": "PASS",
        "reason": (
            "no same-repo `Closes <repo>#N` and no missing-closes "
            "footprint (fleet-ops#695)"
        ),
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
            "Same-repo `Closes <repo>#N` rejection gate (fleet-ops#695). "
            "Pure evaluator."
        )
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="evaluate",
        choices=["evaluate"],
        help="evaluate a PR (default)",
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
