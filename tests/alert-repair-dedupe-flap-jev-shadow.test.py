#!/usr/bin/env python3
"""fleet-ops#7394: the alert-repair prompt carries the advisory Jev shadow tier
for the alert-repair dedupe/flap site. Static prompt-contract assertions plus a
functional pass that runs the embedded block against a stub /jev endpoint and a
fixture actions.log. Run: python3 tests/alert-repair-dedupe-flap-jev-shadow.test.py
"""
import datetime, json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'alert-repair.md'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"python3 - <<'PY'\n(.*?)\nPY\n", text, re.S)
    return m.group(1) if m else None


def main():
    text = PROMPT.read_text()

    check('## Shadow Jev tier — advisory, never a gate (fleet-ops#7394)' in text,
          'shadow section heading present')
    lines = text.splitlines()
    steps = next((i for i, l in enumerate(lines) if l.startswith('Steps:')), -1)
    shadow = next((i for i, l in enumerate(lines)
                   if l.startswith('## Shadow Jev tier — advisory, never a gate (fleet-ops#7394)')), -1)
    check(0 <= steps < shadow, 'shadow section follows the steps list')
    check(not any(l.startswith('## ') for l in lines[shadow + 1:]),
          'shadow section is the last section')

    blocks = re.findall(r"python3 - <<'PY'\n", text)
    check(len(blocks) == 1, 'exactly one embedded python block for this site, got %d' % len(blocks))
    block = extract_block(text)
    check(block is not None, 'block extracted')
    try:
        compile(block, 'jev-shadow-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_ALERT_REPAIR', 'alert-repair.jsonl',
                   "site='alert-repair'", '127.0.0.1:4000/jev',
                   'advisory_only=True', 'rule_disposition', 'duplicate_of',
                   'flap', 'advice only, never a gate',
                   'agent-state/alert-repair/actions.log', 'search/issues',
                   'alertname=%s'):
        check(needle in text, 'prompt names %s' % needle)
    check("os.environ.get('JEV_ALERT_REPAIR') == '0'" in block,
          'off-flag branch present')
    check(block.count('advisory unavailable') >= 5,
          'every failure path is fail-open (%d)' % block.count('advisory unavailable'))
    check('Print what you did in one short block' in text, 'summary step intact')
    check('amtool alert add alertname=NishEscalation' in text, 'boundary path intact')

    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TYPESAFE_API_KEY', 'GH_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|log)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'key variable never interpolated into a print/log call')

    class Stub(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7394':
                self.send_response(401); self.end_headers(); return
            if Stub.mode == 'invalid':
                answers = {'a0_class': {'type': 'choice', 'choice': 'file_issue',
                                        'probabilities': {'file_issue': 1.7}},
                           'a0_duplicate_of': {'type': 'boolean', 'probability': 0.5},
                           'a0_flap': {'type': 'boolean', 'probability': 0.5}}
            else:
                answers = {'a0_class': {'type': 'choice', 'choice': 'file_issue',
                                        'probabilities': {'repair_in_place': 0.09, 'file_issue': 0.9,
                                                          'nish_boundary': 0.0, 'no_action': 0.01}},
                           'a0_duplicate_of': {'type': 'boolean', 'probability': 0.76},
                           'a0_flap': {'type': 'boolean', 'probability': 0.53}}
            out = json.dumps({'answers': answers,
                              'usage': {'inputTokens': 700, 'outputTokens': 90}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    Stub.mode = 'ok'
    srv = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        blockfile = td / 'block.py'
        blockfile.write_text(block)
        meta = td / 'meta.json'
        meta.write_text(json.dumps([{'alertname': 'DetachedJobDied', 'severity': 'warning',
                                     'status': 'firing', 'instance': '', 'disposition': 'filed'}]))
        logfile = td / 'alert-repair.jsonl'
        # Fixture actions.log: two in-window events for the alertname, one old,
        # one for a different alertname.
        now = datetime.datetime.now(datetime.timezone.utc)
        def iso(**kw):
            return (now - datetime.timedelta(**kw)).strftime('%Y-%m-%dT%H:%M:%SZ')
        (td / 'actions.log').write_text(
            '[%s] DISPATCH alertname=DetachedJobDied unit=u seat=s reason=r\n'
            '[%s] SKIP alertname=DetachedJobDied reason=cooldown\n'
            '[%s] DISPATCH alertname=DetachedJobDied unit=u seat=s reason=r\n'
            '[%s] DISPATCH alertname=OtherAlert unit=u seat=s reason=r\n'
            % (iso(hours=1), iso(days=2), iso(days=30), iso(hours=1)))

        env = dict(os.environ,
                   LITELLM_JEV_KEY='test-key-7394',
                   JEV_ALERT_REPAIR_ENDPOINT=endpoint,
                   JEV_ALERT_REPAIR_META=str(meta),
                   JEV_ALERT_REPAIR_LOG=str(logfile),
                   JEV_ALERT_REPAIR_ACTIONS_LOG=str(td / 'actions.log'))
        env.pop('JEV_ALERT_REPAIR', None)

        r = subprocess.run([sys.executable, str(blockfile)],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'happy path: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check('jev advisory logged n=1' in r.stderr, 'happy path: logged line')
        check('test-key-7394' not in r.stdout + r.stderr, 'key never printed')

        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'one row appended, got %d' % len(rows))
        row = rows[0]
        check(row.get('site') == 'alert-repair', 'row site')
        check(row.get('advisory_only') is True, 'row advisory_only')
        check(row.get('rule_disposition') == 'filed', 'row carries rule disposition')
        check(row.get('item') == 'DetachedJobDied', 'row item is the alertname')
        check((row.get('ref') or '').endswith('#DetachedJobDied'), 'row ref names the alert')
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              'row state_sha256')
        probs = row.get('probabilities', {})
        check((probs.get('class') or {}).get('file_issue') == 0.9, 'row class probabilities')
        check(probs.get('duplicate_of') == 0.76, 'row duplicate_of p')
        check(probs.get('flap') == 0.53, 'row flap p')
        check('test-key-7394' not in json.dumps(row), 'row carries no key')
        check(not meta.exists(), 'meta temp file cleaned up')

        body = Stub.last_body or {}
        check(body.get('model') == 'typesafe-ai/jev', 'request model id')
        qs = body.get('questions') or {}
        check('a0_class' in qs and 'a0_duplicate_of' in qs and 'a0_flap' in qs,
              'request carries the three issue questions')
        st = (body.get('state') or {}).get('alerts') or [{}]
        check(st[0].get('prior_dispatch_events_7d') == 2, 'self-derived 7d dispatch count')
        check(st[0].get('prior_dispatch_events_24h') == 1, 'self-derived 24h dispatch count')
        check('open_issues_same_alertname' in st[0], 'open-issue field present (value may be withheld)')

        env_off = dict(env, JEV_ALERT_REPAIR='0')
        meta.write_text(json.dumps([{'alertname': 'DetachedJobDied', 'disposition': 'filed'}]))
        r = subprocess.run([sys.executable, str(blockfile)],
                           capture_output=True, text=True, env=env_off, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stderr,
              'flag=0 disables and exits 0')
        check(len(logfile.read_text().splitlines()) == 1, 'flag=0 writes no row')

        env_dead = dict(env, JEV_ALERT_REPAIR_ENDPOINT='http://127.0.0.1:1/jev')
        meta.write_text(json.dumps([{'alertname': 'DetachedJobDied', 'disposition': 'filed'}]))
        r = subprocess.run([sys.executable, str(blockfile)],
                           capture_output=True, text=True, env=env_dead, timeout=60)
        check(r.returncode == 0 and 'advisory unavailable' in r.stderr,
              'dead endpoint -> advisory unavailable, exit 0')

        Stub.mode = 'invalid'
        meta.write_text(json.dumps([{'alertname': 'DetachedJobDied', 'disposition': 'filed'}]))
        r = subprocess.run([sys.executable, str(blockfile)],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'advisory unavailable' in r.stderr,
              'invalid probability -> advisory unavailable, exit 0')
        check(len(logfile.read_text().splitlines()) == 1, 'invalid answer writes no row')
        Stub.mode = 'ok'

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
