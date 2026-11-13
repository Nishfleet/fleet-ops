"""Stub of the GitHub REST calls systemd/fleet-grafana-github-token.service,
rootfs/etc/systemd/system/fleet-hermes-github-token.service and runner 22's
just-in-time drop-in (rootfs/etc/systemd/system/fleet-runner@22.service.d/10-jit.conf) make.

fleet-ops#9445, fleet-ops#9738. CI runs each unit's real ExecStart under systemd
against this stub (.github/workflows/ci.yml, step "GitHub App token units mint
and refresh"; the Hermes unit through tests/test_hermes_github_token.py).
The stub is strict where GitHub is strict, so a malformed JWT or request body
fails the run instead of passing silently:

  GET  /repos/Nishfleet/<repo>/installation
       needs a Bearer RS256 JWT: header alg RS256, iss == APP_ID, exp - iat
       within GitHub's 10 minute cap, and a signature that verifies with the
       App's public key.
  POST /app/installations/<id>/access_tokens
       needs the same JWT and a body that asks for exactly repositories
       [fleet-ops] and permissions {issues: write} (the Grafana token), or no
       repositories key and permissions {actions: read, issues: write,
       pull_requests: read} (the hermes login: every repo the App is installed
       on, which is what gh repo list and the digest jobs need).

  And for the JIT drop-in, with the installation token the mint returned (not a JWT), which must
  hold exactly organization_self_hosted_runners:write (anything else is 403, as GitHub answers):
  GET    /orgs/Nishfleet/actions/runners            the registered runners
  DELETE /orgs/Nishfleet/actions/runners/<id>       204, or 404
  POST   /orgs/Nishfleet/actions/runners/generate-jitconfig
       needs name, runner_group_id and labels; 409 "Already exists" when a runner of that name
       is registered; else 201, registers the name and returns encoded_jit_config.
  The runners start with one stale record, netcup-agent-22 (id 5), like the pilot's standing
  registration.

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
HERMES_PERMS = {"actions": "read", "issues": "write", "pull_requests": "read"}
RUNNER_PERMS = {"organization_self_hosted_runners": "write"}
TOKENS = {}
RUNNERS = {5: "netcup-agent-22"}


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_problem(auth):
    if not auth or auth[:7].lower() != "bearer ":
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
            input=f"{h}.{p}".encode(), capture_output=True, check=False)
    return None if r.returncode == 0 else "signature"


class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def org_call(self, method, auth, body):
        if TOKENS.get(auth[7:]) != RUNNER_PERMS:
            return 403, {"message": "Resource not accessible by integration"}, "wrong-permissions"
        rest = self.path.split("?")[0][len("/orgs/Nishfleet/actions/runners"):]
        if method == "GET" and rest == "":
            runners = [{"id": i, "name": n} for i, n in RUNNERS.items()]
            return 200, {"total_count": len(runners), "runners": runners}, "ok"
        if method == "DELETE" and rest[:1] == "/" and rest[1:].isdigit():
            if int(rest[1:]) not in RUNNERS:
                return 404, {"message": "Not Found"}, "unknown-runner"
            del RUNNERS[int(rest[1:])]
            return 204, None, "ok"
        if method == "POST" and rest == "/generate-jitconfig":
            req = json.loads(body or b"{}")
            labels = req.get("labels")
            if not (req.get("name") and isinstance(req.get("runner_group_id"), int)
                    and isinstance(labels, list) and 1 <= len(labels) <= 100):
                return 422, {"message": "Validation Failed"}, "bad-body"
            if req["name"] in RUNNERS.values():
                return 409, {"message": "Already exists"}, "already-exists"
            RUNNERS[max(RUNNERS, default=0) + 1] = req["name"]
            return 201, {"encoded_jit_config": f"jit_stub_{req['name']}_{req['runner_group_id']}_{'+'.join(labels)}"}, "ok"
        return 404, {"message": "Not Found"}, "unknown"

    def handle_any(self, method):
        global MINTS
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(MODE_FILE) as f:
            mode = f.read().strip()
        auth = self.headers.get("authorization") or ""
        org = self.path.startswith("/orgs/Nishfleet/actions/runners")
        bad = None if org else jwt_problem(auth)
        verdict = "ok"
        if org and mode != "fail":
            code, out, verdict = self.org_call(method, auth, body)
        elif mode == "fail":
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
                     {"permissions": HERMES_PERMS}, {"permissions": RUNNER_PERMS}]
            if repo is None:
                verdict, code, out = "unknown", 404, {"message": "Not Found"}
            elif json.loads(body or b"{}") not in wants:
                verdict, code, out = "bad-body", 422, {"message": "bad body"}
            else:
                MINTS += 1
                verdict = "ok " + ",".join(sorted(json.loads(body)["permissions"]))
                TOKENS[f"ghs_stub_{MINTS}"] = json.loads(body)["permissions"]
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

    def do_DELETE(self):
        self.handle_any("DELETE")

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(PORT)), H).serve_forever()
