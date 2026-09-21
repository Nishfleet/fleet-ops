#!/usr/bin/env python3
"""fleet-ops#7459: worker.md carries the advisory Jev shadow for the
dependency-PR arm site (dependabot/lockfile PRs at the step-9 auto-merge arm).
Static prompt-contract assertions plus a functional pass that runs the
embedded block against a stub /jev endpoint with fixture evidence and a
stubbed gh. Run:
python3 tests/jev-dep-pr-shadow.test.py
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


def extract(text):
    m = re.search(re.escape('python3 - "<repo>" "<pr>" <<\'PY_DEP\'')
                  + r'\n(.*?)\nPY_DEP\n', text, re.S)
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

    check('## Shadow Jev tier — dependency PR arm risk (fleet-ops#7459' in wtext,
          'worker.md: dependency-PR shadow section heading present')

    block = extract(wtext)
    check(block is not None, 'worker.md: dep-pr block extracted')
    if block is None:
        print('FAILED: missing embedded block', file=sys.stderr)
        sys.exit(1)
    try:
        compile(block, 'worker.md-block', 'exec')
        check(True, 'worker.md: embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'worker.md: embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_DEP_PR_ARM', 'dependency-pr-arm', 'dependency-pr-arm.jsonl',
                   '127.0.0.1:4000/jev', 'advisory_only=True', 'LITELLM_JEV_KEY',
                   'breaking', 'security_fix', 'safe_auto_merge', 'typesafe-ai/jev',
                   'jev-deps:', 'state_sha256', 'changelog', 'semver', 'lockfile',
                   'app/dependabot', 'gh', 'pr', 'comment'):
        check(needle in wtext, 'worker.md names %s' % needle)
    check("os.environ.get('JEV_DEP_PR_ARM') == '0'" in block,
          'worker.md: off-flag branch present')
    static_secret_checks(block, 'worker.md')

    class Stub(BaseHTTPRequestHandler):
        prob = 0.42
        last_body = None
        posts = 0

        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            Stub.posts += 1
            if self.headers.get('Authorization') != 'Bearer test-key-7459':
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
        bfile = td / 'dep-pr-block.py'
        bfile.write_text(block)
        log = td / 'dependency-pr-arm.jsonl'

        # A stub gh that records argv and succeeds; it MUST intercept the
        # `gh api .../comments` dedupe read and the `gh pr comment` post. The
        # fake repo arg makes a real-gh escape a harmless 404 anyway.
        bindir = td / 'bin'
        bindir.mkdir()
        ghlog = td / 'gh-calls.jsonl'
        gh = bindir / 'gh'
        gh_comments = td / 'gh-comments.json'
        gh_comments.write_text('[]')
        gh.write_text('#!/usr/bin/env python3\n'
                      'import json, os, pathlib, sys\n'
                      'pathlib.Path(os.environ["GH_STUB_LOG"]).open("a").write(json.dumps(sys.argv[1:]) + "\\n")\n'
                      'if len(sys.argv) > 1 and sys.argv[1] == "api":\n'
                      '    print(pathlib.Path(os.environ["GH_STUB_COMMENTS"]).read_text())\n'
                      'else:\n'
                      '    print("{}")\n')
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7459',
                        GH_STUB_LOG=str(ghlog),
                        GH_STUB_COMMENTS=str(gh_comments),
                        PATH='%s:%s' % (bindir, os.environ.get('PATH', '')))
        base_env.pop('JEV_DEP_PR_ARM', None)

        dep_env = dict(base_env, JEV_DEP_PR_ARM_ENDPOINT=endpoint,
                       JEV_DEP_PR_ARM_LOG=str(log),
                       JEV_DEP_PR_ARM_FIXTURE_PR=str(FIXTURES / 'jev7459-pr.json'),
                       JEV_DEP_PR_ARM_FIXTURE_DIFF=str(FIXTURES / 'jev7459-diff.txt'))

        # --- happy path: dependabot-shaped PR ---
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '999999'],
                           capture_output=True, text=True, env=dep_env, timeout=90)
        check(r.returncode == 0, 'dep-pr: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev-deps: breaking=p=0\.420 security_fix=p=0\.420 '
                        r'safe_auto_merge=p=0\.420', r.stdout.strip(), re.M) is not None,
              'dep-pr: stdout carries the jev-deps line (got %r)' % r.stdout.strip()[:200])
        check('test-key-7459' not in r.stdout + r.stderr, 'dep-pr: key never printed')
        check(Stub.posts == 1, 'dep-pr: exactly one Jev POST, got %d' % Stub.posts)

        rows = [json.loads(l) for l in log.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'dep-pr: one row appended, got %d' % len(rows))
        row = rows[0]
        check(row.get('site') == 'dependency-pr-arm', 'dep-pr: row site')
        check(row.get('advisory_only') is True, 'dep-pr: row advisory_only')
        check(row.get('rule_tier') == 'worker-arm', 'dep-pr: row rule_tier')
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              'dep-pr: row state_sha256')
        probs = row.get('probabilities') or {}
        check(probs.get('breaking') == 0.42 and probs.get('security_fix') == 0.42
              and probs.get('safe_auto_merge') == 0.42,
              'dep-pr: row carries all three probabilities')
        check(row.get('pr') == 999999 and row.get('repo') == 'Nishfleet/jev7459-nonexistent',
              'dep-pr: row repo/pr')
        check(row.get('head_sha') == '0123456789abcdef0123456789abcdef01234567',
              'dep-pr: row head_sha from fixture')
        ev = row.get('dependency_evidence') or {}
        check(ev.get('bot_author') is True and 'dependencies' in (ev.get('dep_labels') or []),
              'dep-pr: row dependency evidence')
        sd = row.get('semver_delta') or {}
        check(sd.get('count') == 3 and sd.get('grouped') is True,
              'dep-pr: row semver delta parsed three grouped bumps (got %r)' % sd)
        check('test-key-7459' not in json.dumps(row), 'dep-pr: row carries no key')
        body = Stub.last_body or {}
        check(body.get('model') == 'typesafe-ai/jev', 'dep-pr: request model id')
        q = body.get('questions') or {}
        check(set(q) == {'breaking', 'security_fix', 'safe_auto_merge'},
              'dep-pr: request question ids')
        st = body.get('state') or {}
        check(st.get('changelog_excerpt') and 'Bumps' in st['changelog_excerpt'],
              'dep-pr: state carries changelog excerpt')
        check((st.get('lockfile_diff_summary') or {}).get('diff_file_count') == 1,
              'dep-pr: state carries lockfile diff summary')
        check('dependabot' in (st.get('author') or ''), 'dep-pr: state author')
        check('Nishfleet/jev7459-nonexistent#999999@' in (row.get('ref') or ''),
              'dep-pr: ref names repo#pr@sha')

        calls = [json.loads(l) for l in ghlog.read_text().splitlines() if l.strip()]
        commented = [c for c in calls if c[:2] == ['pr', 'comment']]
        check(len(commented) == 1,
              'dep-pr: exactly one gh pr comment call, got %d' % len(commented))
        check(commented and any('jev-deps: breaking=p=0.420' in a for a in commented[0]),
              'dep-pr: comment body carries the jev-deps line')
        state_sha = row.get('state_sha256')

        # --- dedupe: same state already commented -> no second comment ---
        gh_comments.write_text(json.dumps(
            [[{'body': 'jev-deps: breaking=p=0.420 security_fix=p=0.420 '
                       'safe_auto_merge=p=0.420 state_sha256=%s' % state_sha}]]))
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '999999'],
                           capture_output=True, text=True, env=dep_env, timeout=90)
        check(r.returncode == 0 and 'comment already present' in r.stdout,
              'dep-pr: same state -> deduped comment, exit 0')
        calls = [json.loads(l) for l in ghlog.read_text().splitlines() if l.strip()]
        commented = [c for c in calls if c[:2] == ['pr', 'comment']]
        check(len(commented) == 1, 'dep-pr: dedupe posts no second comment')
        gh_comments.write_text('[]')

        # --- non-dependency PR: no Jev call, no row, no comment ---
        Stub.posts = 0
        env = dict(base_env, JEV_DEP_PR_ARM_ENDPOINT=endpoint,
                   JEV_DEP_PR_ARM_LOG=str(log),
                   JEV_DEP_PR_ARM_FIXTURE_PR=str(FIXTURES / 'jev7459-pr-nondep.json'),
                   JEV_DEP_PR_ARM_FIXTURE_DIFF=str(FIXTURES / 'jev7459-diff.txt'))
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '888888'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'not a dependency PR' in r.stdout,
              'dep-pr: non-dep PR skipped, exit 0')
        check(Stub.posts == 0, 'dep-pr: non-dep PR spends no Jev call')

        # --- off flag ---
        env = dict(dep_env, JEV_DEP_PR_ARM='0')
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory off' in r.stdout,
              'dep-pr: flag=0 disables and exits 0')

        # --- dead endpoint ---
        env = dict(dep_env, JEV_DEP_PR_ARM_ENDPOINT='http://127.0.0.1:1/jev')
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '999999'],
                           capture_output=True, text=True, env=env, timeout=60)
        check(r.returncode == 0 and 'jev advisory unavailable' in r.stdout,
              'dep-pr: dead endpoint -> advisory unavailable, exit 0')

        # --- invalid probability ---
        Stub.prob = 1.7
        r = subprocess.run([sys.executable, str(bfile), 'Nishfleet/jev7459-nonexistent', '999999'],
                           capture_output=True, text=True, env=dep_env, timeout=60)
        check(r.returncode == 0 and 'invalid probability' in r.stdout,
              'dep-pr: invalid probability -> advisory unavailable, exit 0')
        Stub.prob = 0.42

        # --- bad args ---
        r = subprocess.run([sys.executable, str(bfile), 'not-a-repo', '999999'],
                           capture_output=True, text=True, env=dep_env, timeout=60)
        check(r.returncode == 0 and 'bad args' in r.stdout,
              'dep-pr: bad repo arg -> advisory unavailable, exit 0')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
