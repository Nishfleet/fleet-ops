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
AUDIT = '.jobs.lighthouse.steps[] | select(has("uses")) | select(.with.configPath)'


def _y(expr):
    out = subprocess.run(["yq", expr, str(WORKFLOW)], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out.strip()


def _run(urls, require="false"):
    script = _y(f"{STEP} | .run")
    with subprocess.Popen(["mktemp"], stdout=subprocess.PIPE, text=True) as p:
        out = pathlib.Path(p.stdout.read().strip())
    try:
        done = subprocess.run(
            ["bash", "-e", "-c", script],
            env=dict(os.environ, URLS=urls, REQUIRE=require, GITHUB_OUTPUT=str(out)),
            capture_output=True,
            text=True,
        )
        text = out.read_text()
        if done.returncode != 0:
            return None, done.stdout + done.stderr, done.returncode
        head = "urls<<END\n"
        assert text.startswith(head) and text.endswith("END\n"), text
        return text[len(head) : -len("END\n")], done.stdout + done.stderr, 0
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
    urls, logged, code = _run(f"{site}/open\n{site}/walled\n")
    assert code == 0
    assert urls == f"{site}/open\n"
    assert "::warning::" in logged and f"{site}/walled answers the Cloudflare Access login" in logged


def test_every_page_walled_leaves_nothing_to_audit(site):
    urls, logged, code = _run(f"{site}/walled\n{site}/walled?again\n")
    assert code == 0 and urls == ""
    assert logged.count("::warning::") == 2


def test_a_caller_that_requires_the_audit_fails_when_nothing_is_left(site):
    urls, logged, code = _run(f"{site}/walled\n", require="true")
    assert code != 0
    assert urls is None
    assert "::error::every URL answers the Cloudflare Access login, so nothing was audited" in logged


def test_a_caller_that_requires_the_audit_still_audits_a_reachable_page(site):
    urls, logged, code = _run(f"{site}/open\n{site}/walled\n", require="true")
    assert code == 0 and urls == f"{site}/open\n"


def test_a_redirect_on_the_site_is_still_audited(site):
    urls, logged, code = _run(f"{site}/login\n")
    assert code == 0 and urls == f"{site}/login\n"
    assert "::warning::" not in logged


def test_an_empty_list_skips_the_audit_instead_of_failing_it():
    assert _y('.jobs.lighthouse.steps[] | select(has("uses")) | select(.with.configPath) | .if') == "steps.reach.outputs.urls != ''"


def test_the_audit_reads_the_list_the_skip_step_wrote():
    assert _y(f"{AUDIT} | .with.urls") == "${{ steps.reach.outputs.urls }}"
    assert _y(f"{AUDIT} | .with.configPath") == "./config/lighthouserc.json"
    assert _y(f"{AUDIT} | .with.runs") == "5"


def test_the_skip_step_passes_the_urls_through_env_not_into_the_run_block():
    assert "${{ inputs.urls }}" == _y(f"{STEP} | .env.URLS")
    assert "${{ inputs.require_audit }}" == _y(f"{STEP} | .env.REQUIRE")
    assert "${{" not in _y(f"{STEP} | .run")


def test_the_fail_switch_is_off_unless_the_caller_asks():
    assert _y(".on.workflow_call.inputs.require_audit.default") == "false"
    assert _y(".on.workflow_call.inputs.require_audit.type") == "boolean"
