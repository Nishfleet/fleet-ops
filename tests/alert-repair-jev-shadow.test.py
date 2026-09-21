#!/usr/bin/env python3
"""fleet-ops#7392: the alert-repair prompt carries the advisory Jev shadow tier
for the gha-stuck-run-watch site. Static prompt-contract assertions plus a
functional pass that runs the embedded block against three fixture logs with a
stub /jev endpoint. Run: python3 tests/alert-repair-jev-shadow.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'alert-repair.md'
FIXTURES = ROOT / 'tests' / 'fixtures'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"python3 - [^\n]*<<'PY'\n(.*?)\nPY\n", text, re.S)
    return m.group(1) if m else None


def main():
    text = PROMPT.read_text()

    check('## Shadow Jev tier — advisory, never a gate (fleet-ops#7392)' in text,
          'shadow section heading present')
    lines = text.splitlines()
    steps = next((i for i, l in enumerate(lines) if l.startswith('Steps:')), -1)
    shadow = next((i for i, l in enumerate(lines) if l.startswith('## Shadow Jev tier')), -1)
    check(0 <= steps < shadow, 'shadow section follows the steps list')
    check(shadow == max(i for i, l in enumerate(lines) if l.startswith('## ')),
          'shadow section is the last section')

    blocks = re.findall(r"<<'PY'\n", text)
    check(len(blocks) == 1, 'exactly one embedded python block, got %d' % len(blocks))
    block = extract_block(text)
    check(block is not None, 'block extracted')
    try:
        compile(block, 'jev-shadow-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_GHA_STUCK_RUN_WATCH', 'gha-stuck-run-watch',
                   'gha-stuck-run-watch.jsonl', '127.0.0.1:4000/jev',
                   'advisory_only=True', 'LITELLM_JEV_KEY',
                   "'runner-gone', 'concurrency-blocked', 'flaky', 'real'"):
        check(needle in text, 'prompt names %s' % needle)
    check("os.environ.get('JEV_GHA_STUCK_RUN_WATCH') == '0'" in block,
          'off-flag branch present')

    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'key variable never interpolated into a print call')

    class Stub(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7392':
                self.send_response(401); self.end_headers(); return
            out = json.dumps({'answers': {'failure_class': {
                                  'choice': 'flaky',
                                  'probabilities': {'runner-gone': 0.02, 'concurrency-blocked': 0.05,
                                                    'flaky': 0.83, 'real': 0.10}}},
                              'usage': {'total_tokens': 310}}).encode()
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
        logfile = pathlib.Path(td) / 'gha-stuck-run-watch.jsonl'

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7392',
                        JEV_GHA_STUCK_RUN_WATCH_ENDPOINT=endpoint,
                        JEV_GHA_STUCK_RUN_WATCH_LOG=str(logfile))
        base_env.pop('JEV_GHA_STUCK_RUN_WATCH', None)

        cases = [
            ('jev7392-runner-gone.log', 'SystemUnitFailed', 'pi-issue@fleet-ops-1.service', '-'),
            ('jev7392-concurrency-blocked.log', 'CiHostedQueueDepthHigh', '-', 'Nishfleet/0509'),
            ('jev7392-flaky.log', 'FleetMainRed', '-', '-'),
        ]
        for name, alertname, unit, repo in cases:
            env = dict(base_env, JEV_GHA_FIXTURE_LOG=str(FIXTURES / name))
            r = subprocess.run([sys.executable, str(blockfile), alertname, unit, repo],
                               capture_output=True, text=True, env=env, timeout=90)
            check(r.returncode == 0, 'fixture %s: exit 0 (stderr: %s)' % (name, r.stderr.strip()[:200]))
            check(re.search(r'^jev-class: flaky p=0\.830$', r.stdout.strip()), 
                  'fixture %s: stdout carries the jev-class line' % name)
            check('test-key-7392' not in r.stdout + r.stderr,
                  'fixture %s: key never printed' % name)

        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 3, 'three fixture rows appended, got %d' % len(rows))
        for i, row in enumerate(rows):
            check(row.get('site') == 'gha-stuck-run-watch', 'row %d site' % i)
            check(row.get('advisory_only') is True, 'row %d advisory_only' % i)
            check(row.get('rule_tier') == 'alert-repair', 'row %d rule_tier' % i)
            check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
                  'row %d state_sha256' % i)
            check((row.get('probabilities', {}).get('failure_class') or {}).get('flaky') == 0.83,
                  'row %d per-option probability' % i)
            check(row.get('evidence', {}).get('fixture') is True, 'row %d fixture flag' % i)
            check('test-key-7392' not in json.dumps(row), 'row %d carries no key' % i)
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'request model id')
        check('failure_class' in (Stub.last_body.get('questions') or {}), 'request question id')

        env = dict(base_env, JEV_GHA_STUCK_RUN_WATCH='0',
                   JEV_GHA_FIXTURE_LOG=str(FIXTURES / 'jev7392-flaky.log'))
        r = subprocess.run([sys.executable, str(blockfile), 'X', '-', '-'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'flag=0 disables and exits 0')
        check(len(logfile.read_text().splitlines()) == 3, 'flag=0 writes no row')

        env = dict(base_env, JEV_GHA_STUCK_RUN_WATCH_ENDPOINT='http://127.0.0.1:1/jev',
                   JEV_GHA_FIXTURE_LOG=str(FIXTURES / 'jev7392-flaky.log'))
        r = subprocess.run([sys.executable, str(blockfile), 'X', '-', '-'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'dead endpoint -> advisory unavailable, exit 0')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
