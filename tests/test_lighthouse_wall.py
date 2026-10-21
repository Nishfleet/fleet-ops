import http.server
import os
import pathlib
import subprocess
import threading

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/lighthouse.yml"
WALL = "https://nish345.cloudflareaccess.com/cdn-cgi/access/login/0509.io?kid=5dcfc647"
STEP = '.jobs.lighthouse.steps[] | select(.id == "reach")'
AUDIT = '.jobs.lighthouse.steps[] | select(has("with"))'


def _y(expr):
    out = subprocess.run(["yq", expr, str(WORKFLOW)], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out.strip()


def _run(urls):
    script = _y(f"{STEP} | .run")
    with subprocess.Popen(["mktemp"], stdout=subprocess.PIPE, text=True) as p:
        out = pathlib.Path(p.stdout.read().strip())
    try:
        done = subprocess.run(
            ["bash", "-e", "-c", script],
            env=dict(os.environ, URLS=urls, GITHUB_OUTPUT=str(out)),
            capture_output=True,
            text=True,
        )
        assert done.returncode == 0, done.stderr
        text = out.read_text()
        head = "urls<<END\n"
        assert text.startswith(head) and text.endswith("END\n"), text
        return text[len(head) : -len("END\n")], done.stdout + done.stderr
    finally:
        out.unlink(missing_ok=True)


class _Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        self.send_response({"open": 200, "walled": 302, "login": 302}[path.lstrip("/")])
        if path == "/walled":
            self.send_header("Location", WALL)
        if path == "/login":
            self.send_header("Location", "/login?moved=1")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def site():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Pages)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    thread.join()


def test_a_walled_page_is_skipped_and_named(site):
    urls, logged = _run(f"{site}/open\n{site}/walled\n")
    assert urls == f"{site}/open\n"
    assert "::warning::" in logged and f"{site}/walled answers the Cloudflare Access login" in logged


def test_every_page_walled_leaves_nothing_to_audit(site):
    urls, logged = _run(f"{site}/walled\n{site}/walled?again\n")
    assert urls == ""
    assert logged.count("::warning::") == 2


def test_a_redirect_on_the_site_is_still_audited(site):
    urls, logged = _run(f"{site}/login\n")
    assert urls == f"{site}/login\n"
    assert "::warning::" not in logged


def test_an_empty_list_skips_the_audit_instead_of_failing_it():
    assert _y('.jobs.lighthouse.steps[] | select(has("uses")) | select(.with.configPath) | .if') == "steps.reach.outputs.urls != ''"


def test_the_audit_reads_the_list_the_skip_step_wrote():
    audit = '.jobs.lighthouse.steps[] | select(has("uses")) | select(.with.configPath)'
    assert _y(f"{audit} | .with.urls") == "${{ steps.reach.outputs.urls }}"
    assert _y(f"{audit} | .with.configPath") == "./fleet-ops/config/lighthouserc.json"
    assert _y(f"{audit} | .with.runs") == "5"


def test_the_skip_step_passes_the_urls_through_env_not_into_the_run_block():
    assert "${{ inputs.urls }}" in _y(f"{STEP} | .env.URLS")
    assert "${{" not in _y(f"{STEP} | .run")
