import base64
import http.server
import json
import pathlib
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/deploy-failed.yaml"
QUADLET = ROOT / "containers/quadlet/fleet-grafana.container"
YQ = shutil.which("yq")
DOCKER = shutil.which("docker")
RUNS_PATH = re.compile(r"^/api/v3/repos/Nishfleet/([^/]+)/actions/workflows/([^/]+)/runs$")
SCENARIOS = {
    "red-for-30h": ([("success", 50), ("failure", 30), ("failure", 1)], 1, 1),
    "red-for-23h": ([("success", 50), ("failure", 23)], 1, 0),
    "red-for-25h": ([("success", 50), ("failure", 25)], 1, 1),
    "green": ([("failure", 30), ("success", 1)], 0, 0),
    "cancel-superseded": ([("success", 50), ("cancelled", 2), ("success", 1)], 0, 0),
    "cancel-newest-25h": ([("success", 50), ("cancelled", 25)], 1, 1),
    "cancel-then-skipped": ([("success", 50), ("cancelled", 30), ("skipped", 1)], 1, 1),
    "skipped-for-30h": ([("success", 50), ("skipped", 30), ("skipped", 1)], 0, 1),
    "skipped-for-2h": ([("success", 50), ("skipped", 2)], 0, 0),
    "running": ([("success", 3), ("in_progress", 0)], 0, 0),
    "undated-failure": ([("success", 50), ("failure", None)], 1, "error"),
}
SEEN = []


def _run(n, conclusion, hours):
    at = None if hours is None else (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    status = "in_progress" if conclusion == "in_progress" else "completed"
    return {
        "id": 1000 + n, "name": "deploy", "head_branch": "main", "head_sha": f"{n:040d}",
        "created_at": at, "updated_at": at, "run_started_at": at,
        "html_url": f"https://github.invalid/runs/{n}", "url": f"https://api.github.invalid/runs/{n}",
        "status": status, "conclusion": None if status != "completed" else conclusion,
        "event": "push", "workflow_id": 1, "run_number": n,
    }


class _GitHub(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        match = RUNS_PATH.match(url.path)
        if not match or match.group(1) not in SCENARIOS:
            self.send_error(404)
            return
        SEEN.append((match.group(1), match.group(2), urllib.parse.parse_qs(url.query), self.headers.get("Authorization")))
        runs = [_run(n, c, h) for n, (c, h) in enumerate(SCENARIOS[match.group(1)][0], start=1)]
        body = json.dumps({"total_count": len(runs), "workflow_runs": runs[::-1]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _quadlet(key):
    return next(line.split("=", 1)[1] for line in QUADLET.read_text().splitlines() if line.startswith(key + "="))


def _rule(uid):
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", f'.groups[].rules[] | select(.uid == "{uid}")', str(RULES)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


@pytest.fixture(scope="module")
def grafana():
    assert DOCKER, "docker must be on PATH: this test runs the rules on the pinned Grafana image"
    stub = http.server.ThreadingHTTPServer(("127.0.0.1", _free_port()), _GitHub)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    image = _quadlet("Image")
    plugin = next(
        p for line in QUADLET.read_text().splitlines() if line.startswith("Environment=GF_PLUGINS_PREINSTALL_SYNC=")
        for p in line.split("=", 2)[2].split(",") if p.startswith("grafana-github-datasource@"))
    port = _free_port()
    password = secrets.token_hex(16)
    name = f"deploy-failed-engine-{secrets.token_hex(4)}"
    with tempfile.TemporaryDirectory() as tmp:
        provisioning = pathlib.Path(tmp, "datasources")
        provisioning.mkdir()
        alerting = pathlib.Path(tmp, "alerting")
        alerting.mkdir()
        shutil.copy(RULES, alerting / RULES.name)
        provisioning.joinpath("stub.yaml").write_text(json.dumps({"apiVersion": 1, "datasources": [{
            "name": "fleet-github", "uid": "fleet-github", "type": "grafana-github-datasource", "access": "proxy",
            "jsonData": {"selectedAuthType": "personal-access-token", "githubUrl": f"http://127.0.0.1:{stub.server_port}"},
            "secureJsonData": {"accessToken": "stub-token"},
        }]}))
        pathlib.Path(tmp).chmod(0o755)
        for path in (provisioning, alerting):
            path.chmod(0o755)
        for path in (provisioning / "stub.yaml", alerting / RULES.name):
            path.chmod(0o644)
        subprocess.run([DOCKER, "run", "-d", "--name", name, "--network", "host",
                        "-e", "TZ=Asia/Kolkata", "-e", "GF_SERVER_HTTP_ADDR=127.0.0.1", "-e", f"GF_SERVER_HTTP_PORT={port}",
                        "-e", f"GF_SECURITY_ADMIN_PASSWORD={password}", "-e", f"GF_PLUGINS_PREINSTALL_SYNC={plugin}",
                        "-e", "GF_ANALYTICS_REPORTING_ENABLED=false", "-e", "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
                        "-v", f"{provisioning}:/etc/grafana/provisioning/datasources:ro",
                        "-v", f"{alerting}:/etc/grafana/provisioning/alerting:ro", image],
                       check=True, capture_output=True)
        base = f"http://127.0.0.1:{port}"
        auth = {"Authorization": "Basic " + base64.b64encode(f"admin:{password}".encode()).decode(), "Content-Type": "application/json"}
        try:
            deadline = time.monotonic() + 240
            while True:
                try:
                    urllib.request.urlopen(urllib.request.Request(f"{base}/api/datasources/uid/fleet-github", headers=auth), timeout=5)
                    urllib.request.urlopen(urllib.request.Request(f"{base}/api/plugins/grafana-github-datasource/settings", headers=auth), timeout=5)
                    urllib.request.urlopen(urllib.request.Request(f"{base}/api/v1/provisioning/alert-rules/deploy-failed-24h-0509", headers=auth), timeout=5)
                    break
                except (urllib.error.URLError, ConnectionError):
                    assert time.monotonic() < deadline, subprocess.run([DOCKER, "logs", "--tail", "40", name], capture_output=True, text=True).stderr
                    time.sleep(2)
            date = subprocess.run([DOCKER, "exec", name, "date", "+%Z"], capture_output=True, text=True, check=True).stdout.strip()
            yield base, auth, date
        finally:
            subprocess.run([DOCKER, "rm", "-f", name], capture_output=True)
            stub.shutdown()


def _evaluate(grafana, uid, repo):
    base, auth, _ = grafana
    data = json.load(urllib.request.urlopen(urllib.request.Request(f"{base}/api/v1/provisioning/alert-rules/{uid}", headers=auth), timeout=10))["data"]
    assert [{k: v for k, v in d["model"].items() if k not in ("intervalMs", "maxDataPoints")} for d in data] == [d["model"] for d in _rule(uid)["data"]]
    query = data[0]["model"]
    query["repository"] = query["options"]["repository"] = repo
    request = urllib.request.Request(f"{base}/api/v1/eval", data=json.dumps({"data": data, "condition": "C"}).encode(), headers=auth, method="POST")
    results = json.load(urllib.request.urlopen(request, timeout=60))["results"]
    assert results["A"].get("frames"), results["A"]
    fields = {f["name"]: f["type"] for f in results["A"]["frames"][0]["schema"]["fields"]}
    assert (fields["id"], fields["created_at"], fields["status"], fields["conclusion"]) == ("number", "time", "string", "string")
    if results["C"].get("error"):
        return "error"
    (frame,) = results["C"]["frames"]
    return frame["data"]["values"][0][0]


def test_the_container_runs_in_a_zone_that_is_not_utc(grafana):
    assert grafana[2] == "IST"


@pytest.mark.parametrize("repo", sorted(SCENARIOS))
def test_grafanas_engine_reads_each_scenario_from_the_real_plugin(grafana, repo):
    _, issue, page = SCENARIOS[repo]
    assert _evaluate(grafana, "deploy-failed-0509", repo) == issue
    assert _evaluate(grafana, "deploy-failed-24h-0509", repo) == page


def test_the_plugin_asked_github_for_seven_days_of_main_runs_of_the_rules_workflow(grafana):
    assert SEEN
    for repo, workflow, query, authorization in SEEN:
        assert (workflow, query["branch"], query["per_page"], authorization) == ("deploy-production.yml", ["main"], ["100"], "Bearer stub-token")
        start, end = (datetime.fromisoformat(t.replace("Z", "+00:00")) for t in query["created"][0].split(".."))
        assert end - start == timedelta(days=7)
