"""Stub of the two GitHub REST calls systemd/fleet-grafana-github-token.service and
systemd/fleet-worker-github-token@.service make.

fleet-ops#9445, fleet-ops#9738. CI runs each unit's real ExecStart under systemd
against this stub (.github/workflows/ci.yml, steps "GitHub App token unit mints
and refreshes" and "Worker token unit mints one repo token per launch").
The stub is strict where GitHub is strict, so a malformed JWT or request body
fails the run instead of passing silently:

  GET  /repos/Nishfleet/<repo>/installation
       needs a Bearer RS256 JWT: header alg RS256, iss == APP_ID, exp - iat
       within GitHub's 10 minute cap, and a signature that verifies with the
       App's public key.
  POST /app/installations/<id>/access_tokens
       needs the same JWT and a body that asks for exactly repositories
       [fleet-ops] and permissions {issues: write} (the Grafana token), or
       exactly the one repo whose installation was looked up and permissions
       {contents, issues, pull_requests: write} (the worker token).

Every answered mint returns a distinct token (ghs_stub_<n>) so a test can tell
a refresh from a stale file. The mode file switches the stub to answering 401
"Bad credentials" (what GitHub returns for a bad JWT) to drill the failure path.

usage: github_app_stub.py PORT PUBLIC_KEY_PEM APP_ID MODE_FILE LOG_FILE
"""
import base64
import http.server
import json
import subprocess
import sys
import tempfile

PORT, PUB, APP_ID, MODE_FILE, LOG_FILE = sys.argv[1:6]
MINTS = 0
REPOS = {}
WORKER_PERMS = {"contents": "write", "issues": "write", "pull_requests": "write"}


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_problem(auth):
    if not auth or not auth.startswith("Bearer "):
        return "no bearer"
    try:
        h, p, s = auth[7:].split(".")
        head, pay = json.loads(b64d(h)), json.loads(b64d(p))
    except Exception as e:  # noqa: BLE001 - any parse failure is a bad JWT
        return f"unparseable: {e}"
    if head.get("alg") != "RS256":
        return "alg"
    if str(pay.get("iss")) != APP_ID:
        return "iss"
    if not 0 < pay["exp"] - pay["iat"] <= 600:
        return "lifetime"
    with tempfile.NamedTemporaryFile() as sig:
        sig.write(b64d(s))
        sig.flush()
        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", PUB, "-signature", sig.name],
            input=f"{h}.{p}".encode(), capture_output=True)
    return None if r.returncode == 0 else "signature"


class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        global MINTS
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        mode = open(MODE_FILE).read().strip()
        bad = jwt_problem(self.headers.get("authorization"))
        verdict = "ok"
        if mode == "fail":
            verdict, code, out = "mode-fail", 401, {"message": "Bad credentials"}
        elif bad:
            verdict, code, out = f"bad-jwt:{bad}", 401, {"message": "Bad credentials"}
        elif method == "GET" and self.path.startswith("/repos/Nishfleet/") and self.path.endswith("/installation"):
            repo = self.path[len("/repos/Nishfleet/"):-len("/installation")]
            iid = 77 if repo == "fleet-ops" else 1000 + len(REPOS)
            REPOS[iid] = repo
            code, out = 200, {"id": iid}
        elif method == "POST" and self.path.startswith("/app/installations/") and self.path.endswith("/access_tokens"):
            iid = int(self.path.split("/")[3])
            repo = REPOS.get(iid)
            wants = [{"repositories": ["fleet-ops"], "permissions": {"issues": "write"}},
                     {"repositories": [repo], "permissions": WORKER_PERMS}]
            if repo is None or json.loads(body or b"{}") not in wants:
                verdict, code, out = "bad-body", 422, {"message": "bad body"}
            else:
                MINTS += 1
                code, out = 201, {"token": f"ghs_stub_{MINTS}"}
        else:
            verdict, code, out = "unknown", 404, {"message": "Not Found"}
        with open(LOG_FILE, "a") as f:
            f.write(f"{method} {self.path} -> {code} {verdict}\n")
        self.reply(code, out)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(PORT)), H).serve_forever()
