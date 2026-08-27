#!/usr/bin/env python3
# Host is the literal api.cloudflare.com; target is only GET
# /user/tokens/verify. Semgrep sees the Request object and flags dynamic
# urllib; audit-confirmed safe (same suppression as
# lib/credential-expiry-canary.py).
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
"""Canary for the sanctioned VPS Cloudflare token file (fleet-ops#1166).

The vacation-audit-20260827 finding 10 showed ~/.config/cloudflare/deploy.env
had gone 401 dead while VPS scripts (siterep-deploy, siterep-deploy-rollback)
kept sourcing it. Those callers were retargeted to deploy-ci.env after proving
its tokens/verify returns 200/active AND a non-mutating 0509 D1 list succeeds.

This canary is the detector for the blind spot: a dead sanctioned CF file must
fail loud, never degrade silently. It sources the sanctioned file, mints no
token, and GETs the official Cloudflare tokens/verify endpoint
(developers.cloudflare.com/api/resources/user/subresources/tokens/).
A 200 with result.status == "active" is PASS. Anything else (401, inactive,
missing file, unparseable) is REJECT. Network unreachable is SKIP (exit 0),
matching the credential-expiry-canary convention — a network blip is not a
credential failure.

The token value is NEVER printed, logged, or returned. Only HTTP status and
the result.status string ("active"/"expired"/...) are reported.

Usage:
  cf-token-canary
  cf-token-canary --cf-file <path>
  cf-token-canary --cf-status 200 --cf-active active   (offline)
  cf-token-canary --cf-status 401                       (offline)
  cf-token-canary --ledger-line
"""
from __future__ import annotations

import argparse
import os
import ssl
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO = "Nishfleet/fleet-ops"
DEFAULT_CF_FILE = os.path.expanduser("~/.config/cloudflare/deploy-ci.env")
TOKEN_VAR = "CLOUDFLARE_API_TOKEN"
LEDGER = (
    "2026-08-27 | Sanctioned VPS Cloudflare token liveness | The VPS CF "
    "token file used by siterep-deploy/rollback must keep tokens/verify "
    "200/active via fleet-cf-token-canary (fleet-ops#1166); a dead file "
    "fails loud, never degrades silently."
)


def _verify_online(token: str) -> tuple[int, dict[str, Any] | str]:
    """GET https://api.cloudflare.com/client/v4/user/tokens/verify.

    Returns (status, parsed_body). Host and path are literals so urllib
    cannot be pointed at file:// (sgscan dynamic-urllib-use-detected).
    """
    url = "https://api.cloudflare.com/client/v4/user/tokens/verify"
    req = Request(
        url,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "User-Agent": "fleet-ops-cf-token-canary",
        },
    )
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        with urlopen(req, timeout=20, context=ssl.create_default_context()) as resp:
            status = resp.status
            body = resp.read().decode("utf-8", "replace")
    except HTTPError as exc:
        status = exc.code
        body = exc.read().decode("utf-8", "replace") if exc.fp else ""
    try:
        parsed: dict[str, Any] | str = _loads(body)
    except (ValueError, TypeError):
        parsed = body
    return status, parsed


def _loads(body: str) -> dict[str, Any] | str:
    import json

    return json.loads(body) if body else {}


def _token_from_file(path: str) -> str:
    """Source a CF env file and return CLOUDFLARE_API_TOKEN. Never prints it."""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith(TOKEN_VAR + "="):
                val = line.split("=", 1)[1].strip()
                # strip surrounding quotes
                if (val.startswith('"') and val.endswith('"')) or (
                    val.startswith("'") and val.endswith("'")
                ):
                    val = val[1:-1]
                return val
    return ""


def evaluate(
    cf_status: int,
    cf_active: str | None,
    file_present: bool,
    had_token: bool,
) -> dict[str, Any]:
    """Decide PASS/REJECT/SKIP from the tokens/verify response.

    cf_status: HTTP status from GET tokens/verify (0 = not attempted).
    cf_active: result.status string ("active"/"expired"/...), or None.
    file_present: whether the sanctioned CF file existed.
    had_token: whether the file yielded a non-empty CLOUDFLARE_API_TOKEN.
    """
    if not file_present:
        return {
            "verdict": "REJECT",
            "reason": "sanctioned VPS CF token file is missing — callers cannot source it",
        }
    if not had_token:
        return {
            "verdict": "REJECT",
            "reason": (
                "sanctioned VPS CF token file present but has no "
                "CLOUDFLARE_API_TOKEN — callers will 401"
            ),
        }
    if cf_status == 0:
        return {
            "verdict": "SKIP",
            "reason": "tokens/verify not reached (network unreachable)",
        }
    if cf_status != 200:
        hint = "401 = dead/revoked" if cf_status == 401 else "non-200"
        return {
            "verdict": "REJECT",
            "reason": (
                "tokens/verify returned HTTP %s — sanctioned VPS CF token is "
                "not accepted (%s)" % (cf_status, hint)
            ),
            "cf_status": cf_status,
        }
    # 200 — must also be active
    if cf_active is None:
        return {
            "verdict": "REJECT",
            "reason": "tokens/verify 200 but result.status missing/unparseable",
            "cf_status": cf_status,
        }
    if cf_active != "active":
        return {
            "verdict": "REJECT",
            "reason": (
                "tokens/verify 200 but result.status=%s (not active)"
                % cf_active
            ),
            "cf_status": cf_status,
            "cf_active": cf_active,
        }
    return {
        "verdict": "PASS",
        "reason": "tokens/verify 200, result.status=active",
        "cf_status": cf_status,
        "cf_active": cf_active,
    }


def _online(cf_file: str) -> tuple[int, str | None, bool, bool]:
    file_present = os.path.isfile(cf_file)
    if not file_present:
        return 0, None, False, False
    token = _token_from_file(cf_file)
    if not token:
        return 0, None, True, False
    try:
        status, parsed = _verify_online(token)
    except URLError:
        return 0, None, True, True
    active: str | None = None
    if isinstance(parsed, dict):
        result = parsed.get("result")
        if isinstance(result, dict):
            active = result.get("status")
    return status, active, True, True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sanctioned VPS Cloudflare token liveness canary (fleet-ops#1166).",
    )
    parser.add_argument(
        "--cf-file",
        default=None,
        help="CF env file to source (default $CF_TOKEN_CANARY_FILE or ~/.config/cloudflare/deploy-ci.env).",
    )
    parser.add_argument(
        "--cf-status",
        type=int,
        default=None,
        help="Inline HTTP status from tokens/verify (offline).",
    )
    parser.add_argument(
        "--cf-active",
        default=None,
        help="Inline result.status string (offline, pairs with --cf-status).",
    )
    parser.add_argument(
        "--file-present",
        dest="file_present",
        action="store_true",
        default=None,
        help="Inline assertion that the CF file exists (offline).",
    )
    parser.add_argument(
        "--no-file",
        dest="file_present",
        action="store_false",
        help="Inline assertion that the CF file is missing (offline).",
    )
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--ledger-line", action="store_true")
    args = parser.parse_args()

    if args.ledger_line:
        print(LEDGER)
        return 0

    cf_file = args.cf_file or os.environ.get(
        "CF_TOKEN_CANARY_FILE", DEFAULT_CF_FILE
    )

    # Offline mode is triggered by any inline assertion: --cf-status,
    # --file-present, or --no-file. Without any of these we go online.
    offline = (
        args.cf_status is not None or args.file_present is not None
    )
    if offline:
        file_present = args.file_present if args.file_present is not None else True
        had_token = True  # offline callers assert file shape via fixtures
        status, active, fp = args.cf_status, args.cf_active, file_present
    else:
        status, active, fp, had_token = _online(cf_file)

    result = evaluate(
        cf_status=status, cf_active=active, file_present=fp, had_token=had_token
    )
    verdict = result["verdict"]
    reason = result["reason"]
    if verdict == "PASS":
        print("cf-token-canary: PASS — %s" % reason, file=sys.stderr)
        return 0
    if verdict == "SKIP":
        print("cf-token-canary: SKIP — %s" % reason, file=sys.stderr)
        return 0
    print("cf-token-canary: REJECT — %s" % reason, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
