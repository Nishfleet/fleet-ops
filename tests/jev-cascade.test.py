#!/usr/bin/env python3
"""fleet-ops#7396: Jev cascade gating at the first two call sites —
bin/am-executor-claim (site alert-dispatch) and prompts/intake.md
(site intake-seat-smoke). Static contract assertions plus functional passes
of both embedded blocks against a stub /jev endpoint, and end-to-end runs of
the real bin. Run: python3 tests/jev-cascade.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
INTAKE = ROOT / 'prompts' / 'intake.md'
BIN = ROOT / 'bin' / 'am-executor-claim'
DOC = ROOT / 'docs' / 'jev-cascade.md'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_intake_block(text):
    m = re.search(r'python3 - "<seat>" "<repo>" "<issue>" <<\'PY\'\n(.*?)\nPY\n', text, re.S)
    return m.group(1) if m else None


def extract_bin_block(text):
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY", text, re.S)
    for b in blocks:
        if 'jev-cascade site=alert-dispatch' in b:
            return b
    return None


class JevStub(BaseHTTPRequestHandler):
    """Serves POST /jev (canned probability) and GET /metrics."""
    prob = 0.5
    hits = []
    metrics = ('litellm_deployment_state{litellm_model_name="worker-cheap",model_id="x"} 0.0\n'
               'litellm_deployment_state{litellm_model_name="worker-capable",model_id="y"} 2.0\n')

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        JevStub.hits.append(body)
        if self.headers.get('Authorization') != 'Bearer test-key-7396':
            self.send_response(401); self.end_headers(); return
        q = list((body.get('questions') or {}).keys())
        name = q[0] if q else 'q'
        out = json.dumps({'answers': {name: {'answer': JevStub.prob >= 0.5,
                                             'probability': JevStub.prob}},
                          'usage': {'total_tokens': 140}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        out = JevStub.metrics.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def run_block(block, argv, env):
    with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False) as f:
        f.write(block)
        path = f.name
    try:
        return subprocess.run(['python3', path] + argv,
                              capture_output=True, text=True, timeout=60, env=env)
    finally:
        os.unlink(path)


def main():
    text_i = INTAKE.read_text()
    text_b = BIN.read_text()
    text_d = DOC.read_text() if DOC.exists() else ''

    # ---- static contract -------------------------------------------------
    check('## Jev cascade — seat smoke (fleet-ops#7396)' in text_i,
          'intake.md carries the cascade section')
    check('smoke_will_pass' in text_i and 'intake-seat-smoke' in text_i,
          'intake.md names site + question')
    check('JEV_CASCADE_INTAKE_SMOKE' in text_i and 'JEV_CASCADE_LO' in text_i,
          'intake.md names the flag and band envs')
    check('Jev cascade block' in text_i or 'Jev cascade' in text_i.split('re-open')[0] + text_i,
          're-open bullet references the cascade')

    check('jev-cascade site=alert-dispatch' in text_b,
          'am-executor-claim carries the cascade gate')
    for needle in ('JEV_CASCADE_ALERT_DISPATCH', 'alert-dispatch.jsonl',
                   '127.0.0.1:4000/jev', 'needs_repair_session',
                   'NEVER_GATE_SEVERITIES', 'jev-cascade-skip'):
        check(needle in text_b, 'bin names %s' % needle)

    for needle in ('JEV_CASCADE', 'shadow', 'act', 'would_skip', 'skipped',
                   'alert-dispatch', 'intake-seat-smoke', '0.9', '0.1',
                   'never reached the big model'):
        check(needle in text_d, 'doc names %s' % needle)

    block_i = extract_intake_block(text_i)
    check(block_i is not None, 'intake block extracted')
    block_b = extract_bin_block(text_b)
    check(block_b is not None, 'bin block extracted')
    for name, block in (('intake', block_i), ('bin', block_b)):
        if block is None:
            continue
        try:
            compile(block, '%s-block' % name, 'exec')
            check(True, '%s embedded python compiles' % name)
        except SyntaxError as exc:
            check(False, '%s embedded python compiles (%s)' % (name, exc))
        for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'GH_TOKEN', 'TELEGRAM_BOT_TOKEN'):
            check(var not in block, '%s block never references %s' % (name, var))
        check(not re.search(r'print\([^)]*(?:\+\s*key\b|%\s*key\b|,\s*key\b|\{key)', block),
              '%s block never prints the key' % name)

    if block_i is None or block_b is None:
        print('FAIL: cannot continue functional passes without both blocks', file=sys.stderr)
        sys.exit(1)

    # ---- functional: intake-seat-smoke block ------------------------------
    srv = HTTPServer(('127.0.0.1', 0), JevStub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port
    metrics = 'http://127.0.0.1:%d/metrics' % srv.server_port

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        pi_stub = td / 'pi-stub'
        pi_stub.write_text('#!/bin/sh\necho smoke-ok\n')
        pi_stub.chmod(pi_stub.stat().st_mode | stat.S_IEXEC)
        pi_fail = td / 'pi-fail'
        pi_fail.write_text('#!/bin/sh\necho nope >&2\nexit 1\n')
        pi_fail.chmod(pi_fail.stat().st_mode | stat.S_IEXEC)
        log_i = td / 'intake-seat-smoke.jsonl'
        ran_marker = td / 'pi-ran'

        pi_marked = td / 'pi-marked'
        pi_marked.write_text('#!/bin/sh\ntouch "%s"\necho smoke-ok\n' % ran_marker)
        pi_marked.chmod(pi_marked.stat().st_mode | stat.S_IEXEC)

        base = dict(os.environ,
                    LITELLM_JEV_KEY='test-key-7396',
                    JEV_CASCADE_INTAKE_SMOKE_ENDPOINT=endpoint,
                    JEV_CASCADE_INTAKE_SMOKE_METRICS=metrics,
                    JEV_CASCADE_INTAKE_SMOKE_LOG=str(log_i),
                    JEV_CASCADE_INTAKE_SMOKE_PI=str(pi_marked),
                    JEV_CASCADE_INTAKE_SMOKE_TIMEOUT='10')
        base.pop('JEV_CASCADE', None)
        base.pop('JEV_CASCADE_INTAKE_SMOKE', None)

        def rows():
            if not log_i.exists():
                return []
            return [json.loads(l) for l in log_i.read_text().splitlines() if l.strip()]

        # shadow + mid band: Jev asked, probe still runs, row carries truth
        JevStub.prob = 0.5
        JevStub.hits.clear()
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], base)
        check(r.stdout.strip().endswith('smoke-ok'), 'shadow mid prints smoke-ok (%r)' % r.stdout)
        check(ran_marker.exists(), 'shadow mid ran the real probe')
        check(len(JevStub.hits) == 1, 'shadow mid made one Jev call')
        rs = rows()
        check(len(rs) == 1 and rs[0]['site'] == 'intake-seat-smoke'
              and rs[0]['band'] == 'mid' and rs[0]['skipped'] is False
              and rs[0]['would_skip'] is False and rs[0]['smoke_ok'] is True
              and rs[0]['advisory_only'] is True and rs[0]['mode'] == 'shadow',
              'shadow mid row shape %s' % (rs[-1] if rs else None))

        # shadow + hi band: would_skip but still probes (advisory by construction)
        JevStub.prob = 0.97
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], base)
        check(ran_marker.exists(), 'shadow hi still ran the real probe')
        rs = rows()
        check(rs and rs[-1]['band'] == 'hi' and rs[-1]['would_skip'] is True
              and rs[-1]['skipped'] is False, 'shadow hi row would_skip only')

        # act + hi: probe skipped, verdict pass
        env = dict(base, JEV_CASCADE_INTAKE_SMOKE='act')
        JevStub.prob = 0.97
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(not ran_marker.exists(), 'act hi skipped the real probe')
        check(r.stdout.strip().endswith('smoke-ok'), 'act hi verdict smoke-ok')
        rs = rows()
        check(rs and rs[-1]['skipped'] is True and rs[-1]['mode'] == 'act',
              'act hi row skipped=true')

        # act + lo: probe skipped, verdict fail
        JevStub.prob = 0.02
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(not ran_marker.exists(), 'act lo skipped the real probe')
        check(r.stdout.strip().endswith('smoke-fail'), 'act lo verdict smoke-fail')

        # act + mid: probe runs
        JevStub.prob = 0.5
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(ran_marker.exists(), 'act mid ran the real probe')

        # off: no Jev call, probe runs
        env = dict(base, JEV_CASCADE_INTAKE_SMOKE='0')
        JevStub.hits.clear()
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(len(JevStub.hits) == 0, 'off made no Jev call')
        check(ran_marker.exists(), 'off ran the real probe')

        # no key: probe runs (unavailable falls through)
        env = dict(base)
        env.pop('LITELLM_JEV_KEY', None)
        env['HOME'] = str(td / 'nohome')
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(ran_marker.exists(), 'no-key ran the real probe')
        check(r.stdout.strip().endswith('smoke-ok'), 'no-key still prints a verdict')

        # invalid probability: probe runs
        class BadStub(JevStub):
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                self.rfile.read(n)
                out = json.dumps({'answers': {'smoke_will_pass': {'probability': 'high'}}}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.end_headers(); self.wfile.write(out)
        srv2 = HTTPServer(('127.0.0.1', 0), BadStub)
        threading.Thread(target=srv2.serve_forever, daemon=True).start()
        env = dict(base, JEV_CASCADE_INTAKE_SMOKE='act',
                   JEV_CASCADE_INTAKE_SMOKE_ENDPOINT='http://127.0.0.1:%d/jev' % srv2.server_port)
        ran_marker.unlink(missing_ok=True)
        r = run_block(block_i, ['worker-cheap', 'fleet-ops', '7396'], env)
        check(ran_marker.exists(), 'invalid probability ran the real probe')
        srv2.shutdown()

        # failing seat: probe runs, verdict fail
        env = dict(base, JEV_CASCADE_INTAKE_SMOKE_PI=str(pi_fail))
        JevStub.prob = 0.5
        r = run_block(block_i, ['dead-seat', 'fleet-ops', '7396'], env)
        check(r.stdout.strip().endswith('smoke-fail'), 'dead seat prints smoke-fail')

    # ---- functional: bin gate end-to-end -----------------------------------
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        bindir = td / 'bin'
        bindir.mkdir()
        state = td / 'state'
        state.mkdir()
        log_b = td / 'alert-dispatch.jsonl'
        actions = td / 'actions.log'
        actions.write_text('')
        runs = td / 'runs'
        runs.write_text('')

        (bindir / 'systemctl').write_text('#!/bin/sh\nexit 0\n')
        (bindir / 'systemctl').chmod(0o755)
        stub = td / 'stub-repair'
        stub.write_text('#!/bin/sh\necho run >> "%s"\n' % runs)
        stub.chmod(0o755)

        def bin_env(extra):
            e = dict(os.environ)
            e.update(dict(HOME=str(td), PATH='%s:/usr/bin:/bin' % bindir,
                          ALERT_STATE_DIR=str(state),
                          SYSTEMCTL=str(bindir / 'systemctl'),
                          AM_EXECUTOR_CLAIM_UNIT='am-executor-claim-test',
                          LITELLM_JEV_KEY='test-key-7396',
                          JEV_CASCADE_ALERT_DISPATCH_ENDPOINT=endpoint,
                          JEV_CASCADE_ALERT_DISPATCH_LOG=str(log_b),
                          JEV_CASCADE_ALERT_DISPATCH_ACTIONS_LOG=str(actions)))
            e.pop('JEV_CASCADE', None)
            e.update(extra)
            return e

        payload = ('{"status":"firing","commonLabels":{"alertname":"FakeGauge","severity":"warning"},'
                   '"groupLabels":{"alertname":"FakeGauge"},'
                   '"alerts":[{"status":"firing","labels":{"alertname":"FakeGauge","severity":"warning"}}]}')

        def fire(env, pl=payload):
            return subprocess.run(['bash', str(BIN), str(stub)],
                                  input=pl, capture_output=True, text=True,
                                  timeout=60, env=env)

        def brows():
            if not log_b.exists():
                return []
            return [json.loads(l) for l in log_b.read_text().splitlines() if l.strip()]

        # act + confident-no: session never runs
        JevStub.prob = 0.02
        JevStub.hits.clear()
        runs.write_text('')
        r = fire(bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}))
        check(r.returncode == 0, 'act lo exit 0 (rc=%s %s)' % (r.returncode, r.stderr[-300:]))
        check(runs.read_text() == '', 'act lo skipped the repair session')
        check('jev-cascade-skip' in r.stderr, 'act lo logged the skip')
        rs = brows()
        check(len(rs) == 1 and rs[0]['site'] == 'alert-dispatch'
              and rs[0]['band'] == 'lo' and rs[0]['skipped'] is True
              and rs[0]['would_skip'] is True and rs[0]['mode'] == 'act',
              'act lo row shape %s' % (rs[-1] if rs else None))

        # act + mid: session runs
        JevStub.prob = 0.5
        runs.write_text('')
        r = fire(bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}))
        check(r.returncode == 0 and runs.read_text().strip() == 'run',
              'act mid ran the repair session')
        rs = brows()
        check(rs and rs[-1]['band'] == 'mid' and rs[-1]['skipped'] is False,
              'act mid row shape')

        # shadow + confident-no: session still runs, row projects the skip
        JevStub.prob = 0.02
        runs.write_text('')
        r = fire(bin_env({}))
        check(runs.read_text().strip() == 'run', 'shadow lo still ran the session')
        rs = brows()
        check(rs and rs[-1]['mode'] == 'shadow' and rs[-1]['would_skip'] is True
              and rs[-1]['skipped'] is False and rs[-1]['advisory_only'] is True,
              'shadow lo row shape')

        # boundary severity never gates, never even calls Jev
        nish_payload = ('{"status":"firing","commonLabels":{"alertname":"NishEscalation","severity":"nish"},'
                        '"alerts":[{"status":"firing","labels":{"alertname":"NishEscalation","severity":"nish"}}]}')
        JevStub.hits.clear()
        runs.write_text('')
        r = fire(bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}), pl=nish_payload)
        check(runs.read_text().strip() == 'run', 'severity=nish ran the session')
        check(len(JevStub.hits) == 0, 'severity=nish never called Jev')

        # off: no Jev call
        JevStub.hits.clear()
        runs.write_text('')
        r = fire(bin_env({'JEV_CASCADE_ALERT_DISPATCH': '0'}))
        check(len(JevStub.hits) == 0 and runs.read_text().strip() == 'run',
              'off: no call, session runs')

        # global flag reaches the site flag
        JevStub.prob = 0.02
        runs.write_text('')
        r = fire(bin_env({'JEV_CASCADE': 'act'}))
        check(runs.read_text() == '', 'global JEV_CASCADE=act also gates')

    srv.shutdown()
    if FAILS:
        print('\n%d failures' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('jev-cascade: all scenarios passed (fleet-ops#7396)')


if __name__ == '__main__':
    main()
