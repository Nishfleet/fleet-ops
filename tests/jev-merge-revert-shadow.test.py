#!/usr/bin/env python3
"""fleet-ops#7397: worker.md carries the advisory Jev shadow for the
merge-queue enqueue site and alert-repair.md carries the advisory Jev shadow
for the auto-revert (red-attribution) site. Static prompt-contract assertions
plus a functional pass that runs both embedded blocks against a stub /jev
endpoint with fixture evidence and a stubbed gh. Run:
python3 tests/jev-merge-revert-shadow.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKER = ROOT / 'prompts' / 'worker.md'
REPAIR = ROOT / 'prompts' / 'alert-repair.md'
FIXTURES = ROOT / 'tests' / 'fixtures'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract(text, argv_sig):
    m = re.search(re.escape('python3 - %s <<\'PY\'' % argv_sig) + r'\n(.*?)\nPY\n', text, re.S)
    return m.group(1) if m else None


def static_secret_checks(block, tag):
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, '%s: block never references %s' % (tag, var))
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          '%s: key reaches only the Authorization header' % tag)
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          '%s: key variable never interpolated into a print call' % tag)


def main():
    wtext = WORKER.read_text()
    rtext = REPAIR.read_text()

    check('## Shadow Jev tier — merge-queue enqueue risk (fleet-ops#7397' in wtext,
          'worker.md: enqueue shadow section heading present')
    check('## Shadow Jev tier — auto-revert attribution (fleet-ops#7397' in rtext,
          'alert-repair.md: auto-revert shadow section heading present')

    # The fleet-ops#7392 ordering invariant must still hold: every `## `
    # heading after the first shadow section is itself a shadow section.
    rlines = rtext.splitlines()
    first_shadow = next((i for i, l in enumerate(rlines) if l.startswith('## Shadow Jev tier')), -1)
    check(first_shadow >= 0, 'alert-repair.md: at least one shadow section')
    check(all(l.startswith('## Shadow Jev tier')
              for l in rlines[first_shadow:] if l.startswith('## ')),
          'alert-repair.md: only shadow sections follow the first shadow section')

    wblock = extract(wtext, '"<repo>" "<pr>"')
    rblock = extract(rtext, '"<alertname>" "<repo-or-dash>" "<disposition>"')
    check(wblock is not None, 'worker.md: enqueue block extracted')
    check(rblock is not None, 'alert-repair.md: auto-revert block extracted')
    if wblock is None or rblock is None:
        print('FAILED: missing embedded block', file=sys.stderr)
        sys.exit(1)
    for tag, block in (('worker.md', wblock), ('alert-repair.md', rblock)):
        try:
            compile(block, '%s-block' % tag, 'exec')
            check(True, '%s: embedded python block compiles' % tag)
        except SyntaxError as exc:
            check(False, '%s: embedded python block compiles (%s)' % (tag, exc))
            return

    for needle in ('JEV_MERGE_QUEUE_ENQUEUE', 'merge-queue-enqueue',
                   'merge-queue-enqueue.jsonl', '127.0.0.1:4000/jev',
                   'advisory_only=True', 'LITELLM_JEV_KEY', 'merge_risk',
                   'typesafe-ai/jev', 'gh', 'pr', 'comment'):
        check(needle in wtext, 'worker.md names %s' % needle)
    check("os.environ.get('JEV_MERGE_QUEUE_ENQUEUE') == '0'" in wblock,
          'worker.md: off-flag branch present')
    static_secret_checks(wblock, 'worker.md')

    for needle in ('JEV_AUTO_REVERT', 'auto-revert', 'auto-revert.jsonl',
                   'red_attributable_to_head_merge', 'rule_disposition',
                   'FleetMainRed', '127.0.0.1:4000/jev', 'advisory_only=True',
                   'LITELLM_JEV_KEY', 'typesafe-ai/jev'):
        check(needle in rtext, 'alert-repair.md names %s' % needle)
    check("os.environ.get('JEV_AUTO_REVERT') == '0'" in rblock,
          'alert-repair.md: off-flag branch present')
    static_secret_checks(rblock, 'alert-repair.md')

    class Stub(BaseHTTPRequestHandler):
        prob = 0.42
        last_body = None

        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7397':
                self.send_response(401); self.end_headers(); return
            answers = {}
            for qid in (body.get('questions') or {}):
                answers[qid] = {'type': 'boolean', 'probability': Stub.prob}
            out = json.dumps({'answers': answers,
                              'usage': {'total_tokens': 300}}).encode()
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
        td = pathlib.Path(td)
        wfile = td / 'enqueue-block.py'
        wfile.write_text(wblock)
        rfile = td / 'revert-block.py'
        rfile.write_text(rblock)
        wlog = td / 'merge-queue-enqueue.jsonl'
        rlog = td / 'auto-revert.jsonl'
        bands_file = td / 'jev-bands.json'
        bands_file.write_text(json.dumps({'sites': {
            'merge-queue-enqueue': {'act_hi': 0.9, 'review_lo': 0.1},
            'auto-revert': {'act_hi': 0.9, 'review_lo': 0.1}}}))

        # A stub gh that records argv and succeeds; it MUST intercept the
        # `gh pr comment` the enqueue block posts. The fake repo arg makes a
        # real-gh escape a harmless 404 anyway.
        bindir = td / 'bin'
        bindir.mkdir()
        ghlog = td / 'gh-calls.jsonl'
        gh = bindir / 'gh'
        gh.write_text('#!/usr/bin/env python3\n'
                      'import json, os, pathlib, sys\n'
                      'pathlib.Path(os.environ["GH_STUB_LOG"]).open("a").write(json.dumps(sys.argv[1:]) + "\\n")\n'
                      'print("{}")\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7397',
                        GH_STUB_LOG=str(ghlog),
                        JEV_BANDS_FILE=str(bands_file),
                        PATH='%s:%s' % (bindir, os.environ.get('PATH', '')))
        for v in ('JEV_MERGE_QUEUE_ENQUEUE', 'JEV_AUTO_REVERT'):
            base_env.pop(v, None)

        # --- enqueue site: happy path ---
        env = dict(base_env, JEV_MQE_ENDPOINT=endpoint, JEV_MQE_LOG=str(wlog),
                   JEV_MQE_FIXTURE_PR=str(FIXTURES / 'jev7397-pr.json'))
        r = subprocess.run([sys.executable, str(wfile), 'Nishfleet/jev7397-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'enqueue: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev-risk: p=0\.420', r.stdout.strip(), re.M) is not None,
              'enqueue: stdout carries the jev-risk line (got %r)' % r.stdout.strip()[:200])
        check('test-key-7397' not in r.stdout + r.stderr, 'enqueue: key never printed')

        rows = [json.loads(l) for l in wlog.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'enqueue: one row appended, got %d' % len(rows))
        row = rows[0]
        check(row.get('site') == 'merge-queue-enqueue', 'enqueue: row site')
        check(row.get('advisory_only') is True, 'enqueue: row advisory_only')
        check(row.get('rule_tier') == 'worker-arm', 'enqueue: row rule_tier')
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              'enqueue: row state_sha256')
        check(row.get('probabilities', {}).get('merge_risk') == 0.42, 'enqueue: row probability')
        check(row.get('pr') == 999999 and row.get('repo') == 'Nishfleet/jev7397-nonexistent',
              'enqueue: row repo/pr')
        check(row.get('head_sha') == '0123456789abcdef0123456789abcdef01234567',
              'enqueue: row head_sha from fixture')
        check(row.get('act_hi') == 0.9 and row.get('review_lo') == 0.1,
              'enqueue: row stamps the site band edges from the table')
        check('test-key-7397' not in json.dumps(row), 'enqueue: row carries no key')
        check((Stub.last_body or {}).get('model') == 'typesafe-ai/jev', 'enqueue: request model id')
        check('merge_risk' in ((Stub.last_body or {}).get('questions') or {}),
              'enqueue: request question id')
        check('Nishfleet/jev7397-nonexistent#999999@' in (row.get('ref') or ''),
              'enqueue: ref names repo#pr@sha')

        calls = [json.loads(l) for l in ghlog.read_text().splitlines() if l.strip()]
        commented = [c for c in calls if c[:2] == ['pr', 'comment']]
        check(len(commented) == 1, 'enqueue: exactly one gh pr comment call, got %d' % len(commented))
        check(commented and any('jev-risk: p=0.420' in a for a in commented[0]),
              'enqueue: comment body carries the jev-risk line')

        # --- enqueue site: off flag ---
        env = dict(env, JEV_MERGE_QUEUE_ENQUEUE='0')
        r = subprocess.run([sys.executable, str(wfile), 'Nishfleet/jev7397-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'enqueue: flag=0 disables and exits 0')
        check(len(wlog.read_text().splitlines()) == 1, 'enqueue: flag=0 writes no row')

        # --- enqueue site: dead endpoint ---
        env = dict(base_env, JEV_MQE_ENDPOINT='http://127.0.0.1:1/jev',
                   JEV_MQE_LOG=str(wlog), JEV_MQE_FIXTURE_PR=str(FIXTURES / 'jev7397-pr.json'))
        r = subprocess.run([sys.executable, str(wfile), 'Nishfleet/jev7397-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'enqueue: dead endpoint -> advisory unavailable, exit 0')

        # --- enqueue site: invalid probability ---
        Stub.prob = 1.7
        env = dict(base_env, JEV_MQE_ENDPOINT=endpoint, JEV_MQE_LOG=str(wlog),
                   JEV_MQE_FIXTURE_PR=str(FIXTURES / 'jev7397-pr.json'))
        r = subprocess.run([sys.executable, str(wfile), 'Nishfleet/jev7397-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'invalid probability' in r.stdout,
              'enqueue: invalid probability -> advisory unavailable, exit 0')
        Stub.prob = 0.87

        # --- auto-revert site: happy path ---
        env = dict(base_env, JEV_AR_ENDPOINT=endpoint, JEV_AR_LOG=str(rlog),
                   JEV_AR_FIXTURE_RUNS=str(FIXTURES / 'jev7397-runs.json'),
                   JEV_AR_FIXTURE_COMMIT=str(FIXTURES / 'jev7397-commit.json'),
                   JEV_AR_FIXTURE_ALERT=str(FIXTURES / 'jev7397-alert.json'))
        r = subprocess.run([sys.executable, str(rfile), 'FleetMainRed',
                            'Nishfleet/jev7397-nonexistent', 'reverted'],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'auto-revert: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev-attribution: p=0\.870', r.stdout.strip(), re.M) is not None,
              'auto-revert: stdout carries the jev-attribution line (got %r)' % r.stdout.strip()[:200])
        check('test-key-7397' not in r.stdout + r.stderr, 'auto-revert: key never printed')

        rows = [json.loads(l) for l in rlog.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'auto-revert: one row appended, got %d' % len(rows))
        row = rows[0]
        check(row.get('site') == 'auto-revert', 'auto-revert: row site')
        check(row.get('advisory_only') is True, 'auto-revert: row advisory_only')
        check(row.get('rule_tier') == 'alert-repair', 'auto-revert: row rule_tier')
        check(row.get('rule_disposition') == 'reverted',
              'auto-revert: row carries the packet disposition beside the score')
        check(row.get('probabilities', {}).get('red_attributable_to_head_merge') == 0.87,
              'auto-revert: row probability')
        check(row.get('head_sha') == 'deadbeefcafebabe0123456789abcdef01234567',
              'auto-revert: row head_sha from fixture')
        check(row.get('failing_run_id') == 9901, 'auto-revert: row failing run id')
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              'auto-revert: row state_sha256')
        check(row.get('act_hi') == 0.9 and row.get('review_lo') == 0.1,
              'auto-revert: row stamps the site band edges from the table')
        check('test-key-7397' not in json.dumps(row), 'auto-revert: row carries no key')
        check('red_attributable_to_head_merge' in ((Stub.last_body or {}).get('questions') or {}),
              'auto-revert: request question id')

        # --- auto-revert site: off flag ---
        env = dict(env, JEV_AUTO_REVERT='0')
        r = subprocess.run([sys.executable, str(rfile), 'FleetMainRed',
                            'Nishfleet/jev7397-nonexistent', 'reverted'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'auto-revert: flag=0 disables and exits 0')
        check(len(rlog.read_text().splitlines()) == 1, 'auto-revert: flag=0 writes no row')

        # --- auto-revert site: bad repo arg is refused ---
        env = dict(base_env, JEV_AR_ENDPOINT=endpoint, JEV_AR_LOG=str(rlog),
                   JEV_AR_FIXTURE_RUNS=str(FIXTURES / 'jev7397-runs.json'),
                   JEV_AR_FIXTURE_COMMIT=str(FIXTURES / 'jev7397-commit.json'),
                   JEV_AR_FIXTURE_ALERT=str(FIXTURES / 'jev7397-alert.json'))
        r = subprocess.run([sys.executable, str(rfile), 'FleetMainRed', 'not-a-repo', 'filed'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'bad args' in r.stdout,
              'auto-revert: bad repo arg -> advisory unavailable, exit 0')

        # --- auto-revert site: dead endpoint ---
        env = dict(env, JEV_AR_ENDPOINT='http://127.0.0.1:1/jev')
        r = subprocess.run([sys.executable, str(rfile), 'FleetMainRed',
                            'Nishfleet/jev7397-nonexistent', 'filed'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'auto-revert: dead endpoint -> advisory unavailable, exit 0')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
