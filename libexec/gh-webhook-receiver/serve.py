#!/usr/bin/env python3
"""gh-webhook-receiver — VPS-side receiver for GitHub webhook forwards.

fleet-ops#1464: closes the latency gap on fleet intake. A Cloudflare Worker
(workers/github-push-forward/) verifies the GitHub HMAC, forwards the body
through a Cloudflare Tunnel to this receiver, then returns 200. This
receiver is the dumb dispatcher: verify HMAC (defence-in-depth — the Worker
already verified, but a tunnel hop is still a hop), decode the event, and
fire the matching systemd user unit. All logic stays on the VPS; the Worker
is dumb transport.

Endpoints
=========

POST /webhook        Primary ingress. Verifies HMAC, dispatches.
GET  /healthz        Liveness probe (no auth, no body).
                     Returns 200 + {"status":"ok"} + the receiver version.

Event → unit dispatch (event from X-GitHub-Event; action/label from body)
==========================================================================

issues, action=labeled, label=agent-ready
        → start pi-intake@<repo>.service
issues, action=labeled, label=pipeline-red
        → start fleet-deploy-check.service
issues, action=opened, label=agent-ready
        → start pi-intake@<repo>.service   (race-safe: the tick will dedupe)
workflow_run, action=completed, conclusion=success
        → start fleet-deploy-check.service
pull_request, action=closed (merged OR closed)
        → start fleet-worktree-reaper.service  (fleet-ops#3269)
ping    → no-op (200)

Anything else → 200 + "ignored: <reason>" (the worker must always see 200;
we never bounce, we log + skip).

Why a python http.server and not Flask/Hono/etc.
================================================

Stdlib only, no install step, no venv. The fleet has a hard "no extra
services" rule; a 90-line stdlib server is the smallest durable thing that
does the job and survives a Cloudflare tunnel reconnect. Tested offline in
tests/gh-webhook-receiver-hmac.test.sh via an in-process threading.Thread.

Hard rules
==========

- HMAC SHA-256 with the shared webhook secret. Constant-time comparison.
- Bound to 127.0.0.1 by default (the tunnel connects to loopback).
- 1 MiB body cap (GitHub webhooks never exceed ~200 KiB; cap stops abuse).
- Logs every event to stderr (journal), one line.
- No secrets in stdout; secret is read once at start.
- Fail-closed: a bad signature returns 401, not 200.
- Bodies are decoded as UTF-8 JSON; a non-JSON body is treated as a generic
  event (no action/label routing), still verified against HMAC.

Environment seams (overridden by tests + fleet-ops deploy):

  GH_WEBHOOK_SECRET_FILE  Path to the shared HMAC secret. Default
                          ~/.config/fleet-ops/gh-webhook.secret
  GH_WEBHOOK_RECEIVER_BIND  Default 127.0.0.1
  GH_WEBHOOK_RECEIVER_PORT  Default 8088
  GH_WEBHOOK_RECEIVER_DRY   1 = dispatch to journal only (no systemctl
                            start); used by tests.
  GH_WEBHOOK_RECEIVER_PROM  Path to write the heartbeat prom file. Default
                            /var/lib/prometheus/node-exporter/fleet-gh-webhook-receiver.prom
  GH_WEBHOOK_INTAKE_REPOS   Path to config/intake-repos.json (the single
                            source of truth for which repos run intake).
                            Default <fleet-ops checkout>/config/intake-repos.json.
                            A repo NOT enrolled there is never dispatched
                            to pi-intake@<repo> (the synthetic canary repo
                            is the canonical case — it must keep the
                            receiver heartbeat green without spawning a
                            real intake tick on a non-existent repo).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "0.1.0"
SECRET_FILE = os.environ.get(
    "GH_WEBHOOK_SECRET_FILE",
    str(Path.home() / ".config" / "fleet-ops" / "gh-webhook.secret"),
)
BIND = os.environ.get("GH_WEBHOOK_RECEIVER_BIND", "127.0.0.1")
PORT = int(os.environ.get("GH_WEBHOOK_RECEIVER_PORT", "8088"))
DRY = os.environ.get("GH_WEBHOOK_RECEIVER_DRY", "") == "1"
PROM_FILE = os.environ.get(
    "GH_WEBHOOK_RECEIVER_PROM",
    "/var/lib/prometheus/node-exporter/fleet-gh-webhook-receiver.prom",
)
# config/intake-repos.json is the single source of truth for which repos
# run intake (fleet-ops#32). The receiver refuses to dispatch
# pi-intake@<repo> for a repo not enrolled here — the synthetic canary
# repo (fleet-ops-canary) is the canonical non-enrolled case: it must
# keep the receiver heartbeat green without firing a real intake tick on
# a repo that has no checkout, no labels, and no intake unit.
INTAKE_REPOS_FILE = os.environ.get(
    "GH_WEBHOOK_INTAKE_REPOS",
    "/home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json",
)
MAX_BODY = 1 * 1024 * 1024  # 1 MiB
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

_log = logging.getLogger("gh-webhook-receiver")


def _prom_quote(value: str) -> str:
    """Quote a label value for Prometheus exposition format.

    Prometheus label values MUST be double-quoted, with ``\\``, ``"``,
    and ``\\n`` escaped. Python's ``repr()`` emits single quotes
    (``unit='(ignored)'``) which node-exporter's textfile parser rejects
    silently — the series is dropped, ``absent()`` fires forever, and the
    FleetGhWebhookReceiverAbsent alert never clears. This is the
    fleet-ops#1464 root cause: the receiver wrote a healthy prom file
    that Prometheus could not scrape.
    """
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _read_secret() -> bytes:
    p = Path(SECRET_FILE)
    if not p.is_file():
        raise SystemExit(f"gh-webhook-receiver: secret file missing: {p}")
    s = p.read_text().strip()
    if not s:
        raise SystemExit(f"gh-webhook-receiver: secret file empty: {p}")
    return s.encode("utf-8")


def _load_enrolled_repos(path: str) -> set[str]:
    """Return the set of repo names enrolled in intake-repos.json.

    A missing or unparseable file degrades to an EMPTY set (fail-closed:
    no pi-intake@<repo> dispatch). fleet-ops#32 makes this file the single
    source of truth; the receiver never enables an intake unit itself.
    """
    try:
        data = json.loads(Path(path).read_text())
        repos = data.get("repos") or []
        return {str(r.get("name", "") or "") for r in repos if isinstance(r, dict)}
    except (OSError, ValueError) as e:
        _log.warning("intake-repos load failed (%s): %s — no intake dispatch", path, e)
        return set()


def verify_hmac(secret: bytes, body: bytes, signature_header: str) -> bool:
    """Constant-time HMAC SHA-256 verify. GitHub sends sha256=<hex>."""
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    try:
        given = bytes.fromhex(signature_header.split("=", 1)[1].strip())
    except ValueError:
        return False
    expect = hmac.new(secret, body, hashlib.sha256).digest()
    return hmac.compare_digest(given, expect)


def dispatch(event: str, action: str, label: str, repo: str, conclusion: str,
             dry: bool, enrolled: set[str] | None = None,
             pr_merged: str = "") -> tuple[str, str]:
    """Return (unit, reason). ``unit`` is empty when no-op. ``reason`` is
    human + log friendly.

    ``enrolled`` is the set of repos in config/intake-repos.json. A
    pi-intake@<repo> dispatch is refused for a repo NOT in that set —
    the synthetic canary repo (fleet-ops-canary) is the canonical
    non-enrolled case. fleet-deploy-check is fleet-wide, NOT per-repo,
    so it is never enrollment-gated.

    ``pr_merged`` is the pull_request.merged boolean ("true"/"false")
    for pull_request events; it is informational only — the reaper fires
    on ANY closed PR (merged OR closed), because both terminal states
    leave a claim worktree behind (fleet-ops#3269).
    """
    if event == "ping":
        return "", "ping (no-op)"

    if event == "pull_request":
        if not repo or not REPO_RE.match(repo):
            return "", f"pull_request: bad repo {repo!r}"
        if action == "closed":
            # A merged OR closed PR leaves its claim/issue-<N> worktree
            # behind. The reaper's Mode A reaps MERGED immediately and
            # CLOSED after the age gate (fleet-ops#3023), so both terminal
            # states must trigger it. systemctl start on an already-active
            # oneshot is a no-op, so a burst of closes dedupes naturally.
            return "fleet-worktree-reaper.service", \
                f"pull_request/{action}/merged={pr_merged} → fleet-worktree-reaper"
        return "", f"pull_request: ignored (action={action})"

    if event == "issues":
        if not repo or not REPO_RE.match(repo):
            return "", f"issues: bad repo {repo!r}"
        if action in ("labeled", "opened", "reopened"):
            if label == "agent-ready" or action == "opened":
                # 'opened' is the race-safe variant: the issue body itself
                # has agent-ready (auto-applied by org rules) or the worker
                # should at least try.
                if enrolled is not None and repo not in enrolled:
                    return "", f"issues: {repo!r} not enrolled in intake-repos.json"
                return f"pi-intake@{repo}.service", f"issues/{action}/agent-ready → pi-intake@{repo}"
            if label == "pipeline-red":
                return "fleet-deploy-check.service", f"issues/labeled/pipeline-red → fleet-deploy-check"
        return "", f"issues: ignored (action={action}, label={label})"

    if event == "workflow_run":
        if action == "completed" and conclusion == "success":
            return "fleet-deploy-check.service", "workflow_run/completed/success → fleet-deploy-check"
        return "", f"workflow_run: ignored (action={action}, conclusion={conclusion})"

    return "", f"unknown event: {event!r}"


def fire_unit(unit: str, dry: bool) -> tuple[int, str]:
    """systemctl --user start --no-block <unit>. Returns (rc, stderr)."""
    if dry:
        return 0, "DRY=1 — no systemctl call"
    if not unit or "/" in unit or not re.match(r"^[A-Za-z0-9._@-]+\.service$", unit):
        return 2, f"refusing to fire malformed unit: {unit!r}"
    try:
        proc = subprocess.run(
            ["systemctl", "--user", "start", "--no-block", unit],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return proc.returncode, (proc.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "systemctl --user start timed out"
    except FileNotFoundError as e:
        return 127, f"systemctl not found: {e}"


def write_prom(file_path: str, last_event_ts: float, last_unit: str,
               last_rc: int, total: int, last_event: str) -> None:
    """Write the heartbeat prom file atomically.

    Label values are double-quoted via ``_prom_quote`` so node-exporter's
    textfile parser accepts them. Single quotes (Python ``repr()``) are
    silently dropped — that was the fleet-ops#1464 root cause.
    """
    try:
        body = (
            "# HELP fleet_gh_webhook_receiver_last_green_seconds "
            "Epoch seconds of the last verified webhook the receiver "
            "accepted (organ heartbeat — bumped on every verified event, "
            "dispatched OR ignored, so the synthetic canary keeps it green).\n"
            "# TYPE fleet_gh_webhook_receiver_last_green_seconds gauge\n"
            f"fleet_gh_webhook_receiver_last_green_seconds{{unit={_prom_quote(last_unit)},event={_prom_quote(last_event)}}} "
            f"{last_event_ts:.0f}\n"
            "# HELP fleet_gh_webhook_receiver_dispatch_total "
            "Cumulative count of verified webhook dispatches since process start.\n"
            "# TYPE fleet_gh_webhook_receiver_dispatch_total counter\n"
            f"fleet_gh_webhook_receiver_dispatch_total {total}\n"
            "# HELP fleet_gh_webhook_receiver_last_rc "
            "systemctl return code of the last dispatch attempt (0 = ok, "
            "non-zero = failed to start unit).\n"
            "# TYPE fleet_gh_webhook_receiver_last_rc gauge\n"
            f"fleet_gh_webhook_receiver_last_rc {last_rc}\n"
        )
        Path(file_path).parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(file_path).with_suffix(Path(file_path).suffix + ".tmp")
        tmp.write_text(body)
        os.replace(tmp, file_path)
    except OSError as e:
        _log.warning("prom write skipped: %s", e)


class _State:
    secret: bytes = b""
    enrolled: set[str] = set()
    last_event_ts: float = 0.0
    last_unit: str = ""
    last_rc: int = -1
    last_event: str = ""
    total: int = 0

    @classmethod
    def record(cls, unit: str, rc: int, event: str) -> None:
        cls.last_event_ts = time.time()
        cls.last_unit = unit or "(none)"
        cls.last_rc = rc
        cls.last_event = event or "(unknown)"
        cls.total += 1
        write_prom(PROM_FILE, cls.last_event_ts, cls.last_unit,
                   cls.last_rc, cls.total, cls.last_event)

    @classmethod
    def record_verified(cls, event: str, reason: str) -> None:
        """Bump the heartbeat on every VERIFIED event — dispatched OR
        ignored — without incrementing the dispatch counter.

        The synthetic canary posts to a non-enrolled repo (fleet-ops-
        canary), so its events are 'ignored' by the dispatch table. The
        receiver heartbeat must still go green, or the
        FleetGhWebhookReceiverAbsent alert fires forever even though the
        channel is provably alive (the canary is the liveness probe).
        Bumping last_green here, on every verified receive, is what makes
        'silence is provable, not assumed' actually true.
        """
        cls.last_event_ts = time.time()
        cls.last_event = event or "(unknown)"
        # Keep last_unit/last_rc from the last real dispatch; an ignored
        # event does not erase the dispatch state, it only refreshes the
        # heartbeat timestamp.
        write_prom(PROM_FILE, cls.last_event_ts, cls.last_unit,
                   cls.last_rc, cls.total, cls.last_event)


def _make_handler(secret: bytes):

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            # route to stderr so journal captures it; silence stdout
            _log.info("%s - %s", self.address_string(), fmt % args)

        def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
            if self.path != "/healthz":
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({
                "status": "ok",
                "version": VERSION,
                "total_dispatched": _State.total,
                "dry": DRY,
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/webhook":
                self.send_response(404)
                self.end_headers()
                return
            n = int(self.headers.get("Content-Length", "0") or "0")
            if n <= 0 or n > MAX_BODY:
                self.send_response(413)
                self.end_headers()
                return
            body = self.rfile.read(n)
            sig = self.headers.get("X-Hub-Signature-256", "")
            event = self.headers.get("X-GitHub-Event", "")
            delivery = self.headers.get("X-GitHub-Delivery", "")

            if not verify_hmac(secret, body, sig):
                _log.warning("HMAC FAIL event=%s delivery=%s", event, delivery)
                self.send_response(401)
                self.end_headers()
                return

            action = label = repo = conclusion = ""
            issue_number = ""
            pr_merged = ""
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload = {}
            if isinstance(payload, dict):
                action = str(payload.get("action", "") or "")
                repo = ((payload.get("repository") or {}).get("name") or "")
                if event == "issues":
                    label_obj = payload.get("label") or {}
                    label = str(label_obj.get("name", "") or "")
                    issue = payload.get("issue") or {}
                    issue_number = str(issue.get("number", "") or "")
                elif event == "workflow_run":
                    conclusion = str(
                        ((payload.get("workflow_run") or {}).get("conclusion")) or ""
                    )
                elif event == "pull_request":
                    pr = payload.get("pull_request") or {}
                    pr_merged = str(pr.get("merged", "") or "")

            unit, reason = dispatch(event, action, label, repo, conclusion, DRY,
                                    _State.enrolled, pr_merged)
            if unit:
                rc, err = fire_unit(unit, DRY)
                _State.record(unit, rc, event)
                _log.info(
                    "DISPATCH event=%s delivery=%s repo=%s issue=%s "
                    "action=%s label=%s unit=%s rc=%d reason=%s err=%s",
                    event, delivery, repo, issue_number, action, label, unit, rc, reason, err,
                )
                body_out = json.dumps({
                    "received": True, "dispatched": unit, "rc": rc,
                    "delivery": delivery,
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body_out)))
                self.end_headers()
                self.wfile.write(body_out)
            else:
                # Ignored events are STILL verified receives — bump the
                # heartbeat so the synthetic canary (non-enrolled repo)
                # keeps FleetGhWebhookReceiverAbsent green.
                _State.record_verified(event, reason)
                _log.info("IGNORED event=%s delivery=%s reason=%s", event, delivery, reason)
                body_out = json.dumps({
                    "received": True, "ignored": reason, "delivery": delivery,
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body_out)))
                self.end_headers()
                self.wfile.write(body_out)

    return Handler


def main(argv: list[str]) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    _State.secret = _read_secret()
    _State.enrolled = _load_enrolled_repos(INTAKE_REPOS_FILE)
    _log.info("starting gh-webhook-receiver v%s bind=%s port=%d dry=%s prom=%s "
              "intake_repos=%s enrolled=%s",
              VERSION, BIND, PORT, DRY, PROM_FILE, INTAKE_REPOS_FILE,
              sorted(_State.enrolled) or "(none)")
    # Initial prom write so absent(fleet_gh_webhook_receiver_last_green_seconds)
    # has a NaN-with-labels gauge, not a hard missing series. Double-quoted
    # labels so node-exporter actually scrapes it (fleet-ops#1464 root cause).
    write_prom(PROM_FILE, 0.0, "", -1, 0, "")
    server = ThreadingHTTPServer((BIND, PORT), _make_handler(_State.secret))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log.info("shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
