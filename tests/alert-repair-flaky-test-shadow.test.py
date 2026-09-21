#!/usr/bin/env python3
"""fleet-ops#7424: the alert-repair prompt carries the advisory Jev shadow tier
for per-test flakiness (site `flaky-test-quarantine`). Each failing test is shown
its last <=20 recorded outcomes plus whether the diff touches it, and Jev answers
a per-test flaky probability. Static prompt-contract assertions plus a functional
pass that runs the embedded block against a stub /jev endpoint and fixture run
history. Run: python3 tests/alert-repair-flaky-test-shadow.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'alert-repair.md'
FIXTURES = ROOT / 'tests' / 'fixtures'
HEADING = '## Shadow Jev tier \u2014 per-test flakiness, advisory, never a gate (fleet-ops#7424)'
ARGS = 'python3 - "<alertname>" "<repo-or-dash>" "<run-id-or-dash>" <<\'PY\'\n'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(re.escape(ARGS) + r'(.*?)\nPY\n', text, re.S)
    return m.group(1) if m else None


def main():
    text = PROMPT.read_text()

    check(HEADING in text, 'shadow section heading present')
    lines = text.splitlines()
    steps = next((i for i, l in enumerate(lines) if l.startswith('Steps:')), -1)
    shadow = next((i for i, l in enumerate(lines) if l.startswith(HEADING)), -1)
    check(0 <= steps < shadow, 'shadow section follows the steps list')

    blocks = re.findall(re.escape(ARGS), text)
    check(len(blocks) == 1, 'exactly one embedded python block for this site, got %d' % len(blocks))
    block = extract_block(text)
    check(block is not None, 'block extracted')
    try:
        compile(block, 'jev-flaky-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_FLAKY_TEST_QUARANTINE', 'flaky-test-quarantine.jsonl',
                   "site=flaky-test-quarantine", '127.0.0.1:4000/jev',
                   'advisory_only', 'last 20 recorded outcomes', 'diff touch',
                   'jev-flaky:', '--log-failed', 'gh run list',
                   '100 real failures', 'no synthetic', 'targeted retry',
                   'typesafe-jev.env', 'advisory, never a gate'):
        check(needle in text, 'prompt names %s' % needle)
    check("os.environ.get('JEV_FLAKY_TEST_QUARANTINE') == '0'" in block,
          'off-flag branch present')
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'key variable never interpolated into a print call')

    class Stub(BaseHTTPRequestHandler):
        calls = 0

        def do_POST(self):
            Stub.calls += 1
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7424':
                self.send_response(401)
                self.end_headers()
                return
            ans = {}
            for i, p in enumerate((0.83, 0.12, 0.05)):
                ans['t%d_flaky' % i] = {'type': 'boolean', 'probability': p}
            out = json.dumps({'answers': ans, 'usage': {'total_tokens': 210}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    with tempfile.TemporaryDirectory() as td:
        blockfile = pathlib.Path(td) / 'block.py'
        blockfile.write_text(block)
        logfile = pathlib.Path(td) / 'flaky-test-quarantine.jsonl'

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7424',
                        JEV_FLAKY_TEST_QUARANTINE_ENDPOINT=endpoint,
                        JEV_FLAKY_TEST_QUARANTINE_LOG=str(logfile),
                        JEV_FLAKY_FIXTURE_LOGS=str(FIXTURES / 'jev7424-logs'),
                        JEV_FLAKY_FIXTURE_DIFF=str(FIXTURES / 'jev7424-diff.json'))
        base_env.pop('JEV_FLAKY_TEST_QUARANTINE', None)

        def invoke(env, args=('FleetMainRed', 'Nishfleet/fleet-ops', '-')):
            return subprocess.run([sys.executable, str(blockfile), *args],
                                  capture_output=True, text=True, env=env, timeout=90)

        # Target = newest failing run (9004) from the fixture history.
        env = dict(base_env, JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs.json'))
        r = invoke(env)
        check(r.returncode == 0, 'main: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(Stub.calls == 1, 'main: exactly one /jev call, got %d' % Stub.calls)
        check(re.search(r'^jev-flaky: tests/foo\.test\.ts > suite > alpha adds p=0\.830$',
                        r.stdout, re.M) is not None, 'main: alpha flaky line')
        check(re.search(r'^jev-flaky: suite > beta subtracts p=0\.120$', r.stdout, re.M) is not None,
              'main: beta flaky line')
        check(re.search(r'^jev-flaky: tests/test_bar\.py::test_gamma p=0\.050$', r.stdout, re.M) is not None,
              'main: gamma flaky line')
        check('test-key-7424' not in r.stdout + r.stderr, 'main: key never printed')

        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 3, 'main: three rows appended, got %d' % len(rows))
        by_test = {row.get('test'): row for row in rows}
        alpha = by_test.get('tests/foo.test.ts > suite > alpha adds') or {}
        check(alpha.get('site') == 'flaky-test-quarantine', 'row site')
        check(alpha.get('advisory_only') is True, 'row advisory_only')
        check(alpha.get('rule_tier') == 'alert-repair', 'row rule_tier')
        check(re.match(r'^[0-9a-f]{64}$', alpha.get('state_sha256') or '') is not None,
              'row state_sha256')
        check(alpha.get('probabilities', {}).get('flaky') == 0.83, 'row per-test probability')
        check(alpha.get('last_20_outcomes') == ['pass', 'fail', 'pass', 'fail'],
              'row recorded outcomes, oldest to newest (got %s)' % alpha.get('last_20_outcomes'))
        check(alpha.get('diff_touches_test') is True, 'row diff touch true')
        check(alpha.get('test_file') == 'tests/foo.test.ts', 'row test file')
        check(by_test.get('tests/test_bar.py::test_gamma', {}).get('diff_touches_test') is False,
              'row diff touch false for untouched test')
        check(all('test-key-7424' not in json.dumps(row) for row in rows), 'rows carry no key')
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'request model id')
        qs = Stub.last_body.get('questions') or {}
        check(set(qs) == {'t0_flaky', 't1_flaky', 't2_flaky'}, 'request one boolean per test')
        check(qs.get('t0_flaky', {}).get('type') == 'boolean', 'question type boolean')
        check('pass' in json.dumps(qs.get('t0_flaky', {}).get('instructions', '')),
              'question carries the recorded outcomes')

        # An explicit older run id: history stops at that run, never leaks the future.
        logfile.write_text('')
        env = dict(base_env, JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs.json'))
        r = invoke(env, ('FleetMainRed', 'Nishfleet/fleet-ops', '9002'))
        check(r.returncode == 0, 'run-id: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev-flaky: tests/foo\.test\.ts > suite > alpha adds p=0\.830$',
                        r.stdout, re.M) is not None, 'run-id: alpha flaky line')
        check('beta subtracts' not in r.stdout, 'run-id: only the tests in that run')
        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'run-id: one row, got %d' % len(rows))
        check(rows[0].get('last_20_outcomes') == ['pass', 'fail'],
              'run-id: outcomes end at the target run (got %s)' % rows[0].get('last_20_outcomes'))

        # A failing run whose log names no test (build/runner failure): no advice, no row.
        logfile.write_text('')
        env = dict(base_env, JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs-nosig.json'))
        r = invoke(env)
        check(r.returncode == 0 and 'no failing test signature' in r.stdout,
              'no-signature: exits 0 with a clear line')
        check(logfile.read_text().strip() == '', 'no-signature: writes no row')

        # Invalid probability from Jev: fail open, no partial row.
        logfile.write_text('')
        class BadStub(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                self.rfile.read(n)
                out = json.dumps({'answers': {'t0_flaky': {'type': 'boolean', 'probability': 7}},
                                  'usage': {}}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        bad = HTTPServer(('127.0.0.1', 0), BadStub)
        threading.Thread(target=bad.serve_forever, daemon=True).start()
        env = dict(base_env, JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs.json'),
                   JEV_FLAKY_TEST_QUARANTINE_ENDPOINT='http://127.0.0.1:%d/jev' % bad.server_port)
        r = invoke(env)
        check(r.returncode == 0 and 'invalid probability' in r.stdout,
              'invalid probability -> advisory unavailable, exit 0')
        check(logfile.read_text().strip() == '', 'invalid probability writes no row')
        bad.shutdown()

        # Flag off.
        env = dict(base_env, JEV_FLAKY_TEST_QUARANTINE='0',
                   JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs.json'))
        before = Stub.calls
        r = invoke(env)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'flag=0 disables and exits 0')
        check(Stub.calls == before, 'flag=0 makes no /jev call')

        # Dead endpoint.
        env = dict(base_env, JEV_FLAKY_FIXTURE_RUNS=str(FIXTURES / 'jev7424-runs.json'),
                   JEV_FLAKY_TEST_QUARANTINE_ENDPOINT='http://127.0.0.1:1/jev')
        r = invoke(env)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'dead endpoint -> advisory unavailable, exit 0')

        # Bad args.
        r = invoke(base_env, ('not a name', 'nope', '-'))
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'bad args -> advisory unavailable, exit 0')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
