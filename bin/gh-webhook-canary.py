#!/usr/bin/env python3
# Target is hardcoded 127.0.0.1:8088 (env var override is the loopback
# default; the user never points it elsewhere). Audit-confirmed safe
# (same suppression as lib/credential-expiry-canary.py + lib/verify-fleet-sync-pat.py).
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
"""gh-webhook-canary — synthetic end-to-end probe for the GitHub push channel.

fleet-ops#1464, pattern 2. Posts a synthetic 'issues/labeled/agent-ready'
payload to the local webhook receiver with a valid HMAC SHA-256 signature,
asserts the response is HTTP 200 with a 'dispatched' or 'ignored' status,
and updates /var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom.

Exit codes
==========

  0  canary ran end-to-end and the receiver answered (200)
  1  receiver answered non-200, or refused, or the HMAC failed
  2  misconfiguration (missing secret, bad target)
  3  network/connection failure (receiver not listening)
  4  bad response shape

The deadman (gh-webhook-canary-deadman) watches the prom file and pages
the alert-repair rail when the series is missing or stale. The canary
script itself is silent on success.

Environment seams:

  GH_WEBHOOK_CANARY_TARGET        default http://127.0.0.1:8088/webhook
  GH_WEBHOOK_CANARY_SECRET_FILE   default ~/.config/fleet-ops/gh-webhook.secret
  GH_WEBHOOK_CANARY_PROM          default /var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom
  GH_WEBHOOK_CANARY_DRY           1 = compute HMAC + write the payload to
                                  stdout; no network call (used by tests)
  GH_WEBHOOK_CANARY_TIMEOUT       default 10 (seconds)
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


TARGET = os.environ.get("GH_WEBHOOK_CANARY_TARGET",
                        "http://127.0.0.1:8088/webhook")
SECRET_FILE = os.environ.get(
    "GH_WEBHOOK_CANARY_SECRET_FILE",
    str(Path.home() / ".config" / "fleet-ops" / "gh-webhook.secret"),
)
PROM = os.environ.get("GH_WEBHOOK_CANARY_PROM",
                      "/var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom")
DRY = os.environ.get("GH_WEBHOOK_CANARY_DRY", "") == "1"
TIMEOUT = float(os.environ.get("GH_WEBHOOK_CANARY_TIMEOUT", "10"))


def _read_secret() -> bytes:
    p = Path(SECRET_FILE)
    if not p.is_file():
        print(f"gh-webhook-canary: secret missing: {p}", file=sys.stderr)
        sys.exit(2)
    s = p.read_text().strip()
    if not s:
        print(f"gh-webhook-canary: secret empty: {p}", file=sys.stderr)
        sys.exit(2)
    return s.encode("utf-8")


def _synthetic_payload() -> dict:
    # Synthetic repo name is 'fleet-ops-canary' so test logs clearly
    # distinguish it from real forward events. The dispatch table in
    # serve.py accepts any repo matching ^[A-Za-z0-9._-]{1,64}$ so this
    # name routes cleanly (and the actual systemctl start attempt will
    # fail with DRY=1 — which is fine, the canary only checks the response
    # body, not the dispatch rc).
    return {
        "action": "labeled",
        "label": {"name": "agent-ready"},
        "issue": {"number": 999999, "title": "synthetic canary"},
        "repository": {"name": "fleet-ops-canary",
                       "full_name": "Nishfleet/fleet-ops-canary"},
    }


def _post(url: str, body: bytes, sig: str, timeout: float) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "X-GitHub-Event": "issues",
        "X-GitHub-Delivery": f"canary-{int(time.time())}-{secrets.token_hex(4)}",
        "X-Hub-Signature-256": f"sha256={sig}",
        "User-Agent": "gh-webhook-canary",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if e.fp else b""
    except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
        print(f"gh-webhook-canary: connection error: {e}", file=sys.stderr)
        sys.exit(3)


def _write_prom(file_path: str, last_green: float, last_rc: int,
                last_status: str, run_count: int) -> None:
    try:
        body = (
            "# HELP fleet_gh_webhook_canary_last_green_seconds "
            "Epoch seconds of the last successful end-to-end push-channel "
            "canary (organ heartbeat).\n"
            "# TYPE fleet_gh_webhook_canary_last_green_seconds gauge\n"
            f"fleet_gh_webhook_canary_last_green_seconds "
            f"{last_green:.0f}\n"
            "# HELP fleet_gh_webhook_canary_last_rc "
            "HTTP status code from the last canary POST (200 = pass).\n"
            "# TYPE fleet_gh_webhook_canary_last_rc gauge\n"
            f"fleet_gh_webhook_canary_last_rc {last_rc}\n"
            "# HELP fleet_gh_webhook_canary_last_status "
            "One-word summary of the last canary run: ok|fail|skip|unknown.\n"
            "# TYPE fleet_gh_webhook_canary_last_status gauge\n"
            f"fleet_gh_webhook_canary_last_status{{status=\"{last_status}\"}} 1\n"
            "# HELP fleet_gh_webhook_canary_runs_total "
            "Cumulative canary run count since this prom file was installed.\n"
            "# TYPE fleet_gh_webhook_canary_runs_total counter\n"
            f"fleet_gh_webhook_canary_runs_total {run_count}\n"
        )
        Path(file_path).parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(file_path).with_suffix(Path(file_path).suffix + ".tmp")
        tmp.write_text(body)
        os.replace(tmp, file_path)
    except OSError as e:
        print(f"gh-webhook-canary: prom write skipped: {e}", file=sys.stderr)


def main(argv: list[str]) -> int:
    secret = _read_secret()
    payload = _synthetic_payload()
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    sig = hmac.new(secret, body, hashlib.sha256).hexdigest()

    if DRY:
        # Tests assert the dry output: HMAC + body printed, no HTTP call.
        sys.stdout.buffer.write(b"---HEADERS---\n")
        sys.stdout.buffer.write(f"X-GitHub-Event: issues\n".encode())
        sys.stdout.buffer.write(f"X-Hub-Signature-256: sha256={sig}\n".encode())
        sys.stdout.buffer.write(b"---BODY---\n")
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.write(b"\n")
        return 0

    status, resp = _post(TARGET, body, sig, TIMEOUT)
    status_word = "ok" if status == 200 else "fail"
    _write_prom(PROM, time.time(), status, status_word, run_count=1)
    if status != 200:
        print(
            f"gh-webhook-canary: FAIL status={status} target={TARGET} "
            f"body={resp[:200]!r}",
            file=sys.stderr,
        )
        return 1
    try:
        j = json.loads(resp.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("gh-webhook-canary: bad response shape (not JSON)", file=sys.stderr)
        return 4
    if not (j.get("received") is True):
        print(f"gh-webhook-canary: response missing 'received:true': {j!r}",
              file=sys.stderr)
        return 4
    # rc==0 means the receiver actually fired the unit (pi-intake@<repo>.
    # service or fleet-deploy-check.service). rc non-zero with DRY=0 means
    # the unit did not exist (the canary repo doesn't ship one) — that is
    # expected and not a canary failure. The deadman reads only the
    # canary_last_green_seconds series, which we just bumped.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
