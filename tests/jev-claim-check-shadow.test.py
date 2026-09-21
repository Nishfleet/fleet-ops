#!/usr/bin/env python3
"""fleet-ops#7404: worker.md carries the advisory Jev claim-vs-evidence shadow
with two sites — claim-check-pr (the PR-body path at step 7) and
claim-check-report (the worker-report path at step 10). Static prompt-contract
assertions plus a functional pass that runs the embedded block against a stub
/jev endpoint with fixture evidence and a stubbed gh. Run:
python3 tests/jev-claim-check-shadow.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKER = ROOT / 'prompts' / 'worker.md'
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

    check('## Shadow Jev tier — claim-vs-evidence (fleet-ops#7404' in wtext,
          'worker.md: claim-check shadow section heading present')

    block = extract(wtext, '"<site>" "<repo>" "<issue>" "<pr-or-dash>"')
    check(block is not None, 'worker.md: claim-check block extracted')
    if block is None:
        print('FAILED: missing embedded block', file=sys.stderr)
        sys.exit(1)
    try:
        compile(block, 'worker.md-block', 'exec')
        check(True, 'worker.md: embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'worker.md: embedded python block compiles (%s)' % (tag, exc))
        return

    for needle in ('JEV_CLAIM_CHECK', 'claim-check-pr', 'claim-check-report',
                   'claim-check-pr.jsonl', 'claim-check-report.jsonl',
                   '127.0.0.1:4000/jev', 'advisory_only=True', 'LITELLM_JEV_KEY',
                   'claims_contradicted', 'typesafe-ai/jev', 'state_sha256',
                   'blocking=false', '100 labelled'):
        check(needle in wtext, 'worker.md names %s' % needle)
    check("os.environ.get('JEV_CLAIM_CHECK') == '0'" in block,
          'worker.md: off-flag branch present')
    static_secret_checks(block, 'worker.md')

    class Stub(BaseHTTPRequestHandler):
        prob = 0.42
        last_body = None

        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7404':
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
        bfile = td / 'claim-check-block.py'
        bfile.write_text(block)
        logdir = td / 'jev'
        prlog = logdir / 'claim-check-pr.jsonl'
        rplog = logdir / 'claim-check-report.jsonl'

        # A stub gh that records argv and succeeds; it MUST intercept the
        # `gh pr comment` the pr-site block posts. The fake repo arg makes a
        # real-gh escape a harmless failure anyway.
        bindir = td / 'bin'
        bindir.mkdir()
        ghlog = td / 'gh-calls.jsonl'
        gh = bindir / 'gh'
        gh.write_text('#!/usr/bin/env python3\n'
                      'import json, os, pathlib, sys\n'
                      'pathlib.Path(os.environ["GH_STUB_LOG"]).open("a").write(json.dumps(sys.argv[1:]) + "\\n")\n'
                      'print("[]" if "comments?" in " ".join(sys.argv[1:]) else "{}")\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7404',
                        GH_STUB_LOG=str(ghlog),
                        PATH='%s:%s' % (bindir, os.environ.get('PATH', '')))
        base_env.pop('JEV_CLAIM_CHECK', None)

        # --- pr site: happy path ---
        env = dict(base_env, JEV_CLAIM_CHECK_ENDPOINT=endpoint,
                   JEV_CLAIM_CHECK_LOG_DIR=str(logdir),
                   JEV_CC_FIXTURE_PR=str(FIXTURES / 'jev7404-pr.json'))
        r = subprocess.run([sys.executable, str(bfile), 'pr', 'Nishfleet/jev7404-nonexistent',
                            '7404', '999999'],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'pr site: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev claim-check: claims_contradicted=false p=0\.420',
                        r.stdout.strip(), re.M) is not None,
              'pr site: stdout carries the jev claim-check line (got %r)' % r.stdout.strip()[:200])
        check('test-key-7404' not in r.stdout + r.stderr, 'pr site: key never printed')

        rows = [json.loads(l) for l in prlog.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'pr site: one row appended, got %d' % len(rows))
        row = rows[0]
        check(row.get('site') == 'claim-check-pr', 'pr site: row site')
        check(row.get('advisory_only') is True, 'pr site: row advisory_only')
        check(row.get('rule_tier') == 'worker', 'pr site: row rule_tier')
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              'pr site: row state_sha256')
        check(row.get('probabilities', {}).get('claims_contradicted') == 0.42,
              'pr site: row probability')
        check(row.get('pr') == 999999 and row.get('issue') == 7404
              and row.get('repo') == 'Nishfleet/jev7404-nonexistent',
              'pr site: row repo/issue/pr')
        check(row.get('head_sha') == '0123456789abcdef0123456789abcdef01234567',
              'pr site: row head_sha from fixture')
        check('test-key-7404' not in json.dumps(row), 'pr site: row carries no key')
        check((Stub.last_body or {}).get('model') == 'typesafe-ai/jev',
              'pr site: request model id')
        check('claims_contradicted' in ((Stub.last_body or {}).get('questions') or {}),
              'pr site: request question id')
        check('Nishfleet/jev7404-nonexistent#999999@' in (row.get('ref') or ''),
              'pr site: ref names repo#pr@sha')
        check((Stub.last_body or {}).get('state', {}).get('evidence', {}).get('pr', {}).get('journal') == 'unknown',
              'pr site: unavailable journal marked unknown')
        check(len((Stub.last_body or {}).get('state', {}).get('claims') or []) >= 1,
              'pr site: claim lines extracted from the body')

        calls = [json.loads(l) for l in ghlog.read_text().splitlines() if l.strip()]
        commented = [c for c in calls if c[:2] == ['pr', 'comment']]
        check(len(commented) == 1, 'pr site: exactly one gh pr comment call, got %d' % len(commented))
        check(commented and any('jev claim-check:' in a for a in commented[0]),
              'pr site: comment body carries the jev claim-check line')

        # --- report site: happy path, PR delivered ---
        ghlog.write_text('')
        env = dict(base_env, JEV_CLAIM_CHECK_ENDPOINT=endpoint,
                   JEV_CLAIM_CHECK_LOG_DIR=str(logdir),
                   JEV_CC_FIXTURE_PR=str(FIXTURES / 'jev7404-pr.json'),
                   JEV_CC_FIXTURE_BRANCH=str(FIXTURES / 'jev7404-branch.json'),
                   JEV_CC_FIXTURE_PRS=str(FIXTURES / 'jev7404-prs.json'))
        r = subprocess.run([sys.executable, str(bfile), 'report', 'Nishfleet/jev7404-nonexistent',
                            '7404', '999999'],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'report site: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'site=claim-check-report', r.stdout.strip()) is not None,
              'report site: stdout line names claim-check-report')
        rows = [json.loads(l) for l in rplog.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'report site: one row appended, got %d' % len(rows))
        check(rows[0].get('site') == 'claim-check-report', 'report site: row site')
        check(rows[0].get('advisory_only') is True, 'report site: row advisory_only')
        calls = [json.loads(l) for l in ghlog.read_text().splitlines() if l.strip()]
        check(not [c for c in calls if c[:2] == ['pr', 'comment']],
              'report site: no gh pr comment call')
        st = (Stub.last_body or {}).get('state', {})
        check(any('PR #999999 delivered' in c for c in (st.get('claims') or [])),
              'report site: claim under test is the delivered-PR report')
        check(st.get('evidence', {}).get('claim_branch_exists') is True,
              'report site: claim branch existence re-derived')

        # --- report site: no-PR close ---
        r = subprocess.run([sys.executable, str(bfile), 'report', 'Nishfleet/jev7404-nonexistent',
                            '7404', '-'],
                           capture_output=True, text=True, env=env, timeout=90)
        check(r.returncode == 0, 'report no-pr: exit 0')
        rows = [json.loads(l) for l in rplog.read_text().splitlines() if l.strip()]
        check(len(rows) == 2, 'report no-pr: second row appended')
        check(rows[1].get('pr') is None and rows[1].get('ref') == 'Nishfleet/jev7404-nonexistent#7404',
              'report no-pr: ref falls back to the issue')
        st = (Stub.last_body or {}).get('state', {})
        check(any('no PR delivered' in c for c in (st.get('claims') or [])),
              'report no-pr: claim under test is the empty close')

        # --- off flag ---
        env = dict(env, JEV_CLAIM_CHECK='0')
        r = subprocess.run([sys.executable, str(bfile), 'pr', 'Nishfleet/jev7404-nonexistent',
                            '7404', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'flag=0 disables and exits 0')
        check(len(prlog.read_text().splitlines()) == 1, 'flag=0 writes no row')

        # --- dead endpoint ---
        env = dict(base_env, JEV_CLAIM_CHECK_ENDPOINT='http://127.0.0.1:1/jev',
                   JEV_CLAIM_CHECK_LOG_DIR=str(logdir),
                   JEV_CC_FIXTURE_PR=str(FIXTURES / 'jev7404-pr.json'))
        r = subprocess.run([sys.executable, str(bfile), 'pr', 'Nishfleet/jev7404-nonexistent',
                            '7404', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'dead endpoint -> advisory unavailable, exit 0')

        # --- invalid probability ---
        Stub.prob = 1.7
        env = dict(base_env, JEV_CLAIM_CHECK_ENDPOINT=endpoint,
                   JEV_CLAIM_CHECK_LOG_DIR=str(logdir),
                   JEV_CC_FIXTURE_PR=str(FIXTURES / 'jev7404-pr.json'))
        r = subprocess.run([sys.executable, str(bfile), 'pr', 'Nishfleet/jev7404-nonexistent',
                            '7404', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'invalid probability' in r.stdout,
              'invalid probability -> advisory unavailable, exit 0')
        Stub.prob = 0.42

        # --- bad args ---
        r = subprocess.run([sys.executable, str(bfile), 'bogus', 'not-a-repo', 'x', '1'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'bad args' in r.stdout,
              'bad args -> advisory unavailable, exit 0')
        r = subprocess.run([sys.executable, str(bfile), 'pr', 'Nishfleet/jev7404-nonexistent',
                            '7404', '-'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'bad args' in r.stdout,
              'pr site without a pr -> bad args, exit 0')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
