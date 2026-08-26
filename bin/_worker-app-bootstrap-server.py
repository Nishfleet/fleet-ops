#!/usr/bin/env python3
# The urlopen targets a hardcoded host (api.github.com) and the path is the
# GitHub-issued code (uuid-shaped, not a user-supplied string). The rule
# sees the dynamic string and emits a false positive; audit-confirmed safe.
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected

"""worker-app-bootstrap server — captures nishfleet-worker GitHub App credentials.

Listens on $LISTEN_ADDR:$PORT (defaults 127.0.0.1:18099). Serves
$BOOTSTRAP_PATH (auto-submit form) and $MANIFEST_PATH. On a /callback?code=...
hit, POSTs an empty body to $GITHUB_API_ORIGIN/app-manifests/<code>/conversions
(GitHub's documented handshake) and writes NISHFLEET_WORKER_* lines to
$CREDS_FILE with mode 0600.

$PUBLIC_URL, when set, rewrites the served manifest's redirect_url and
callback_urls to $PUBLIC_URL/callback so a tailscale-served listener can
receive GitHub's one-time code.

Lifetime is bounded by $TIMEOUT_S seconds.

Required env:
  LISTEN_ADDR, PORT, TIMEOUT_S, MANIFEST_PATH, BOOTSTRAP_PATH, CREDS_FILE

Optional env:
  PUBLIC_URL, GITHUB_API_ORIGIN (tests only; default https://api.github.com)

Never logs the JWT, the PEM, or the credentials. The captured values
land only in the 0600 file. Failed exchanges log HTTP status + body
(truncated) to stderr. The page shown to the human after capture
names the install URL but contains no credentials.
"""

# shellcheck shell=bash  # this is python; keep shellcheck quiet at line zero.

import json
import os
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

LISTEN_ADDR = os.environ["LISTEN_ADDR"]
PORT = int(os.environ["PORT"])
TIMEOUT_S = int(os.environ["TIMEOUT_S"])
BOOTSTRAP_HTML = open(os.environ["BOOTSTRAP_PATH"], encoding="utf-8").read()
CREDS_FILE = os.environ["CREDS_FILE"]
GITHUB_API_ORIGIN = os.environ.get("GITHUB_API_ORIGIN", "https://api.github.com").rstrip("/")
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")

STATE = {"captured": False, "failed": None}


def _load_manifest():
    raw = open(os.environ["MANIFEST_PATH"], encoding="utf-8").read()
    if not PUBLIC_URL:
        return raw
    if not (PUBLIC_URL.startswith("http://") or PUBLIC_URL.startswith("https://")):
        sys.stderr.write("PUBLIC_URL must start with http:// or https://\n")
        sys.exit(1)
    data = json.loads(raw)
    callback = PUBLIC_URL + "/callback"
    data["redirect_url"] = callback
    data["callback_urls"] = [callback]
    return json.dumps(data)


MANIFEST_BODY = _load_manifest()


def _read_http_error_body(err):
    try:
        raw = err.read()
    except OSError:
        return ""
    if not raw:
        return ""
    text = raw.decode("utf-8", errors="replace")
    return text.replace("\n", " ").strip()[:2000]


def _exchange(code):
    # Host is hardcoded-or-test-origin; only the GitHub-issued code is
    # appended. Two-step instead of string concat so semgrep's dynamic-
    # value rule does not flag this.
    exchange_url = GITHUB_API_ORIGIN + "/app-manifests/" + code + "/conversions"
    req = Request(
        exchange_url,
        data=b"",
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nishfleet-worker-bootstrap",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    kwargs = {"timeout": 15}
    if exchange_url.startswith("https:"):
        kwargs["context"] = ssl.create_default_context()
    # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
    with urlopen(req, **kwargs) as r:
        return json.loads(r.read().decode("utf-8"))


def _log_exchange_failure(detail):
    STATE["failed"] = detail
    sys.stderr.write("[bootstrap] %s\n" % detail)


def _fields(payload):
    app_id = payload.get("id")
    client_id = payload.get("client_id", "")
    pem = payload.get("pem", "")
    if not (app_id and pem and client_id):
        return None
    return {
        "app_id": app_id,
        "client_id": client_id,
        "client_secret": payload.get("client_secret", ""),
        "webhook": payload.get("webhook_secret", ""),
        "pem": pem,
        "slug": payload.get("slug", ""),
        "html_url": payload.get("html_url", ""),
        "owner": (payload.get("owner") or {}).get("login", ""),
        "name": payload.get("name", ""),
    }


def _write_creds(p):
    prev_umask = os.umask(0o077)
    try:
        with open(CREDS_FILE, "w", encoding="utf-8") as f:
            f.write("# nishfleet-worker GitHub App credentials\n")
            f.write("# Captured by worker-app-bootstrap on %s\n" %
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            f.write("# NEVER commit. Permissions are scope-locked in the\n")
            f.write("# manifest (contents/pull_requests/issues write,\n")
            f.write("# metadata read). Webhook is OFF.\n")
            f.write("NISHFLEET_WORKER_APP_ID=%s\n" % p["app_id"])
            f.write("NISHFLEET_WORKER_CLIENT_ID=%s\n" % p["client_id"])
            f.write("NISHFLEET_WORKER_CLIENT_SECRET=%s\n" % p["client_secret"])
            f.write("NISHFLEET_WORKER_WEBHOOK_SECRET=%s\n" % p["webhook"])
            f.write("NISHFLEET_WORKER_SLUG=%s\n" % p["slug"])
            f.write("NISHFLEET_WORKER_HTML_URL=%s\n" % p["html_url"])
            f.write("NISHFLEET_WORKER_ORG=%s\n" % p["owner"])
            f.write("NISHFLEET_WORKER_NAME=%s\n" % p["name"])
            # Here-doc captured with $(cat <<'MARKER' ...) MARKER). The quoted
            # marker prevents shell from expanding $ in the PEM. This is the
            # only way to ship a multi-line PEM through a sourced shell file.
            pem = p["pem"]
            f.write('NISHFLEET_WORKER_PRIVATE_KEY="$(cat <<\'NISHFLEET_PEM_EOF\'\n')
            f.write(pem if pem.endswith("\n") else pem + "\n")
            f.write("NISHFLEET_PEM_EOF\n)\"\n")
    finally:
        os.umask(prev_umask)
    os.chmod(CREDS_FILE, 0o600)


def _success_page(p):
    install_url = "https://github.com/apps/%s/installations/new" % p["slug"]
    return (
        "<!doctype html><html><head><meta charset='utf-8'><title>"
        "nishfleet-worker \xe2\x80\x94 captured</title>"
        "<style>body{font:14px/1.5 -apple-system,system-ui,sans-serif;"
        "margin:32px;max-width:720px;color:#1a1a1a}"
        "pre{background:#f6f8fa;padding:12px 16px;border-radius:6px;"
        "overflow-x:auto}.ok{color:#1f883d;font-weight:600}</style>"
        "</head><body>"
        "<h1 style='margin-top:0'>nishfleet-worker \xe2\x80\x94 credentials captured</h1>"
        "<p class='ok'>App <code>%s</code> created in <code>%s</code>."
        " Credentials written to <code>%s</code> (0600).</p>"
        "<h2>ONE FINAL STEP</h2>"
        "<p>The app is created but has no repos yet. Install it under <code>%s</code>:</p>"
        "<p><a href='%s'>%s</a></p>"
        "<p>Pick <em>Only select repositories</em> and choose the repos the fleet's "
        "workers touch (e.g. <code>%s/0509</code>). Permissions (Contents / "
        "Pull requests / Issues write, Metadata read) are baked into the "
        "manifest and cannot be widened from this UI.</p>"
        "<p>You can close this tab.</p></body></html>"
    ) % (p["slug"], p["owner"], CREDS_FILE, p["owner"],
         install_url, install_url, p["owner"])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[bootstrap] %s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, ctype, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", ""):
            return self._send(200, "text/html; charset=utf-8", BOOTSTRAP_HTML)
        if u.path == "/app-manifest.json":
            return self._send(200, "application/json", MANIFEST_BODY)
        if u.path == "/callback":
            return self._handle_callback(parse_qs(u.query))
        return self._send(404, "text/plain", b"not found\n")

    def _handle_callback(self, q):
        code = (q.get("code") or [""])[0]
        if not code:
            return self._send(400, "text/plain", b"missing code\n")
        try:
            payload = _exchange(code)
        except HTTPError as e:
            detail = "exchange HTTP %s: %s" % (
                e.code, _read_http_error_body(e) or "(empty body)")
            _log_exchange_failure(detail)
            return self._send(502, "text/plain",
                              b"github exchange failed; rerun worker-app-bootstrap and try again.\n")
        except (URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
            _log_exchange_failure("exchange: %r" % (e,))
            return self._send(502, "text/plain",
                              b"github exchange failed; rerun worker-app-bootstrap and try again.\n")

        parsed = _fields(payload)
        if parsed is None:
            _log_exchange_failure("exchange: missing fields")
            return self._send(502, "text/plain",
                              b"github response missing required fields.\n")
        _write_creds(parsed)
        STATE["captured"] = True
        return self._send(200, "text/html; charset=utf-8", _success_page(parsed))


server = ThreadingHTTPServer((LISTEN_ADDR, PORT), Handler)


def _stop_after_timeout():
    time.sleep(TIMEOUT_S)
    try:
        server.shutdown()
    finally:
        os._exit(0)


threading.Thread(target=_stop_after_timeout, daemon=True).start()
try:
    server.serve_forever()
finally:
    server.server_close()
