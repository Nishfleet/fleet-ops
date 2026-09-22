#!/usr/bin/env python3
"""fleet-ops#7778: the scout prompt carries a second advisory Jev shadow
tier (site `scout-rank`). After a run's Step 5 summary, code re-collects
the repo's candidate signals — conflicting/stale open PRs, failing main CI
runs, open code-scanning alerts, recent merged PRs — as (id, source, text,
first_seen), reads open-issue titles as the dedupe corpus, asks Jev two
questions per signal in ONE batched call (score `issue_worthiness`,
boolean `duplicate_of_open_issue`), and appends one JSONL row per signal
to scout-rank.jsonl beside the run's filed/labeled picks. Static
prompt-contract assertions plus a functional pass against a stub /jev
endpoint and fixture probes. Run: python3 tests/scout-rank-shadow.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'scout.md'
FIXTURES = ROOT / 'tests' / 'fixtures' / 'scout-rank'
HEADING = '## Shadow Jev tier — scout signal ranking (fleet-ops#7778, advisory, never a gate)'
PREV = '## Shadow Jev tier — scout candidate review (fleet-ops#7442, advisory, never a gate)'
DELIM = "<<'PY_SCOUT_RANK'"
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"<<'PY_SCOUT_RANK'\n(.*?)\nPY_SCOUT_RANK\n", text, re.S)
    return m.group(1) if m else None


def replay_rows(logfile):
    """The flip-time replay primitive: every row must re-parse with a real
    ref, a state hash and at least one typed answer extractable."""
    out = []
    for line in logfile.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        assert re.match(r'^Nishfleet/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$', row['ref']), row['ref']
        assert row['site'] == 'scout-rank' and row['advisory_only'] is True
        assert re.match(r'^[0-9a-f]{64}$', row['state_sha256'])
        assert isinstance(row['answers'], dict) and row['answers']
        assert isinstance(row['signal'], dict) and row['signal'].get('id')
        assert {'id', 'source', 'text', 'first_seen'} <= set(row['signal'])
        assert isinstance(row['worker_picks'], list)
        out.append(row)
    return out


def main():
    text = PROMPT.read_text()

    check(HEADING in text, 'shadow section heading present')
    lines = text.splitlines()
    prev = next((i for i, l in enumerate(lines) if l.startswith(PREV)), -1)
    shadow = next((i for i, l in enumerate(lines) if l.startswith(HEADING)), -1)
    check(0 <= prev < shadow, 'scout-rank section follows the #7442 shadow section')
    check(text.count(DELIM) == 1, 'exactly one embedded python block for this site')
    block = extract_block(text)
    check(block is not None, 'block extracted')
    try:
        compile(block, 'jev-scout-rank-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_SCOUT_RANK_SHADOW', 'scout-rank.jsonl', "site='scout-rank'",
                   '127.0.0.1:4000/jev', 'advisory_only', 'typesafe-ai/jev',
                   'fleet-ops#7754', 'advisory, never a gate', 'issue_worthiness',
                   'duplicate_of_open_issue', 'first_seen',
                   'REST only, never GraphQL', 'typesafe-jev.env',
                   'worker_picks', 'INVOCATION_ID'):
        check(needle in text, 'prompt names %s' % needle)
    check("E('JEV_SCOUT_RANK_SHADOW')" in block, 'flag gate present')
    check("('0', 'off', 'false', 'no')" in block,
          'on-by-default flag semantics (advisory inert; =0 rolls back)')
    check("'pr', 'list'" in block and "'run', 'list'" in block
          and "'issue', 'list'" in block and "code-scanning" in block,
          'signal list built via REST gh probes')
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
            if self.headers.get('Authorization') != 'Bearer test-key-7778':
                self.send_response(401)
                self.end_headers()
                return
            ans = {}
            for qid, q in (body.get('questions') or {}).items():
                if q.get('type') == 'score':
                    lv = q.get('criteria') or ['a', 'b']
                    ans[qid] = {'type': 'score', 'score': 2.5,
                                'probabilities': {str(i): 1.0 / len(lv) for i in range(len(lv))}}
                else:
                    ans[qid] = {'type': 'boolean', 'probability': 0.31}
            out = json.dumps({'answers': ans, 'usage': {'total_tokens': 700}}).encode()
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
        logfile = pathlib.Path(td) / 'scout-rank.jsonl'
        bands_file = pathlib.Path(td) / 'jev-bands.json'
        bands_file.write_text(json.dumps({'sites': {
            'scout-rank': {'act_hi': 0.9, 'review_lo': 0.1}}}))

        base_env = dict(os.environ,
                        LITELLM_JEV_KEY='test-key-7778',
                        JEV_SCOUT_RANK_ENDPOINT=endpoint,
                        JEV_SCOUT_RANK_LOG=str(logfile),
                        JEV_BANDS_FILE=str(bands_file),
                        JEV_SCOUT_RANK_FIXTURE_DIR=str(FIXTURES))

        def invoke(env, args=('Nishfleet/0509', '201', '201')):
            return subprocess.run([sys.executable, str(blockfile), *args],
                                  capture_output=True, text=True, env=env, timeout=90)

        # Default (unset): the call RUNS — advisory is inert by
        # construction, so the shipped default is on.
        env = dict(base_env); env.pop('JEV_SCOUT_RANK_SHADOW', None)
        r = invoke(env)
        check(r.returncode == 0, 'default: exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(Stub.calls == 1, 'default: exactly one batched /jev call, got %d' % Stub.calls)
        check('test-key-7778' not in r.stdout + r.stderr, 'default: key never printed')
        check(r.stdout.strip() == '', 'default: stdout clean (stderr-only notes)')
        check('logged 6/6 signals' in r.stderr,
              'default: summary line (stderr: %s)' % r.stderr.strip()[:200])
        qs = Stub.last_body.get('questions') or {}
        check(len(qs) == 12, 'default: 2 questions x 6 signals, got %d' % len(qs))
        check(set(qs) == {'c%d_%s' % (i, q) for i in range(6)
                          for q in ('issue_worthiness', 'duplicate_of_open_issue')},
              'question ids per signal index')
        check(qs['c0_issue_worthiness']['type'] == 'score' and
              list(qs['c0_issue_worthiness']['criteria']) ==
              ['noise', 'nice-to-have', 'user-visible defect', 'revenue-or-retention'],
              'issue_worthiness score over the issue\'s 4 levels')
        check(qs['c0_duplicate_of_open_issue']['type'] == 'boolean',
              'duplicate_of_open_issue is boolean')
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'request model id')
        st = Stub.last_body.get('state') or {}
        check(st.get('site') == 'scout-rank', 'state site')
        cands = st.get('candidates') or []
        check([c['id'] for c in cands] ==
              ['pr-55', 'pr-61', 'run-901', 'codeql-7', 'merged-88', 'merged-89'],
              'code-collected signal set (got %s)' % [c.get('id') for c in cands])
        check(all({'id', 'source', 'text', 'first_seen'} <= set(c) for c in cands),
              'every signal carries id/source/text/first_seen')
        check(cands[0]['source'] == 'conflicting-pr' and cands[1]['source'] == 'stale-pr',
              'conflicting vs stale classification')
        check(len(st.get('open_issues') or []) == 2,
              'open-issue dedupe corpus in state')
        check((st.get('worker_picks') or [{}])[0].get('number') == 201,
              'worker pick set in state')
        check((st.get('probes') or {}).get('code_scanning') == 'ok',
              'probe status map in state')

        rows = replay_rows(logfile)
        check(len(rows) == 6, 'six rows replayed, got %d' % len(rows))
        by_ref = {r_['ref']: r_ for r_ in rows}
        r55 = by_ref.get('Nishfleet/0509:pr-55') or {}
        check(set(r55.get('answers') or {}) ==
              {'issue_worthiness', 'duplicate_of_open_issue'},
              'row answers keyed by the issue\'s two question names')
        check(r55.get('rule_tier') == 'scout', 'row rule_tier')
        check(r55.get('act_hi') == 0.9 and r55.get('review_lo') == 0.1,
              'row stamps the site band edges from the table')
        wp = r55.get('worker_picks') or []
        check(wp and wp[0].get('title') == 'rebase-and-land #55: compare-table sticky header'
              and wp[0].get('filed') is True and wp[0].get('labeled') is True,
              'worker pick logged beside the rank')
        check((r55.get('signal') or {}).get('first_seen') == '2026-09-10T00:00:00Z',
              'row carries first_seen')
        check(all('test-key-7778' not in json.dumps(r_) for r_ in rows),
              'rows carry no key')
        check([r_['signal']['id'] for r_ in replay_rows(logfile)] ==
              ['pr-55', 'pr-61', 'run-901', 'codeql-7', 'merged-88', 'merged-89'],
              'replay: rows re-parse in order')

        # Flag off: no call, no row, exit 0.
        Stub.calls = 0
        logfile.write_text('')
        env = dict(base_env, JEV_SCOUT_RANK_SHADOW='0')
        r = invoke(env)
        check(r.returncode == 0 and 'advisory off' in r.stderr and Stub.calls == 0,
              'flag=0: off-note, no call')
        check(logfile.read_text().strip() == '', 'flag=0: no rows written')

        # No picks passed (filed=0 run): signals still ranked, picks empty.
        Stub.calls = 0
        logfile.write_text('')
        r = invoke(dict(base_env), ('Nishfleet/0509', '-', '-'))
        check(r.returncode == 0 and Stub.calls == 1 and 'logged 6/6' in r.stderr,
              'filed=0 run still ranks the signal set')
        check((replay_rows(logfile)[0].get('worker_picks')) == [],
              'filed=0 row carries empty pick set')

        # Invalid answers: bad rows are dropped, valid ones kept.
        class BadStub(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                body = json.loads(self.rfile.read(n) or b'{}')
                ans = {}
                for qid in (body.get('questions') or {}):
                    if qid.endswith('_issue_worthiness'):
                        ans[qid] = {'type': 'score', 'score': 'high'}
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
        env = dict(base_env,
                   JEV_SCOUT_RANK_ENDPOINT='http://127.0.0.1:%d/jev' % bad.server_port)
        r = invoke(env)
        check(r.returncode == 0 and 'no valid answers' in r.stderr,
              'all-invalid -> advisory unavailable, exit 0')
        check(logfile.read_text().strip() == '', 'all-invalid writes no row')
        bad.shutdown()

        # Dead endpoint.
        logfile.write_text('')
        env = dict(base_env, JEV_SCOUT_RANK_ENDPOINT='http://127.0.0.1:1/jev')
        r = invoke(env)
        check(r.returncode == 0 and 'advisory unavailable' in r.stderr,
              'dead endpoint -> advisory unavailable, exit 0')

        # No key.
        env = dict(base_env)
        env.pop('LITELLM_JEV_KEY', None)
        env['HOME'] = td  # no seat file reachable
        r = invoke(env)
        check(r.returncode == 0 and 'no seat key' in r.stderr,
              'no key -> advisory unavailable, exit 0')

        # Bad repo arg.
        r = invoke(dict(base_env), ('bad repo', '201', '-'))
        check(r.returncode == 0 and 'bad repo arg' in r.stderr, 'bad repo -> unavailable')

        # Empty signal set: every probe fails -> skip note, no call.
        empty = pathlib.Path(td) / 'empty-fixtures'
        empty.mkdir()
        Stub.calls = 0
        env = dict(base_env, JEV_SCOUT_RANK_FIXTURE_DIR=str(empty))
        r = invoke(env)
        check(r.returncode == 0 and 'no candidate signals' in r.stderr and Stub.calls == 0,
              'all probes failing -> skip note, no /jev call')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
