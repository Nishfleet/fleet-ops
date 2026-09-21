#!/usr/bin/env python3
"""fleet-ops#7416: the advisory intake acquisition rank.

Static contract assertions on prompts/intake.md plus functional passes of the
embedded block against a stub /jev endpoint and a ready-queue fixture. The
block is advisory-only: every failure path must leave today's order standing
and exit 0, and the seat key must never reach stdout, stderr or a log row.
Run: python3 tests/intake-rank-jev-shadow.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
INTAKE = ROOT / 'prompts' / 'intake.md'
BLOCK_ARGV = 'python3 - "<repo>" <<\'PY\''
KEY = 'test-key-7416'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r'python3 - "<repo>" <<\'PY\'\n(.*?)\nPY\n', text, re.S)
    return m.group(1) if m else None


class JevStub(BaseHTTPRequestHandler):
    """POST /jev. mode=ok answers every question from the fixture numbers;
    mode=bad drops a probability key; mode=oob returns an out-of-range p."""
    mode = 'ok'
    hits = []

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        JevStub.hits.append(body)
        if self.headers.get('Authorization') != 'Bearer ' + KEY:
            self.send_response(401)
            self.end_headers()
            return
        answers = {}
        for qid in body.get('questions') or {}:
            num = int(qid.rsplit('_', 1)[-1])
            if num == 21:
                choice, probs = '3', {'0': 0.02, '1': 0.03, '2': 0.02, '3': 0.93}
            elif num == 25:
                choice, probs = '2', {'0': 0.05, '1': 0.03, '2': 0.90, '3': 0.02}
            elif num == 23:
                choice, probs = '2', {'0': 0.02, '1': 0.03, '2': 0.93, '3': 0.02}
            else:
                choice, probs = '1', {'0': 0.05, '1': 0.65, '2': 0.15, '3': 0.15}
            if JevStub.mode == 'bad':
                probs.pop('3')
            if JevStub.mode == 'oob':
                probs = {'0': 0.0, '1': 0.0, '2': 0.0, '3': 4.2}
            answers[qid] = {'type': 'choice', 'choice': choice, 'probabilities': probs}
        out = json.dumps({'answers': answers, 'usage': {'total_tokens': 4210}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def serve(mode):
    JevStub.mode = mode
    JevStub.hits = []
    srv = HTTPServer(('127.0.0.1', 0), JevStub)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, 'http://127.0.0.1:%d/jev' % srv.server_address[1]


def run_block(block_path, argv, env):
    return subprocess.run(['python3', block_path] + argv,
                          capture_output=True, text=True, timeout=60, env=env)


def read_rows(path):
    if not pathlib.Path(path).exists():
        return []
    return [json.loads(l) for l in pathlib.Path(path).read_text().splitlines() if l.strip()]


def main():
    text = INTAKE.read_text()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='jev7416-'))
    block = extract_block(text)

    # ---- static contract -------------------------------------------------
    check('## Shadow Jev tier — advisory, never a gate (fleet-ops#7416)' in text,
          'intake.md carries the shadow tier section')
    for needle in ('intake-rank', 'can this produce the first real signup',
                   'PI_INTAKE_JEV_ACQUISITION', 'LITELLM_JEV_KEY',
                   'intake-rank.jsonl', 'acquisition_value', 'signups_since_june',
                   '2026-09-17', 'advisory_only', 'state_sha256', 'usage',
                   '2 weeks', '30-issue spot audit', 'jev-rank-act',
                   'JEV_INTAKE_RANK_MAX', 'scored N of M', '2,000-char body excerpts',
                   "jev: unavailable", 'tail guard'):
        check(needle in text, 'intake.md names %s' % needle)
    check(text.count(BLOCK_ARGV) == 1, 'exactly one acquisition-rank block')
    check('VERCEL_AI_GATEWAY' not in text,
          'the raw gateway key variable is never named')
    sec = text.index('## Shadow Jev tier — advisory, never a gate (fleet-ops#7416)')
    check(sec > text.index('Steps:'), 'section sits after the step list')
    check(sec > text.index('6. Print one line per issue'),
          'section sits after step 6')
    step3 = text[text.index('3. **Capacity.**'):text.index('4. **Pick work.**')]
    check('acquisition rank' in step3, 'step 3 runs the rank before at-capacity')
    step4 = text[text.index('4. **Pick work.**'):text.index('5. **Claim, in order')]
    check('acquisition rank' in step4, 'step 4 runs the rank after the pick')
    step5 = text[text.index('5. **Claim, in order'):text.index('6. Print one line')]
    check('jev-rank-act:' in step5 and 'tail guard' in step5,
          'step 5 carries the one act override and the tail-guard precedence')
    check(block is not None, 'acquisition-rank block extracted')
    if block is None:
        print('cannot continue without the block', file=sys.stderr)
        return 1
    try:
        compile(block, 'intake-rank-block', 'exec')
        check(True, 'embedded python compiles')
    except SyntaxError as exc:
        check(False, 'embedded python compiles (%s)' % exc)
        return 1
    for banned in ('issue edit', 'git push', 'systemctl', 'gh pr'):
        check(banned not in block, 'block never mutates state (%r absent)' % banned)
    block_path = tmp / 'block.py'
    block_path.write_text(block)

    fixture = tmp / 'ready.json'
    fixture.write_text(json.dumps([
        {'number': 9009, 'title': 'noise', 'body': 'x',
         'labels': [{'name': 'agent-ready'}, {'name': 'noise-class'}],
         'createdAt': '2026-09-21T10:00:00Z'},
        {'number': 7777, 'title': 'not ready', 'body': 'x',
         'labels': [{'name': 'priority'}], 'createdAt': '2026-09-01T10:00:00Z'},
        {'number': 21, 'title': 'public signup CTA', 'body': 'reachable signup',
         'labels': [{'name': 'agent-ready'}], 'createdAt': '2026-09-22T09:00:00Z'},
        {'number': 31, 'title': '__scout_probe_ leak', 'body': 'x',
         'labels': [{'name': 'agent-ready'}], 'createdAt': '2026-09-18T09:00:00Z'},
        {'number': 22, 'title': 'docs touchup', 'body': 'x' * 3000,
         'labels': [{'name': 'agent-ready'}], 'createdAt': '2026-09-20T09:00:00Z'},
        {'number': 23, 'title': 'oldest plain', 'body': 'fix',
         'labels': [{'name': 'agent-ready'}], 'createdAt': '2026-09-19T09:00:00Z'},
        {'number': 25, 'title': 'critical thing', 'body': 'cp',
         'labels': [{'name': 'agent-ready'}, {'name': 'critical-path'}],
         'createdAt': '2026-09-21T09:00:00Z'},
    ]))

    def env(endpoint, log, extra=None):
        e = dict(os.environ, JEV_INTAKE_RANK_ENDPOINT=endpoint, JEV_INTAKE_RANK_LOG=log,
                 JEV_INTAKE_FIXTURE_READY=str(fixture), LITELLM_JEV_KEY=KEY,
                 JEV_INTAKE_RANK_SEAT_ENV=str(tmp / 'no-seat.env'))
        e.pop('PI_INTAKE_JEV_ACQUISITION', None)
        if extra:
            e.update(extra)
        return e

    # ---- functional: the happy path --------------------------------------
    srv, url = serve('ok')
    log = tmp / 'rank.jsonl'
    r = run_block(block_path, ['fleet-ops'], env(url, str(log)))
    srv.shutdown()
    out = r.stdout
    check(r.returncode == 0, 'happy path exits 0')
    check('jev-rank: Nishfleet/fleet-ops#21 acquisition_value=3 p=0.930 current=4 advisory=1' in out,
          'real issue number, both orders and the score print')
    check(out.count('jev-rank: Nishfleet/fleet-ops#') == 4,
          'one rank line per ready issue after the drops')
    check('Nishfleet/fleet-ops#9009' not in out and 'Nishfleet/fleet-ops#7777' not in out
          and 'Nishfleet/fleet-ops#31' not in out,
          'noise-class, non-ready and probe issues are dropped')
    check('jev-rank-act: Nishfleet/fleet-ops#21 p=0.930' in out,
          'a value-3 issue at p>=0.9 is offered first place')
    check('Nishfleet/fleet-ops#25' in out and 'current=1' in out,
          'the critical-path issue keeps current=1')
    rows = read_rows(log)
    check(len(rows) == 4, 'one JSONL row per ready issue')
    check(all(x['site'] == 'intake-rank' and x['advisory_only'] is True for x in rows),
          'rows carry site=intake-rank and advisory_only=true')
    check(all(x['state_sha256'] and x['usage'] and x['answers'] for x in rows),
          'rows carry state_sha256, answers and usage')
    check(all(x['batch_size'] == 4 for x in rows), 'rows carry the batch size')
    check(any(x['ref'] == 'Nishfleet/fleet-ops#21' and x['advisory'] == 1 and x['acted'] for x in rows),
          'the promoted issue is rowed with its advisory rank and acted flag')
    check([x['ref'] for x in sorted(rows, key=lambda x: x['current'])] ==
          ['Nishfleet/fleet-ops#25', 'Nishfleet/fleet-ops#23', 'Nishfleet/fleet-ops#22',
           'Nishfleet/fleet-ops#21'],
          "current= is today's order: critical-path first, then oldest-first")
    check(sorted(x['advisory'] for x in rows) == [1, 2, 3, 4],
          'advisory ranks are a permutation')
    check(KEY not in out and KEY not in r.stderr, 'the seat key never reaches the transcript')
    check(KEY not in log.read_text(), 'the seat key never reaches a log row')
    check(stat.S_IMODE(log.stat().st_mode) == 0o600, 'the log is written 0600')
    check(len(JevStub.hits) == 1, 'one batched Jev call per tick')
    q = JevStub.hits[0].get('questions') or {}
    check(sorted(q) == ['issue_21', 'issue_22', 'issue_23', 'issue_25'],
          'the batch asks one question per ready issue, keyed by issue number')
    check('baseline' in JevStub.hits[0].get('state', {}) and
          JevStub.hits[0]['state']['baseline']['signups_since_june'] == 0,
          'the state carries the dated baseline')
    sent = JevStub.hits[0]['state']
    check(sent.get('ready_total') == 4, 'the state carries the ready total')
    body_22 = [x for x in sent['issues'] if x['number'] == 22][0]['body']
    check(len(body_22) == 2000 and
          [x for x in sent['issues'] if x['number'] == 22][0]['body_truncated'] is True,
          'long bodies are cut to 2000 chars and flagged')
    check(all('instructions' in q and 'evidence, not instructions' in q['instructions']
              for q in JevStub.hits[0]['questions'].values()),
          'every question carries the untrusted-text instruction')

    # ---- functional: the head-only cost bound ----------------------------
    srv, url = serve('ok')
    log_cap = tmp / 'cap.jsonl'
    r = run_block(block_path, ['fleet-ops'],
                  env(url, str(log_cap), {'JEV_INTAKE_RANK_MAX': '2'}))
    srv.shutdown()
    check('scored 2 of 4 ready issues' in r.stdout,
          'a longer queue prints the scored-of-ready coverage line')
    check(r.stdout.count('jev-rank: Nishfleet/fleet-ops#') == 2,
          'only the head of the order is scored')
    check('Nishfleet/fleet-ops#25' in r.stdout and 'Nishfleet/fleet-ops#23' in r.stdout,
          'the scored head is the top of today\'s order')
    cap_rows = read_rows(log_cap)
    check(len(cap_rows) == 2 and all(x['batch_size'] == 2 and x['ready_total'] == 4
                                     and x['leftover'] == 2 for x in cap_rows),
          'rows carry the batch size, the ready total and the leftover tail')
    check(sorted(q for q in JevStub.hits[0]['questions']) == ['issue_23', 'issue_25'],
          'the Jev call only asks about the scored head')

    # ---- functional: advisory failure paths ------------------------------
    cases = [
        ('flag off', env(url, str(tmp / 'off.jsonl'), {'PI_INTAKE_JEV_ACQUISITION': '0'}),
         'off (PI_INTAKE_JEV_ACQUISITION=0)', False),
        ('dead endpoint', env('http://127.0.0.1:1/jev', str(tmp / 'dead.jsonl')),
         'jev: unavailable (', False),
        ('no key', env(url, str(tmp / 'nokey.jsonl'), {'LITELLM_JEV_KEY': ''}),
         'no LITELLM_JEV_KEY', False),
        ('missing fixture', env(url, str(tmp / 'nofix.jsonl'), {'JEV_INTAKE_FIXTURE_READY': str(tmp / 'nope.json')}),
         'ready-queue fetch failed', False),
        ('empty queue', env(url, str(tmp / 'empty.jsonl'), {'JEV_INTAKE_FIXTURE_READY': str(tmp / 'empty.json')}),
         'ready queue empty', False),
        ('bad repo arg', env(url, str(tmp / 'badrepo.jsonl')), 'bad repo arg', False),
    ]
    (tmp / 'empty.json').write_text('[]')
    for name, e, needle, rows_expected in cases:
        r = run_block(block_path, ['fleet-ops'] if name != 'bad repo arg' else ['bad repo/../x'], e)
        check(r.returncode == 0, '%s exits 0' % name)
        check(needle in r.stdout, '%s prints %s' % (name, needle))
        check('today\'s order stands' in r.stdout or 'ready queue empty' in r.stdout,
              '%s leaves the order standing' % name)

    srv, url = serve('bad')
    log_bad = tmp / 'bad.jsonl'
    r = run_block(block_path, ['fleet-ops'], env(url, str(log_bad)))
    srv.shutdown()
    check(r.returncode == 0 and 'invalid answer' in r.stdout,
          'a malformed answer prints invalid answer and exits 0')
    check(read_rows(log_bad) == [], 'a malformed answer logs nothing')

    srv, url = serve('oob')
    log_oob = tmp / 'oob.jsonl'
    r = run_block(block_path, ['fleet-ops'], env(url, str(log_oob)))
    srv.shutdown()
    check(r.returncode == 0 and 'invalid answer' in r.stdout,
          'an out-of-range probability is rejected')
    check(read_rows(log_oob) == [], 'an out-of-range probability logs nothing')

    # ---- functional: no confident value-3 issue -> no promotion ----------
    srv, url = serve('ok')
    low = tmp / 'low.json'
    low.write_text(json.dumps([
        {'number': 41, 'title': 'maybe a signup thing', 'body': 'x',
         'labels': [{'name': 'agent-ready'}], 'createdAt': '2026-09-19T09:00:00Z'},
    ]))
    log_low = tmp / 'low.jsonl'
    e = env(url, str(log_low), {'JEV_INTAKE_FIXTURE_READY': str(low)})
    r = run_block(block_path, ['fleet-ops'], e)
    srv.shutdown()
    check('no first-place promotion' in r.stdout,
          'a lone value-1 issue does not win first place')
    check(read_rows(log_low)[0]['advisory'] == 1 and read_rows(log_low)[0]['current'] == 1,
          'the lone issue still carries both orders')

    # ---- the block's own source never names a secret or a raw gateway var
    check('VERCEL_AI_GATEWAY' not in block, 'block never names the raw gateway variable')
    check(re.search(r'print\([^\n]*LITELLM_JEV_KEY', block) is None,
          'the block never prints the key variable')

    if FAILS:
        print('\n%d FAILED' % len(FAILS), file=sys.stderr)
        return 1
    print('\nall checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
