#!/usr/bin/env python3
# Host is the literal api.github.com; path is /user or /repos/<regex-validated
# owner/repo>. Semgrep sees the Request object and flags dynamic urllib;
# audit-confirmed safe (same suppression as bin/_worker-app-bootstrap-server.py).
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
"""FLEET_SYNC_PAT probe (fleet-ops#482).

The repo-standards-sync workflow used to only check the secret was non-empty.
A token that was set but missing the `workflow` scope (so PRs touching
.github/workflows/** get "Resource not accessible by personal access token")
or missing push access to Nishfleet org repos (so `git push` is denied) looked
"set" and sailed past the check, failing later inside BetaHuhn with a vague
error. This probe fails LOUD, in one sentence, before BetaHuhn runs.

What it certifies:
  1. The token is present and alive (GET /user -> 200, or 403 for App tokens
     which is not dead).
  2. Classic PAT: X-OAuth-Scopes includes `repo` AND `workflow`.
  3. GET /repos/Nishfleet/fleet-ops reports permissions.push == true (the
     org-push gate; catches "Permission to Nishfleet/<repo>.git denied").

Fine-grained/App tokens carry no X-OAuth-Scopes; workflows:write is not
enumerable via a read-only API (the /repos endpoint only exposes
metadata:read in X-Accepted-Github-Permissions), so push access is the
mechanically certifiable signal for those token types, with a note that
the owner must grant Contents+Workflows+Pull-requests write.

Pure evaluator + a thin online fetcher. No GitHub writes, no dispatch.

Usage:
  verify-fleet-sync-pat                       # online: reads $FLEET_SYNC_PAT
  verify-fleet-sync-pat --token <tok>         # online with explicit token
  verify-fleet-sync-pat --from-fixtures <dir> # offline: replay recorded
                                              # HTTP responses (tests)
  verify-fleet-sync-pat --ledger-line         # print the standing-rule line

Offline fixture dir layout (all four files required for a live-token fixture):
  <dir>/user.headers   raw HTTP response headers from GET /user
  <dir>/user.body      JSON body from GET /user
  <dir>/repo.headers   raw HTTP response headers from GET /repos/<owner>/<repo>
  <dir>/repo.body      JSON body from GET /repos/<owner>/<repo>
For the empty-token case, pass --token "" (no fixtures read). For a dead
token, the user fixture carries a 401 status line.

Output: one JSON object on stdout: {"verdict":"PASS"|"REJECT","reason":"..."}
Exit: 0 on PASS, 1 on REJECT, 2 on usage/IO error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO = "Nishfleet/fleet-ops"
# owner/repo — reject anything that could escape the API host (scheme, host,
# query, fragment, path traversal). Host is the literal api.github.com;
# this regex only bounds the path suffix.
_REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
LEDGER = (
    "fleet-ops #482: FLEET_SYNC_PAT probe — a dead/under-scoped PAT cannot "
    "look set; missing workflow scope or org push fails loud before BetaHuhn."
)


def _header_lookup(raw_headers: str) -> dict[str, str]:
    """Parse 'curl -D'-style header block into a lowercased name->value map.

    Handles folded headers and duplicate names by joining with ', '.
    """
    out: dict[str, list[str]] = {}
    for line in raw_headers.splitlines():
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
            # folded continuation of the previous header
            if out:
                last = next(reversed(out))
                out[last][-1] = out[last][-1] + " " + line.strip()
            continue
        if ":" not in line:
            continue
        name, _, value = line.partition(":")
        out.setdefault(name.strip().lower(), []).append(value.strip())
    return {k: ", ".join(v) for k, v in out.items()}


def _status_from_headers(raw_headers: str) -> int:
    for line in raw_headers.splitlines():
        line = line.strip()
        if not line:
            continue
        # 'HTTP/2 200' or 'HTTP/1.1 200 OK'
        parts = line.split()
        if parts and parts[0].upper().startswith("HTTP/"):
            for p in parts[1:]:
                if p.isdigit():
                    return int(p)
    return 0


def _scopes_to_set(scopes_header: str) -> set[str]:
    return {s.strip() for s in scopes_header.split(",") if s.strip()}


def _accepted_perms_to_set(perms_header: str) -> set[str]:
    """Parse 'contents:write, metadata:read' into {'contents:write', ...}."""
    return {p.strip().lower() for p in perms_header.split(",") if p.strip()}


def fetch_online(token: str, repo: str = REPO) -> dict[str, Any]:
    """Make the two read-only API calls and reduce them to the eval state."""
    state: dict[str, Any] = {
        "token_present": bool(token),
        "user_status": 0,
        "oauth_scopes": "",
        "user_accepted_perms": "",
        "repo_status": 0,
        "repo_push": None,
        "repo_accepted_perms": "",
    }
    if not token:
        return state

    def _get(path: str) -> tuple[int, dict[str, str], str]:
        # Two-step concat, host literal. Path is "/user" or "/repos/" + a
        # regex-validated owner/repo. Same shape as
        # bin/_worker-app-bootstrap-server.py (CI-proven nosemgrep).
        url = "https://api.github.com" + path
        req = Request(url, headers={
            "Authorization": "token " + token,
            "Accept": "application/vnd.github+json",
            "User-Agent": "fleet-ops-verify-fleet-sync-pat",
        })
        kwargs = {"timeout": 20, "context": ssl.create_default_context()}
        try:
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            with urlopen(req, **kwargs) as resp:
                status = resp.status
                headers = {k.lower(): v for k, v in resp.headers.items()}
                body = resp.read().decode("utf-8", "replace")
        except HTTPError as exc:
            status = exc.code
            headers = {k.lower(): v for k, v in (exc.headers or {}).items()}
            body = exc.read().decode("utf-8", "replace") if exc.fp else ""
        return status, headers, body

    u_status, u_headers, _u_body = _get("/user")
    state["user_status"] = u_status
    state["oauth_scopes"] = u_headers.get("x-oauth-scopes", "")
    state["user_accepted_perms"] = u_headers.get(
        "x-accepted-github-permissions", ""
    )

    if not _REPO_RE.match(repo):
        state["repo_push"] = None
        return state

    r_status, r_headers, r_body = _get("/repos/" + repo)
    state["repo_status"] = r_status
    state["repo_accepted_perms"] = r_headers.get(
        "x-accepted-github-permissions", ""
    )
    try:
        rjson = json.loads(r_body) if r_body else {}
        perms = rjson.get("permissions")
        if isinstance(perms, dict):
            state["repo_push"] = bool(perms.get("push"))
    except json.JSONDecodeError:
        state["repo_push"] = None
    return state


def fetch_offline(fixtures_dir: str) -> dict[str, Any]:
    """Replay recorded HTTP responses from a fixture directory."""
    state: dict[str, Any] = {
        "token_present": True,
        "user_status": 0,
        "oauth_scopes": "",
        "user_accepted_perms": "",
        "repo_status": 0,
        "repo_push": None,
        "repo_accepted_perms": "",
    }
    base = os.path.abspath(fixtures_dir)

    def _read(name: str) -> str:
        with open(os.path.join(base, name), encoding="utf-8") as fh:
            return fh.read()

    u_headers = _read("user.headers")
    state["user_status"] = _status_from_headers(u_headers)
    h = _header_lookup(u_headers)
    state["oauth_scopes"] = h.get("x-oauth-scopes", "")
    state["user_accepted_perms"] = h.get(
        "x-accepted-github-permissions", ""
    )

    r_headers = _read("repo.headers")
    state["repo_status"] = _status_from_headers(r_headers)
    rh = _header_lookup(r_headers)
    state["repo_accepted_perms"] = rh.get(
        "x-accepted-github-permissions", ""
    )
    try:
        rjson = json.loads(_read("repo.body"))
        perms = rjson.get("permissions")
        if isinstance(perms, dict):
            state["repo_push"] = bool(perms.get("push"))
    except json.JSONDecodeError:
        state["repo_push"] = None
    return state


def _no_push_reason(prefix: str) -> dict[str, str]:
    return {
        "verdict": "REJECT",
        "reason": (
            f"{prefix} cannot push to Nishfleet/fleet-ops "
            "(permissions.push=false) — org push will be denied with "
            "'Permission to Nishfleet/<repo>.git denied'. Grant the token "
            "push access to Nishfleet repos and re-run (fleet-ops#482)."
        ),
    }


def evaluate(state: dict[str, Any]) -> dict[str, str]:
    """Pure: state -> {verdict, reason}. No I/O."""
    if not state.get("token_present"):
        return {
            "verdict": "REJECT",
            "reason": (
                "FLEET_SYNC_PAT is not set. Create a classic PAT with repo+"
                "workflow scopes (contents+workflows+pull-requests write) "
                "across Nishfleet and nish3451, add it as the FLEET_SYNC_PAT "
                "secret on Nishfleet/fleet-ops, then re-run."
            ),
        }

    user_status = int(state.get("user_status") or 0)
    # 401 = dead/revoked token (both classic and fine-grained). A dead token
    # fails /user AND /repos with 401; reporting it as dead is the true root
    # cause, not "cannot push".
    if user_status == 401:
        return {
            "verdict": "REJECT",
            "reason": (
                "FLEET_SYNC_PAT is dead or revoked: GET /user returned 401. "
                "Rotate the token (fleet-ops#482)."
            ),
        }

    scopes = _scopes_to_set(state.get("oauth_scopes", ""))
    is_classic = bool(scopes)

    if is_classic:
        if "repo" not in scopes:
            return {
                "verdict": "REJECT",
                "reason": (
                    "FLEET_SYNC_PAT is a classic PAT missing the `repo` "
                    "scope — add the repo scope (covers pull-requests "
                    "write) and re-run (fleet-ops#482)."
                ),
            }
        if "workflow" not in scopes:
            return {
                "verdict": "REJECT",
                "reason": (
                    "FLEET_SYNC_PAT is a classic PAT missing the `workflow` "
                    "scope — PRs touching .github/workflows/** will be "
                    "rejected with 'Resource not accessible by personal "
                    "access token'. Add the workflow scope and re-run "
                    "(fleet-ops#482)."
                ),
            }
        if int(state.get("repo_status") or 0) != 200 or not state.get(
            "repo_push"
        ):
            return _no_push_reason("FLEET_SYNC_PAT has repo+workflow scopes but")
        return {
            "verdict": "PASS",
            "reason": (
                "FLEET_SYNC_PAT is a classic PAT with repo+workflow scopes "
                "and push access to Nishfleet/fleet-ops."
            ),
        }

    # Fine-grained PAT or GitHub App installation token: no X-OAuth-Scopes.
    # /user may be 403 (App token, or fine-grained PAT with no account
    # permissions) — that is NOT dead; fall through to the repo-push check,
    # which is the mechanically certifiable signal for these token types.
    # workflows:write is NOT enumerable via a read-only API (the /repos
    # endpoint only exposes metadata:read in X-Accepted-Github-Permissions),
    # so push access is the best available certifiable signal; the token
    # owner must grant Contents+Workflows+Pull-requests write (fleet-ops#482).
    if int(state.get("repo_status") or 0) != 200 or not state.get("repo_push"):
        return _no_push_reason("FLEET_SYNC_PAT (fine-grained/App)")
    return {
        "verdict": "PASS",
        "reason": (
            "FLEET_SYNC_PAT (fine-grained/App) has push access to "
            "Nishfleet/fleet-ops. Note: workflows:write is not separately "
            "certifiable via a read-only API — the token owner must grant "
            "Contents+Workflows+Pull-requests write (fleet-ops#482)."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="FLEET_SYNC_PAT probe (fleet-ops#482).",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Token to probe (default: $FLEET_SYNC_PAT env). "
        "Pass an empty string to exercise the empty-token REJECT.",
    )
    parser.add_argument(
        "--from-fixtures",
        metavar="DIR",
        default=None,
        help="Offline mode: replay recorded HTTP responses from DIR.",
    )
    parser.add_argument(
        "--repo",
        default=REPO,
        help=f"Target repo for the push-permission check (default: {REPO}).",
    )
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="Print the standing-rule ledger line and exit.",
    )
    args = parser.parse_args()

    if args.ledger_line:
        print(LEDGER)
        return 0

    if args.from_fixtures:
        state = fetch_offline(args.from_fixtures)
    else:
        token = args.token if args.token is not None else os.environ.get(
            "FLEET_SYNC_PAT", ""
        )
        if not _REPO_RE.match(args.repo):
            print(json.dumps({
                "verdict": "REJECT",
                "reason": (
                    f"invalid --repo {args.repo!r}: must be owner/repo "
                    f"(alphanumerics, ., _, -)."
                ),
            }))
            return 1
        state = fetch_online(token, repo=args.repo)
        state["token_present"] = bool(token)

    result = evaluate(state)
    print(json.dumps(result))
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, URLError) as exc:
        print(json.dumps({
            "verdict": "REJECT",
            "reason": f"FLEET_SYNC_PAT probe could not reach the GitHub API: {exc}",
        }))
        sys.exit(1)
