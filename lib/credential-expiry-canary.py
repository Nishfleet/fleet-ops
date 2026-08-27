#!/usr/bin/env python3
"""Canary for credential/token expiry through the vacation window end.

fleet-ops#938 (led-2026-08-27-vacation-window-corrected).

Nish departs 2026-08-28, returns 2026-09-08. The ledger line requires that
credential/token/quota expiry checks cover through 2026-09-08 inclusive.

What this canary checks (official docs, not folklore):

  1. GitHub App private keys do not expire. GitHub docs
     (managing-private-keys-for-github-apps): "Private keys do not expire
     and instead need to be manually revoked." There is no GET /app/keys
     endpoint. Coverage through the window is: GET /app with a minted App
     JWT returns 200 (the key is currently accepted). A 401/403 is REJECT
     (dead App). worker-app-canary (fleet-ops#413) covers installation-
     token mint liveness separately; those tokens last <=1h and are
     reminted, so they are not horizon-checked here.

  2. FLEET_SYNC_PAT, when present: the GitHub-Authentication-Token-Expiration
     header on GET /user (GitHub changelog 2021-07-26) must be after
     2026-09-08T23:59:59Z. A missing header means a classic PAT with no
     expiry (PASS). An expiry on or before the window end is REJECT.
     Installation tokens (GH_TOKEN) are never probed — they always expire
     inside an hour.

  3. healthchecks.io URLs are UUIDs with no expiry. Prepaid weekly quotas
     reset; entitled-wired-canary covers seat wiring.

Fail-loud: dead App, or a PAT that expires on or before 2026-09-08.
SKIP (exit 0): network unreachable, or no checkable credential is present.

Usage:
  credential-expiry-canary
  credential-expiry-canary --from-fixtures <dir>
  credential-expiry-canary --app-returns <json> [--app-status N]
  credential-expiry-canary --pat-headers <raw-headers>
  credential-expiry-canary --now 2026-09-01T00:00:00Z
  credential-expiry-canary --ledger-line
"""
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
from datetime import datetime, timezone
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

VACATION_WINDOW_END = datetime(2026, 9, 8, 23, 59, 59, tzinfo=timezone.utc)
REPO = "Nishfleet/fleet-ops"
LEDGER = (
    "2026-08-27 | Vacation window corrected | Credential/token/quota expiry "
    "checks cover through 2026-09-08 inclusive via fleet-credential-expiry-canary "
    "(GET /app App-JWT liveness; GitHub App keys do not expire per official docs; "
    "FLEET_SYNC_PAT GitHub-Authentication-Token-Expiration horizon; "
    "worker-app-canary mint liveness; verify-fleet-sync-pat PAT liveness)."
)


def _pem_from_env(creds_path: str) -> tuple[str, str]:
    with open(creds_path, encoding="utf-8") as fh:
        content = fh.read()
    app_id = None
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("NISHFLEET_WORKER_APP_ID="):
            app_id = line.split("=", 1)[1].strip().strip('"').strip("'")
    pem_match = re.search(
        r"(-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----)",
        content,
        re.DOTALL,
    )
    pem = pem_match.group(0) if pem_match else ""
    if not app_id:
        raise ValueError("NISHFLEET_WORKER_APP_ID not found in creds file")
    if not pem:
        raise ValueError("NISHFLEET_WORKER_PRIVATE_KEY PEM block not found")
    return app_id, pem


def _b64url_no_pad(data: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _mint_jwt(app_id: str, pem: str) -> str:
    """Mint a GitHub App JWT (RS256). Same iat/exp window as bin/worker-token."""
    import subprocess
    import tempfile

    now = int(datetime.now(timezone.utc).timestamp())
    exp = now + 540
    header = json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":"))
    payload = json.dumps(
        {"iat": now, "exp": exp, "iss": int(app_id)},
        separators=(",", ":"),
    )
    unsigned = _b64url_no_pad(header.encode()) + "." + _b64url_no_pad(payload.encode())

    fd, path = tempfile.mkstemp(suffix=".pem", prefix="credential-canary-")
    try:
        os.write(fd, pem.encode())
        os.close(fd)
        os.chmod(path, 0o600)
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", path],
            input=unsigned.encode(),
            capture_output=True,
            timeout=10,
        )
        if result.returncode != 0:
            raise RuntimeError("openssl sign failed")
        sig = _b64url_no_pad(result.stdout)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return unsigned + "." + sig


def _header_lookup(raw_headers: str) -> dict[str, str]:
    out: dict[str, list[str]] = {}
    for line in raw_headers.splitlines():
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
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
        parts = line.split()
        if parts and parts[0].upper().startswith("HTTP/"):
            for p in parts[1:]:
                if p.isdigit():
                    return int(p)
    return 0


def _api_get(
    auth: str, path: str
) -> tuple[int, dict[str, Any] | list[Any] | str, str]:
    """GET api.github.com<path>. Returns (status, parsed_body, raw_headers)."""
    url = "https://api.github.com" + path
    req = Request(
        url,
        headers={
            "Authorization": "Bearer " + auth,
            "Accept": "application/vnd.github+json",
            "User-Agent": "fleet-ops-credential-expiry-canary",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    raw_headers = ""
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
        with urlopen(req, timeout=20, context=ssl.create_default_context()) as resp:
            status = resp.status
            body = resp.read().decode("utf-8", "replace")
            raw_headers = "HTTP/1.1 %s\n%s" % (
                status,
                "".join("%s: %s\n" % (k, v) for k, v in resp.headers.items()),
            )
    except HTTPError as exc:
        status = exc.code
        body = exc.read().decode("utf-8", "replace") if exc.fp else ""
        raw_headers = "HTTP/1.1 %s\n" % status
    try:
        parsed: dict[str, Any] | list[Any] | str = json.loads(body) if body else {}
    except json.JSONDecodeError:
        parsed = body
    return status, parsed, raw_headers


def _parse_github_expiry(raw: str) -> datetime | None:
    """Parse GitHub-Authentication-Token-Expiration (changelog 2021-07-26)."""
    raw = raw.strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        try:
            return datetime.fromisoformat(raw[:-1] + "+00:00")
        except (ValueError, TypeError):
            return None
    formats = (
        "%Y-%m-%d %H:%M:%S %z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%d",
    )
    for fmt in formats:
        try:
            dt = datetime.strptime(raw, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    try:
        dt = datetime.fromisoformat(raw)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def evaluate(
    app_status: int,
    pat_expiry_raw: str | None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Check App liveness + PAT horizon against the vacation window end.

    app_status: HTTP status from GET /app (0 = not attempted / unreachable).
    pat_expiry_raw: GitHub-Authentication-Token-Expiration value, or None
      if the PAT was not probed / the header was absent.
    """
    if now is None:
        now = datetime.now(timezone.utc)
    window_end = VACATION_WINDOW_END
    if now >= window_end:
        return {
            "verdict": "SKIP",
            "reason": (
                "current time %s is past the vacation window end %s — "
                "expiry coverage check moot"
                % (now.isoformat(), window_end.isoformat())
            ),
            "window_end": window_end.isoformat(),
        }

    findings: list[str] = []

    if app_status in (401, 403):
        return {
            "verdict": "REJECT",
            "reason": (
                "GET /app returned %s — GitHub App private key is not "
                "accepted; fleet cannot mint through 2026-09-08"
                % app_status
            ),
            "app_status": app_status,
            "window_end": window_end.isoformat(),
        }

    if app_status == 200:
        findings.append(
            "GET /app 200 (GitHub App keys do not expire; official docs "
            "managing-private-keys-for-github-apps)"
        )
    elif app_status not in (0,):
        return {
            "verdict": "REJECT",
            "reason": "GET /app returned unexpected status %s" % app_status,
            "app_status": app_status,
            "window_end": window_end.isoformat(),
        }

    if pat_expiry_raw:
        expiry = _parse_github_expiry(pat_expiry_raw)
        if expiry is None:
            return {
                "verdict": "REJECT",
                "reason": (
                    "FLEET_SYNC_PAT GitHub-Authentication-Token-Expiration "
                    "header is not parseable"
                ),
                "window_end": window_end.isoformat(),
            }
        if expiry <= window_end:
            return {
                "verdict": "REJECT",
                "reason": (
                    "FLEET_SYNC_PAT expires at %s, on or before vacation "
                    "window end %s"
                    % (expiry.isoformat(), window_end.isoformat())
                ),
                "pat_expires_at": expiry.isoformat(),
                "window_end": window_end.isoformat(),
            }
        findings.append(
            "FLEET_SYNC_PAT expires at %s (after window end)" % expiry.isoformat()
        )
    elif pat_expiry_raw == "":
        findings.append(
            "FLEET_SYNC_PAT has no GitHub-Authentication-Token-Expiration "
            "header (classic PAT, no expiry)"
        )

    if not findings:
        return {
            "verdict": "SKIP",
            "reason": (
                "Cannot verify credential expiry: GET /app not reached "
                "(status=%s) and no PAT expiry header"
                % app_status
            ),
            "app_status": app_status,
            "window_end": window_end.isoformat(),
        }

    return {
        "verdict": "PASS",
        "reason": (
            "Expiry coverage holds through %s: %s"
            % (window_end.isoformat(), "; ".join(findings))
        ),
        "app_status": app_status,
        "window_end": window_end.isoformat(),
    }


def _parse_now(s: str | None) -> datetime | None:
    if not s:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def _load_fixture(fixtures_dir: str) -> tuple[int, str | None]:
    app_status = 0
    app_headers_path = os.path.join(fixtures_dir, "app.headers")
    if os.path.isfile(app_headers_path):
        with open(app_headers_path, encoding="utf-8") as fh:
            app_status = _status_from_headers(fh.read())
    app_body_path = os.path.join(fixtures_dir, "app.body")
    if app_status == 0 and os.path.isfile(app_body_path):
        app_status = 200

    pat_raw: str | None = None
    user_headers_path = os.path.join(fixtures_dir, "user.headers")
    if os.path.isfile(user_headers_path):
        with open(user_headers_path, encoding="utf-8") as fh:
            headers = _header_lookup(fh.read())
        if "github-authentication-token-expiration" in headers:
            pat_raw = headers["github-authentication-token-expiration"]
        else:
            pat_raw = ""
    return app_status, pat_raw


def _online(
    creds_path: str | None, pat_token: str | None
) -> tuple[int, str | None]:
    app_status = 0
    if creds_path and os.path.isfile(creds_path):
        try:
            app_id, pem = _pem_from_env(creds_path)
            jwt = _mint_jwt(app_id, pem)
            app_status, _body, _hdrs = _api_get(jwt, "/app")
        except URLError:
            app_status = 0
        except (ValueError, RuntimeError):
            app_status = 401

    pat_raw: str | None = None
    if pat_token:
        try:
            _st, _body, raw_headers = _api_get(pat_token, "/user")
            headers = _header_lookup(raw_headers)
            if "github-authentication-token-expiration" in headers:
                pat_raw = headers["github-authentication-token-expiration"]
            else:
                pat_raw = ""
        except URLError:
            pat_raw = None
    return app_status, pat_raw


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Credential/token expiry canary for fleet-ops#938.",
    )
    parser.add_argument("--from-fixtures", metavar="DIR", default=None)
    parser.add_argument(
        "--app-returns",
        metavar="JSON",
        default=None,
        help="Inline JSON object for GET /app (offline). Implies status 200 unless --app-status.",
    )
    parser.add_argument(
        "--app-status",
        type=int,
        default=None,
        help="HTTP status to pair with --app-returns (default 200).",
    )
    parser.add_argument(
        "--pat-headers",
        metavar="TEXT",
        default=None,
        help="Raw GET /user response headers (offline PAT expiry check).",
    )
    parser.add_argument("--now", default=None)
    parser.add_argument("--creds-file", default=None)
    parser.add_argument("--token", default=None, help="PAT to probe (default $FLEET_SYNC_PAT).")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--ledger-line", action="store_true")
    args = parser.parse_args()

    if args.ledger_line:
        print(LEDGER)
        return 0

    now = _parse_now(args.now) or _parse_now(os.environ.get("FLEET_CRED_EXPIRY_NOW"))

    if args.from_fixtures:
        app_status, pat_raw = _load_fixture(args.from_fixtures)
    elif args.app_returns is not None or args.pat_headers is not None:
        app_status = 0
        pat_raw: str | None = None
        if args.app_returns is not None:
            try:
                parsed = json.loads(args.app_returns) if args.app_returns else {}
            except json.JSONDecodeError as exc:
                print(
                    "credential-expiry-canary: --app-returns is not valid JSON: %s"
                    % exc,
                    file=sys.stderr,
                )
                return 2
            if args.app_returns and not isinstance(parsed, dict):
                print(
                    "credential-expiry-canary: --app-returns must be a JSON object",
                    file=sys.stderr,
                )
                return 2
            app_status = args.app_status if args.app_status is not None else 200
        if args.pat_headers is not None:
            headers = _header_lookup(args.pat_headers)
            if "github-authentication-token-expiration" in headers:
                pat_raw = headers["github-authentication-token-expiration"]
            else:
                pat_raw = ""
    else:
        creds = args.creds_file or os.environ.get(
            "WORKER_APP_CREDS_FILE",
            os.path.expanduser("~/.config/fleet-worker/nishfleet-worker.env"),
        )
        pat_token = args.token if args.token is not None else os.environ.get("FLEET_SYNC_PAT")
        try:
            app_status, pat_raw = _online(creds, pat_token)
        except URLError as exc:
            print(
                "credential-expiry-canary: SKIP — cannot reach GitHub API: %s" % exc,
                file=sys.stderr,
            )
            return 0

    result = evaluate(app_status=app_status, pat_expiry_raw=pat_raw, now=now)
    verdict = result["verdict"]
    reason = result["reason"]
    if verdict == "PASS":
        print("credential-expiry-canary: PASS — %s" % reason, file=sys.stderr)
        return 0
    if verdict == "SKIP":
        print("credential-expiry-canary: SKIP — %s" % reason, file=sys.stderr)
        return 0
    print("credential-expiry-canary: REJECT — %s" % reason, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
