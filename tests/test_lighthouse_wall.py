import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/lighthouse.yml"
WALL = "https://nish345.cloudflareaccess.com/cdn-cgi/access/login/0509.io?kid=5dcfc647"
STEP = '.jobs.lighthouse.steps[] | select(.id == "reach")'
AUDIT = '.jobs.lighthouse.steps[] | select(has("uses")) | select(.with.configPath)'
VERDICT = '.jobs.lighthouse.steps[] | select(.name | test("^Verdict on a failed audit"))'
ASSERT = "-y @lhci/cli@0.15.1 assert --config=./config/lighthouserc.json"


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


def test_the_audit_step_may_fail_without_failing_the_job():
    assert _y(f'{AUDIT} | ."continue-on-error"') == "true"


def test_the_verdict_step_runs_only_after_a_failed_audit_and_reads_the_urls_through_env():
    assert _y(f"{VERDICT} | .if") == "steps.audit.outcome == 'failure'"
    assert _y(f"{VERDICT} | .env.URLS") == "${{ steps.reach.outputs.urls }}"
    assert "${{" not in _y(f"{VERDICT} | .run")


def _run_verdict(files, urls, npx_rc=0, assert_rc=None):
    script = _y(f"{VERDICT} | .run")
    with tempfile.TemporaryDirectory() as tmp:
        stub = pathlib.Path(tmp) / "npx"
        stub.write_text(
            '#!/bin/sh\n'
            'printf \'%s\\n\' "$*" >> "$NPX_LOG"\n'
            'rc=$NPX_RC; [ "$3" = assert ] && rc=$NPX_ASSERT_RC\n'
            'if [ "$rc" = 0 ] && [ "$3" = collect ]; then\n'
            '  for a in "$@"; do case $a in --numberOfRuns=*) k=${a#--numberOfRuns=};; --url=*) u=${a#--url=};; esac; done\n'
            '  n=$(ls .lighthouseci/lhr-*.json 2>/dev/null | wc -l)\n'
            '  i=1; while [ "$i" -le "$k" ]; do printf \'{"requestedUrl": "%s"}\\n\' "$u" > ".lighthouseci/lhr-$((n+i)).json"; i=$((i+1)); done\n'
            'fi\n'
            'exit "$rc"\n'
        )
        stub.chmod(0o755)
        lhci = pathlib.Path(tmp) / ".lighthouseci"
        lhci.mkdir()
        for name, body in files.items():
            (lhci / name).write_text(body)
        done = subprocess.run(
            ["bash", "-e", "-c", script],
            cwd=tmp,
            env=dict(
                os.environ,
                URLS=urls,
                NPX_LOG=str(pathlib.Path(tmp) / "npx.log"),
                NPX_RC=str(npx_rc),
                NPX_ASSERT_RC=str(npx_rc if assert_rc is None else assert_rc),
                PATH=f"{tmp}{os.pathsep}{os.environ['PATH']}",
            ),
            capture_output=True,
            text=True,
        )
        log = pathlib.Path(tmp) / "npx.log"
        calls = log.read_text() if log.exists() else ""
        return done.returncode, done.stdout + done.stderr, calls


def _lhrs(url, count, first=1):
    return {f"lhr-{i}.json": json.dumps({"requestedUrl": url}) for i in range(first, first + count)}


def test_the_verdict_expects_the_number_of_runs_the_audit_asks_for():
    run = _y(f"{VERDICT} | .run")
    assert f"want={_y(f'{AUDIT} | .with.runs')};" in run
    assert '[ "$have" -ge "$want" ]' in run


def test_a_reached_verdict_fails_the_run_and_points_at_the_step_that_says_why():
    breach = json.dumps(
        [{
            "passed": False,
            "level": "error",
            "url": "http://s/a",
            "auditId": "largest-contentful-paint",
            "operator": "<=",
            "expected": 1500,
            "actual": 3200,
        }]
    )
    code, logged, calls = _run_verdict({"assertion-results.json": breach}, "http://s/a\n")
    assert code != 0
    assert "::error::the audit reached a verdict, so this failure is not a lost trace" in logged
    assert calls == ""


def test_a_reached_verdict_fails_the_run_when_no_assertion_failed():
    upload_failure = json.dumps(
        [{
            "passed": True,
            "level": "error",
            "url": "http://s/a",
            "auditId": "largest-contentful-paint",
            "operator": "<=",
            "expected": 1500,
            "actual": 1200,
        }]
    )
    code, logged, calls = _run_verdict({"assertion-results.json": upload_failure}, "http://s/a\n")
    assert code != 0
    assert "the audit reached a verdict" in logged
    assert "of 5 runs" not in logged
    assert calls == ""


def test_a_page_that_recorded_every_run_is_not_collected_again():
    code, logged, calls = _run_verdict(_lhrs("http://s/a", 5), "http://s/a\n")
    assert code == 0
    assert "::warning::" not in logged
    assert calls == f"{ASSERT}\n"


def test_a_page_short_of_its_runs_is_recorded_up_to_the_count():
    code, logged, calls = _run_verdict(_lhrs("http://s/a", 2), "http://s/a\n")
    assert code == 0
    assert "::warning::http://s/a recorded 2 of 5 runs, so the missing ones are collected once more" in logged
    assert calls.splitlines() == [
        "-y @lhci/cli@0.15.1 collect --additive --numberOfRuns=3 --url=http://s/a --config=./config/lighthouserc.json",
        ASSERT,
    ]


def test_a_page_that_recorded_nothing_is_recorded_from_scratch():
    code, logged, calls = _run_verdict({}, "http://s/a\n")
    assert code == 0
    assert "::warning::http://s/a recorded 0 of 5 runs" in logged
    assert calls.splitlines() == [
        "-y @lhci/cli@0.15.1 collect --additive --numberOfRuns=5 --url=http://s/a --config=./config/lighthouserc.json",
        ASSERT,
    ]


def test_only_the_page_that_is_short_is_collected_again():
    page_a, page_b = _lhrs("http://s/a", 5), _lhrs("http://s/b", 1, first=6)
    code, logged, calls = _run_verdict({**page_a, **page_b}, "http://s/a\nhttp://s/b\n")
    assert code == 0
    assert logged.count("::warning::") == 1 and "http://s/b recorded 1 of 5 runs" in logged
    assert calls.splitlines() == [
        "-y @lhci/cli@0.15.1 collect --additive --numberOfRuns=4 --url=http://s/b --config=./config/lighthouserc.json",
        ASSERT,
    ]


def test_a_page_that_still_falls_short_has_no_verdict():
    code, logged, _calls = _run_verdict(_lhrs("http://s/a", 4), "http://s/a\n", npx_rc=1)
    assert code != 0
    assert "::error::http://s/a recorded 4 of 5 runs in two audits, so there is no verdict for it" in logged


def test_a_breach_the_re_collect_reaches_still_fails_the_run():
    code, logged, calls = _run_verdict(_lhrs("http://s/a", 4), "http://s/a\n", assert_rc=1)
    assert code != 0
    assert "http://s/a recorded 4 of 5 runs, so the missing ones are collected once more" in logged
    assert calls.splitlines() == [
        "-y @lhci/cli@0.15.1 collect --additive --numberOfRuns=1 --url=http://s/a --config=./config/lighthouserc.json",
        ASSERT,
    ]


def test_a_page_is_matched_regardless_of_a_trailing_slash():
    code, logged, calls = _run_verdict(_lhrs("http://s/a/", 5), "http://s/a\n")
    assert code == 0
    assert "::warning::" not in logged
    assert calls == f"{ASSERT}\n"
