#!/usr/bin/env python3
"""fleet-ops#7442: the scout prompt carries the advisory Jev shadow tier
(site `scout`). After a run files its issues, one batched call asks Jev four
questions per candidate — choice(5) funnel stage, score label-budget rank,
boolean spec-completeness, boolean touches-migrations — and appends one JSONL
row per candidate to scout.jsonl beside what the prompt produced. Static
prompt-contract assertions plus a functional pass against a stub /jev
endpoint and fixture issues. Run: python3 tests/scout-jev-shadow.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'scout.md'
FIXTURES = ROOT / 'tests' / 'fixtures' / 'scout-jev'
HEADING = '## Shadow Jev tier — scout candidate review (fleet-ops#7442, advisory, never a gate)'
DELIM = "<<'PY_SCOUT'"
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"<<'PY_SCOUT'\n(.*?)\nPY_SCOUT\n", text, re.S)
    return m.group(1) if m else None


def replay_rows(logfile):
    """The flip-time replay primitive: every row must re-parse with a real
    ref, a state hash and at least one typed answer extractable."""
    out = []
    for line in logfile.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        assert re.match(r'^Nishfleet/[A-Za-z0-9._-]+#\d+$', row['ref']), row['ref']
        assert row['site'] == 'scout' and row['advisory_only'] is True
        assert re.match(r'^[0-9a-f]{64}$', row['state_sha256'])
        assert isinstance(row['answers'], dict) and row['answers']
        assert isinstance(row['prompt_produced'], dict)
        out.append(row)
    return out


def main():
    text = PROMPT.read_text()

    check(HEADING in text, 'shadow section heading present')
    lines = text.splitlines()
    step5 = next((i for i, l in enumerate(lines) if l.startswith('## Step 5')), -1)
    shadow = next((i for i, l in enumerate(lines) if l.startswith(HEADING)), -1)
    check(0 <= step5 < shadow, 'shadow section follows Step 5')
    check(text.count(DELIM) == 1, 'exactly one embedded python block for this site')
    block = extract_block(text)
    check(block is not None, 'block extracted')
    try:
        compile(block, 'jev-scout-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_SCOUT_SHADOW', 'scout.jsonl', "site=scout",
                   '127.0.0.1:4000/jev', 'advisory_only', 'typesafe-ai/jev',
                   'fleet-ops#7754', 'advisory, never a gate', 'label_budget',
                   'REST only, never GraphQL', 'typesafe-jev.env',
                   'first watchlist', 'first proof', 'touches-migrations'):
        check(needle in text, 'prompt names %s' % needle)
    check("E('JEV_SCOUT_SHADOW')" in block, 'flag gate present')
    check("('1', 'true', 'on', 'yes', 'shadow')" in block,
          'off-by-default flag semantics')
    check("'gh', 'api', 'repos/" in block, 'candidate list built via REST gh api')
    check('graphql' not in block, 'no GraphQL in block')
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TYPESAFE_API_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'key variable never interpolated into a print call')
    prints = re.findall(r'print\([^)]*\)', block)
    check(prints and all('file=sys.stderr' in p for p in prints),
          'every print goes to stderr (supply: stays last on stdout)')

    # Behaviour re-asserts: the protected rules must survive this PR's edits.
    for needle in ('SCOUT_RESEARCH_FLOOR', 'direction#4518', 'scout-candidate',
                   'usage-uncited', 'supply: ready_count=', 'acquisition-class',
                   'migrations/**', 'scout-yield:', 'blocked-on: orchestrator'):
        check(needle in text, 'prompt still carries %s' % needle)

    class Stub(BaseHTTPRequestHandler):
        calls = 0

        def do_POST(self):
            Stub.calls += 1
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            if self.headers.get('Authorization') != 'Bearer test-key-7442':
                self.send_response(401)
                self.end_headers()
                return
            ans = {}
            for qid, q in (body.get('questions') or {}).items():
                qt = q.get('type')
                if qt == 'choice':
                    crit = list((q.get('criteria') or {}).keys())
                    ans[qid] = {'type': 'choice', 'choice': crit[0],
                                'probabilities': {k: 0.1 for k in crit}}
                elif qt == 'score':
                    lv = q.get('criteria') or ['a', 'b']
                    ans[qid] = {'type': 'score', 'score': 2.5,
                                'probabilities': {str(i): 1.0 / len(lv) for i in range(len(lv))}}
                else:
                    ans[qid] = {'type': 'boolean', 'probability': 0.71}
            out = json.dumps({'answers': ans, 'usage': {'total_tokens': 900}}).encode()
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
        logfile = pathlib.Path(td) / 'scout.jsonl'
        bands_file = pathlib.Path(td) / 'jev-bands.json'
        bands_file.write_text(json.dumps({'sites': {
            'scout': {'act_hi': 0.9, 'review_lo': 0.1}}}))

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7442',
                        JEV_SCOUT_ENDPOINT=endpoint,
                        JEV_SCOUT_LOG=str(logfile),
                        JEV_BANDS_FILE=str(bands_file),
                        JEV_SCOUT_FIXTURE_DIR=str(FIXTURES))

        def invoke(env, args=('Nishfleet/0509', '101 102', '8')):
            return subprocess.run([sys.executable, str(blockfile), *args],
                                  capture_output=True, text=True, env=env, timeout=90)

        # Flag off (unset): no call, no row, exit 0.
        env = dict(base_env); env.pop('JEV_SCOUT_SHADOW', None)
        r = invoke(env)
        check(r.returncode == 0 and 'advisory off' in r.stderr,
              'flag unset: off-note, exit 0 (stderr: %s)' % r.stderr.strip()[:160])
        check(Stub.calls == 0, 'flag unset: no /jev call')
        check(not logfile.exists() or logfile.read_text().strip() == '',
              'flag unset: no rows written')
        check(r.stdout.strip() == '', 'flag unset: stdout clean')

        env = dict(base_env, JEV_SCOUT_SHADOW='0')
        r = invoke(env)
        check(r.returncode == 0 and 'advisory off' in r.stderr and Stub.calls == 0,
              'flag=0: off-note, no call')

        # Shadow on: one batched call, per-candidate rows.
        env = dict(base_env, JEV_SCOUT_SHADOW='1')
        r = invoke(env)
        check(r.returncode == 0, 'shadow: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(Stub.calls == 1, 'shadow: exactly one batched /jev call, got %d' % Stub.calls)
        check('test-key-7442' not in r.stdout + r.stderr, 'shadow: key never printed')
        check(r.stdout.strip() == '', 'shadow: stdout clean (stderr-only notes)')
        check('logged 2/2 candidates' in r.stderr, 'shadow: summary line')
        qs = Stub.last_body.get('questions') or {}
        check(len(qs) == 8, 'shadow: 4 questions x 2 candidates, got %d' % len(qs))
        check(set(qs) == {'i101_funnel', 'i101_rank', 'i101_spec', 'i101_migrations',
                          'i102_funnel', 'i102_rank', 'i102_spec', 'i102_migrations'},
              'shadow: question ids per candidate')
        check(qs['i101_funnel']['type'] == 'choice' and
              list(qs['i101_funnel']['criteria']) ==
              ['visit', 'signup', 'first watchlist', 'first proof', 'paid'],
              'shadow: funnel choice(5) criteria')
        check(qs['i101_rank']['type'] == 'score' and len(qs['i101_rank']['criteria']) == 5,
              'shadow: rank score levels')
        check(qs['i101_spec']['type'] == 'boolean' and
              qs['i101_migrations']['type'] == 'boolean', 'shadow: two booleans')
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'shadow: request model id')
        st = Stub.last_body.get('state') or {}
        check(st.get('site') == 'scout' and len(st.get('candidates') or []) == 2,
              'shadow: state carries code-built candidates')
        check(isinstance(st.get('candidates')[0].get('number'), int),
              'shadow: candidate number is int')

        rows = replay_rows(logfile)
        check(len(rows) == 2, 'shadow: two rows replayed, got %d' % len(rows))
        by_ref = {r_['ref']: r_ for r_ in rows}
        r101 = by_ref.get('Nishfleet/0509#101') or {}
        check(set(r101.get('answers') or {}) == {'funnel', 'rank', 'spec', 'migrations'},
              'row answers keyed by question')
        check(r101.get('rule_tier') == 'scout', 'row rule_tier')
        check(r101.get('act_hi') == 0.9 and r101.get('review_lo') == 0.1,
              'row stamps the site band edges from the table')
        pp = r101.get('prompt_produced') or {}
        check(pp.get('funnel_stage') == 'signup', 'row prompt_produced funnel_stage from body')
        check('scout-candidate' in (pp.get('labels') or []), 'row prompt_produced labels')
        check(pp.get('mentions_migrations') is True, 'row prompt_produced migrations flag')
        check(pp.get('spec_fields_missing') == [],
              'row prompt_produced spec fields complete (fixture 101)')
        r102 = by_ref.get('Nishfleet/0509#102') or {}
        check('metric:' in ((r102.get('prompt_produced') or {}).get('spec_fields_missing') or []),
              'row prompt_produced missing spec fields (fixture 102)')
        check(all('test-key-7442' not in json.dumps(r_) for r_ in rows), 'rows carry no key')

        # Replay over rows twice: deterministic extraction for the flip pass.
        check([r_['issue'] for r_ in replay_rows(logfile)] == [101, 102],
              'replay: rows re-parse in order')

        # Fixture miss (issue not a real record): skipped, other candidate rows.
        logfile.write_text('')
        r = invoke(env, ('Nishfleet/0509', '101 999 102', '8'))
        check(r.returncode == 0 and 'issue 999 unreadable' in r.stderr,
              'unreadable candidate skipped with note')
        check(len(replay_rows(logfile)) == 2, 'unreadable candidate writes no row')

        # Invalid answers: bad rows are dropped, valid ones kept.
        class BadStub(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                body = json.loads(self.rfile.read(n) or b'{}')
                ans = {}
                for qid in (body.get('questions') or {}):
                    if qid.endswith('_funnel'):
                        ans[qid] = {'type': 'choice', 'choice': 'bogus', 'probabilities': {}}
                    else:
                        ans[qid] = {'type': 'boolean', 'probability': 7}
                out = json.dumps({'answers': ans, 'usage': {}}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        bad = HTTPServer(('127.0.0.1', 0), BadStub)
        threading.Thread(target=bad.serve_forever, daemon=True).start()
        logfile.write_text('')
        env = dict(base_env, JEV_SCOUT_SHADOW='1',
                   JEV_SCOUT_ENDPOINT='http://127.0.0.1:%d/jev' % bad.server_port)
        r = invoke(env)
        check(r.returncode == 0 and 'no valid answers' in r.stderr,
              'all-invalid -> advisory unavailable, exit 0')
        check(logfile.read_text().strip() == '', 'all-invalid writes no row')
        bad.shutdown()

        # Dead endpoint.
        logfile.write_text('')
        env = dict(base_env, JEV_SCOUT_SHADOW='1',
                   JEV_SCOUT_ENDPOINT='http://127.0.0.1:1/jev')
        r = invoke(env)
        check(r.returncode == 0 and 'advisory unavailable' in r.stderr,
              'dead endpoint -> advisory unavailable, exit 0')

        # No key.
        env = dict(base_env, JEV_SCOUT_SHADOW='1')
        env.pop('LITELLM_JEV_KEY', None)
        env['HOME'] = td  # no seat file reachable
        r = invoke(env)
        check(r.returncode == 0 and 'no seat key' in r.stderr,
              'no key -> advisory unavailable, exit 0')

        # Bad args / no candidates.
        r = invoke(dict(base_env, JEV_SCOUT_SHADOW='1'), ('bad repo', '101', '-'))
        check(r.returncode == 0 and 'bad repo arg' in r.stderr, 'bad repo -> unavailable')
        r = invoke(dict(base_env, JEV_SCOUT_SHADOW='1'), ('Nishfleet/0509', '-', '-'))
        check(r.returncode == 0 and 'no filed issues' in r.stderr, 'no numbers -> skip note')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
