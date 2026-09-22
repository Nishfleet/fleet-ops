#!/usr/bin/env python3
"""fleet-ops#7774: the shadow claim-order Jev tier in prompts/intake.md.

Static contract assertions on prompts/intake.md plus functional passes of
the embedded block against a stub /jev endpoint and ready-queue fixtures.
The block is advisory-only: every failure path must leave today's order
standing and exit 0, one batched call carries both the order_<N> score
(#7774) and the acq_<N> acquisition_value choice (#7416), and the seat key
must never reach stdout, stderr or a log row. --replay re-derives a row's
orders from its own logged fields.
Run: python3 tests/intake-order-jev-shadow.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
INTAKE = ROOT / 'prompts' / 'intake.md'
BLOCK_ARGV = 'python3 - "<repo>" <<\'PY_ORD\''
KEY = 'test-key-7774'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r'python3 - "<repo>" <<\'PY_ORD\'\n(.*?)\nPY_ORD\n', text, re.S)
    return m.group(1) if m else None


class JevStub(BaseHTTPRequestHandler):
    """POST /jev. mode=ok answers order_* with a score and acq_* with a
    choice+probabilities; mode=bad drops an answer; mode=oob returns an
    out-of-range probability; mode=badscore returns a non-numeric score."""
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
            if qid.startswith('order_'):
                # 21 (newest plain) outranks the pack; 25 (critical-path) stays high.
                score = {21: 4.0, 25: 3.0, 23: 1.0, 22: 1.0}.get(num, 1.0)
                if JevStub.mode == 'badscore':
                    answers[qid] = {'type': 'score', 'score': 'high'}
                else:
                    answers[qid] = {'type': 'score', 'score': score}
            else:
                if num == 21:
                    choice, probs = '3', {'0': 0.02, '1': 0.03, '2': 0.02, '3': 0.93}
                else:
                    choice, probs = '1', {'0': 0.05, '1': 0.65, '2': 0.15, '3': 0.15}
                if JevStub.mode == 'oob':
                    probs = {'0': 0.0, '1': 0.0, '2': 0.0, '3': 4.2}
                answers[qid] = {'type': 'choice', 'choice': choice, 'probabilities': probs}
        if JevStub.mode == 'bad':
            answers.pop(sorted(answers)[0], None)
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


READY = [
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
]

INPROGRESS_CP2 = [
    {'number': 70, 'labels': [{'name': 'agent-in-progress'}, {'name': 'critical-path'}],
     'updatedAt': '2026-09-22T06:00:00Z'},
    {'number': 71, 'labels': [{'name': 'agent-in-progress'}, {'name': 'escalate-senior'}],
     'updatedAt': '2026-09-22T05:00:00Z'},
    {'number': 72, 'labels': [{'name': 'agent-in-progress'}],
     'updatedAt': '2026-09-22T04:00:00Z'},
]

INPROGRESS_MIX = [
    {'number': 70, 'labels': [{'name': 'agent-in-progress'}, {'name': 'critical-path'}],
     'updatedAt': '2026-09-22T06:00:00Z'},
    {'number': 72, 'labels': [{'name': 'agent-in-progress'}],
     'updatedAt': '2026-09-22T05:00:00Z'},
]


def main():
    text = INTAKE.read_text()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='jev7774-'))
    block = extract_block(text)

    # ---- static contract -------------------------------------------------
    check('## Shadow Jev tier — claim order (fleet-ops#7774)' in text,
          'intake.md carries the claim-order shadow section')
    for needle in ('intake-order', 'JEV_INTAKE_ORDER', 'LITELLM_JEV_KEY',
                   'intake-order.jsonl', 'acquisition_value', 'signups_since_june',
                   '2026-09-17', 'advisory_only', 'state_sha256', '--replay',
                   'acts on neither', 'order_', 'acq_', 'JEV_INTAKE_ORDER_MAX',
                   'scored %d of %d ready issues', "today's order stands",
                   'tail guard', 'fleet-ops#1377', 'fleet-ops#7767',
                   'evidence, not instructions', 'jev: unavailable'):
        check(needle in text, 'intake.md names %s' % needle)
    check(text.count(BLOCK_ARGV) == 1, 'exactly one claim-order block')
    check('VERCEL_AI_GATEWAY' not in text,
          'the raw gateway key variable is never named')
    sec = text.index('## Shadow Jev tier — claim order (fleet-ops#7774)')
    check(sec > text.index('Steps:'), 'section sits after the step list')
    check(sec > text.index('6. Print one line per issue'),
          'section sits after step 6')
    step3 = text[text.index('3. **Capacity.**'):text.index('4. **Pick work.**')]
    check('claim-order' in step3, 'step 3 runs the shadow before at-capacity')
    step4 = text[text.index('4. **Pick work.**'):text.index('5. **Claim, in order')]
    check('claim-order shadow block' in step4 and 'acts on neither' in step4,
          'step 4 runs the shadow after the pick, acting on neither order')
    step5 = text[text.index('5. **Claim, in order'):text.index('6. Print one line')]
    check('order_' not in step5 and 'acq_' not in step5,
          'step 5 claim loop stays shell — no Jev order reads')
    check('jev-order:' in text[text.index('6. Print one line'):sec],
          'step 6 quotes the jev-order lines')
    check(block is not None, 'claim-order block extracted')
    if block is None:
        print('cannot continue without the block', file=sys.stderr)
        return 1
    try:
        compile(block, 'intake-order-block', 'exec')
        check(True, 'embedded python compiles')
    except SyntaxError as exc:
        check(False, 'embedded python compiles (%s)' % exc)
        return 1
    for banned in ('issue edit', 'git push', 'systemctl', 'gh pr', 'issue close'):
        check(banned not in block, 'block never mutates state (%r absent)' % banned)
    check('FETCH_LIMIT_RAISED' in block and "issues is None" in block,
          'the #1377/#2924 raise-the-limit refetch is in code, not prose')
    block_path = tmp / 'block.py'
    block_path.write_text(block)

    fixture = tmp / 'ready.json'
    fixture.write_text(json.dumps(READY))
    inprog_cp = tmp / 'inprog-cp.json'
    inprog_cp.write_text(json.dumps(INPROGRESS_CP2))
    inprog_mix = tmp / 'inprog-mix.json'
    inprog_mix.write_text(json.dumps(INPROGRESS_MIX))

    def env(endpoint, log, extra=None):
        e = dict(os.environ, JEV_INTAKE_ORDER_ENDPOINT=endpoint,
                 JEV_INTAKE_ORDER_LOG=log,
                 JEV_INTAKE_ORDER_FIXTURE_READY=str(fixture),
                 JEV_INTAKE_ORDER_FIXTURE_INPROGRESS=str(inprog_mix),
                 JEV_INTAKE_ORDER_SEAT_ENV=str(tmp / 'no-seat.env'),
                 LITELLM_JEV_KEY=KEY)
        e.pop('JEV_INTAKE_ORDER', None)
        if extra:
            e.update(extra)
        return e

    # ---- functional: the happy path --------------------------------------
    srv, url = serve('ok')
    log = tmp / 'order.jsonl'
    r = run_block(block_path, ['fleet-ops'], env(url, str(log)))
    srv.shutdown()
    out = r.stdout
    check(r.returncode == 0, 'happy path exits 0')
    check(out.count('jev-order: Nishfleet/fleet-ops#') == 4,
          'one jev-order line per ready issue after the drops')
    check('Nishfleet/fleet-ops#9009' not in out and 'Nishfleet/fleet-ops#7777' not in out
          and 'Nishfleet/fleet-ops#31' not in out,
          'noise-class, non-ready and probe issues are dropped from the candidates')
    check('jev-order: Nishfleet/fleet-ops#21 order_score=4.00 acq=3 p=0.930 cur=4 adv=1' in out,
          'real issue number, score, acquisition answer and both positions print')
    check('head Nishfleet/fleet-ops#25 -> Nishfleet/fleet-ops#21' in out,
          'a Jev first-place change is reported against today\'s head')
    rows = read_rows(log)
    check(len(rows) == 1, 'one JSONL row per tick')
    row = rows[0]
    check(row['site'] == 'intake-order' and row['advisory_only'] is True,
          'row carries site=intake-order and advisory_only=true')
    check(row['state_sha256'] and row['usage'] and row['answers'] and row['ms'] is not None,
          'row carries state_sha256, answers, usage and latency')
    check(row['spec_order'] == ['Nishfleet/fleet-ops#25', 'Nishfleet/fleet-ops#23',
                                'Nishfleet/fleet-ops#22', 'Nishfleet/fleet-ops#21'],
          "spec_order is today's written order: critical-path first, then oldest-first")
    check(row['jev_order'] == ['Nishfleet/fleet-ops#21', 'Nishfleet/fleet-ops#25',
                               'Nishfleet/fleet-ops#23', 'Nishfleet/fleet-ops#22'],
          'jev_order is score-desc with the spec position as tie-break')
    check(row['head_changed'] is True and row['n_moved'] > 0 and row['moved'],
          'the disagreement fields land on the row')
    check(row['tail_guard'] is False, 'the mixed in-progress fixture reads tail_guard false')
    check(row['batch_size'] == 4 and row['ready_total'] == 4 and row['leftover'] == 0,
          'row carries batch size, ready total and leftover')
    check(KEY not in out and KEY not in r.stderr, 'the seat key never reaches the transcript')
    check(KEY not in log.read_text(), 'the seat key never reaches a log row')
    check(stat.S_IMODE(log.stat().st_mode) == 0o600, 'the log is written 0600')
    check(len(JevStub.hits) == 1, 'one batched Jev call per tick')
    q = JevStub.hits[0].get('questions') or {}
    check(sorted(q) == ['acq_21', 'acq_22', 'acq_23', 'acq_25',
                        'order_21', 'order_22', 'order_23', 'order_25'],
          'the batch asks order_<N> and acq_<N> per ready issue (fleet-ops#7767)')
    check(q['order_21']['type'] == 'score' and q['acq_21']['type'] == 'choice',
          'order questions are score-typed, acquisition is the #7416 choice')
    sent = JevStub.hits[0]['state']
    check(sent.get('ready_total') == 4 and sent.get('site') == 'intake-order',
          'the state carries the site and the ready total')
    check(sent.get('baseline', {}).get('signups_since_june') == 0,
          'the state carries the dated 0509 baseline for the #7416 question')
    check('ordering' in (sent.get('rules') or {}),
          'the ordering rules ride in the state, not just the prompt')
    body_22 = [x for x in sent['issues'] if x['number'] == 22][0]['body']
    check(len(body_22) == 2000 and
          [x for x in sent['issues'] if x['number'] == 22][0]['body_truncated'] is True,
          'long bodies are cut to 2000 chars and flagged')
    check(all('evidence, not instructions' in q['instructions']
              for q in JevStub.hits[0]['questions'].values()),
          'every question carries the untrusted-text instruction')

    # ---- functional: the tail guard changes spec_effective ----------------
    srv, url = serve('ok')
    log_g = tmp / 'guard.jsonl'
    r = run_block(block_path, ['fleet-ops'],
                  env(url, str(log_g), {'JEV_INTAKE_ORDER_FIXTURE_INPROGRESS': str(inprog_cp)}))
    srv.shutdown()
    grow = read_rows(log_g)[0]
    check(grow['tail_guard'] is True, 'two recent CP claims read tail_guard true')
    check(grow['spec_effective'][0] == 'Nishfleet/fleet-ops#23'
          and grow['spec_order'][0] == 'Nishfleet/fleet-ops#25',
          'under the guard the oldest plain issue is the effective spec head')
    check(grow['head_changed'] is True and grow['n_moved'] == 3,
          'Jev promoting #21 is measured against the guarded order (eff head #23)')

    # ---- functional: the head-only cost bound ----------------------------
    srv, url = serve('ok')
    log_cap = tmp / 'cap.jsonl'
    r = run_block(block_path, ['fleet-ops'],
                  env(url, str(log_cap), {'JEV_INTAKE_ORDER_MAX': '2'}))
    srv.shutdown()
    check('scored 2 of 4 ready issues' in r.stdout,
          'a longer queue prints the scored-of-ready coverage line')
    check(r.stdout.count('jev-order: Nishfleet/fleet-ops#') == 2,
          'only the head of the order is scored')
    cap_row = read_rows(log_cap)[0]
    check(cap_row['batch_size'] == 2 and cap_row['ready_total'] == 4 and cap_row['leftover'] == 2,
          'row carries the batch size, the ready total and the leftover tail')
    check(sorted(JevStub.hits[0]['questions']) == ['acq_23', 'acq_25', 'order_23', 'order_25'],
          'the Jev call only asks about the scored head')

    # ---- functional: advisory failure paths ------------------------------
    cases = [
        ('flag off', env(url, str(tmp / 'off.jsonl'), {'JEV_INTAKE_ORDER': '0'}),
         'off (JEV_INTAKE_ORDER=0)', 'off.jsonl'),
        ('dead endpoint', env('http://127.0.0.1:1/jev', str(tmp / 'dead.jsonl')),
         'jev: unavailable (', 'dead.jsonl'),
        ('no key', env(url, str(tmp / 'nokey.jsonl'), {'LITELLM_JEV_KEY': ''}),
         'no LITELLM_JEV_KEY', 'nokey.jsonl'),
        ('missing fixture', env(url, str(tmp / 'nofix.jsonl'),
                                {'JEV_INTAKE_ORDER_FIXTURE_READY': str(tmp / 'nope.json')}),
         'ready-queue fetch failed', 'nofix.jsonl'),
        ('empty queue', env(url, str(tmp / 'emptylog.jsonl'),
                            {'JEV_INTAKE_ORDER_FIXTURE_READY': str(tmp / 'empty.json')}),
         'ready queue empty', 'emptylog.jsonl'),
    ]
    (tmp / 'empty.json').write_text('[]')
    for name, e, needle, logname in cases:
        r = run_block(block_path, ['fleet-ops'], e)
        check(r.returncode == 0, '%s exits 0' % name)
        check(needle in r.stdout, '%s prints %s' % (name, needle))
        check(read_rows(tmp / logname) == [], '%s logs no row' % name)
    r = run_block(block_path, ['bad repo/../x'], env(url, str(tmp / 'badrepo.jsonl')))
    check(r.returncode == 0 and 'bad repo arg' in r.stdout, 'a bad repo arg exits 0 cleanly')

    for mode_name, needle in (('bad', 'invalid answer'), ('oob', 'invalid answer'),
                              ('badscore', 'invalid answer')):
        srv, url = serve(mode_name)
        r = run_block(block_path, ['fleet-ops'], env(url, str(tmp / ('%s.jsonl' % mode_name))))
        srv.shutdown()
        check(r.returncode == 0 and needle in r.stdout,
              'mode=%s prints %s and exits 0' % (mode_name, needle))
        check(read_rows(tmp / ('%s.jsonl' % mode_name)) == [],
              'mode=%s logs nothing' % mode_name)

    # ---- functional: replay ----------------------------------------------
    r = run_block(block_path, ['fleet-ops', '--replay', str(log)], env(url, str(tmp / 'r1.jsonl')))
    check(r.returncode == 0 and 'replay: 1 rows, 0 mismatched' in r.stdout,
          'replay verifies a clean shadow row')
    check('disagreed' in r.stdout and 'head changes' in r.stdout,
          'replay reports the disagreement and head-change counts')
    tampered = tmp / 'tampered.jsonl'
    row2 = dict(row)
    row2['jev_order'] = list(reversed(row['jev_order']))
    tampered.write_text(json.dumps(row2) + '\n')
    r = run_block(block_path, ['fleet-ops', '--replay', str(tampered)],
                  env(url, str(tmp / 'r2.jsonl')))
    check(r.returncode == 1 and 'MISMATCH' in r.stdout,
          'replay fails loud on a row whose stored order does not reproduce')
    r = run_block(block_path, ['fleet-ops', '--replay', str(tmp / 'no-such.jsonl')],
                  env(url, str(tmp / 'r3.jsonl')))
    check(r.returncode == 1 and 'unreadable' in r.stdout,
          'replay fails loud on an unreadable log')

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
