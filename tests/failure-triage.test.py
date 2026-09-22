#!/usr/bin/env python3
"""fleet-ops#7780: the advisory failure-triage shadow tier.

The countable part is code, the judgement is one Jev call. This test pins the
contract:

1. The three packet readers call the shared helper; none carries an inline
   program of its own (the seat-fault prompts must stay under their line
   ceilings too).
2. Tail tagging is code: the last <=255 lines, L001..L255, one Jev call over
   the tagged ids; counting and duration maths never reach Jev.
3. The Jev call carries exactly the three questions, the six classes, and
   the evidence window stamps; the packet's own verdict is withheld from the
   state so Jev is not biased.
4. The row joins to the real unit outcome: unit name, timestamp, evidence
   window, advisory_only, site, the band edges it ran under.
5. The boolean question is answered from the probability, not a value field.
6. Fail-open: off flag, dead endpoint, garbage response, a bad cause line,
   or no evidence all print one unavailable line and exit 0, writing nothing.
7. Secrets are scrubbed before evidence reaches Jev.
8. --replay validates every row's shape and rejects a tampered cause line.

Run: python3 tests/failure-triage.test.py
"""
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / 'lib' / 'failure_triage.py'
FIXTURES = ROOT / 'tests' / 'fixtures'
PROMPTS = [ROOT / 'prompts' / 'alert-repair.md',
           ROOT / 'prompts' / 'intake-repair.md',
           ROOT / 'prompts' / 'scout-repair.md']
HEADING = '## Shadow Jev tier — failure triage, advisory, never a gate (fleet-ops#7780)'
# fleet-ops#7772 caps the prose the seat-fault table replaced; fleet-ops#7780
# must not grow the repair prompts beyond what these ceilings allow.
PROMPT_CEILING = {'intake-repair.md': 11, 'scout-repair.md': 17}
CLASSES = ['runner-gone', 'concurrency-blocked', 'flaky-test', 'real-failure',
           'seat-wall-429-or-empty', 'deadline']
FAILS = []

STUB = {'cause': 'L004', 'cause_p': 0.82, 'klass': 'runner-gone',
        'visible': 0.9, 'calls': 0, 'last_body': None, 'mode': 'ok'}


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        STUB['calls'] += 1
        STUB['last_body'] = body
        self.rfile.close()
        if self.headers.get('Authorization') != 'Bearer stub-key-7780':
            self.send_response(401)
            self.end_headers()
            return
        if STUB['mode'] == 'garbage':
            payload = b'not json at all'
        elif STUB['mode'] == 'bad-choice':
            payload = json.dumps({'answers': {
                'cause_line': {'type': 'choice', 'choice': 'L999',
                               'probabilities': {'L999': 1.0}},
                'failure_class': {'type': 'choice', 'choice': 'runner-gone',
                                  'probabilities': {'runner-gone': 1.0}},
                'cause_visible_in_tail': {'type': 'boolean', 'probability': 0.4}}}).encode()
        elif STUB['mode'] == 'bad-class':
            payload = json.dumps({'answers': {
                'cause_line': {'type': 'choice', 'choice': STUB['cause'],
                               'probabilities': {STUB['cause']: STUB['cause_p']}},
                'failure_class': {'type': 'choice', 'choice': 'seat-fault',
                                  'probabilities': {'seat-fault': 1.0}},
                'cause_visible_in_tail': {'type': 'boolean', 'probability': 0.4}}}).encode()
        elif STUB['mode'] == 'no-probability':
            payload = json.dumps({'answers': {
                'cause_line': {'type': 'choice', 'choice': STUB['cause']},
                'failure_class': {'type': 'choice', 'choice': STUB['klass'],
                                  'probabilities': {STUB['klass']: 0.9}},
                'cause_visible_in_tail': {'type': 'boolean', 'probability': 0.4}}}).encode()
        else:
            cause_probs = {STUB['cause']: STUB['cause_p'], 'L001': 0.08, 'L002': 0.1}
            payload = json.dumps({'answers': {
                'cause_line': {'type': 'choice', 'choice': STUB['cause'],
                               'probabilities': cause_probs},
                'failure_class': {'type': 'choice', 'choice': STUB['klass'],
                                  'probabilities': {k: p for k, p in [
                                      (c, 0.8 if c == STUB['klass'] else 0.04)
                                      for c in CLASSES]}},
                'cause_visible_in_tail': {'type': 'boolean',
                                          'probability': STUB['visible']}},
                'usage': {'total_tokens': 310}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def env(log, endpoint, extra=None):
    base = dict(os.environ,
                JEV_BANDS_FILE=str(ROOT / 'config' / 'jev-bands.json'),
                LITELLM_JEV_KEY='stub-key-7780',
                JEV_FAILURE_TRIAGE_ENDPOINT=endpoint,
                JEV_FAILURE_TRIAGE_LOG=str(log))
    base.pop('JEV_FAILURE_TRIAGE', None)
    base.pop('JEV_FAILURE_TRIAGE_FIXTURE', None)
    base.update(extra or {})
    return base


def run(log, endpoint, argv, evidence=None, extra=None):
    return subprocess.run([sys.executable, str(HELPER)] + argv,
                          input=evidence, capture_output=True, text=True,
                          env=env(log, endpoint, extra), timeout=90)


def rows(log):
    if not pathlib.Path(log).exists():
        return []
    return [json.loads(l) for l in pathlib.Path(log).read_text().splitlines() if l.strip()]


def main():
    tmp = tempfile.mkdtemp(prefix='failure-triage-')
    log = os.path.join(tmp, 'failure-triage.jsonl')
    SERVER = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=SERVER.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % SERVER.server_port

    # 1. The three packet readers call the shared helper, not an inline program.
    target = {}
    for path in PROMPTS:
        text = path.read_text()
        target[path.name] = text
        check('lib/failure_triage.py' in text, '%s invokes the shared triage helper' % path.name)
        check('failure-triage.jsonl' in text, '%s names the shadow log' % path.name)
        check('failure-triage' in text, '%s names the site' % path.name)
        if path.name != 'alert-repair.md':
            check('python3 - <<' not in text, '%s carries no inline program' % path.name)
    check(HEADING in target['alert-repair.md'],
          'alert-repair.md carries the #7780 shadow section')
    section = target['alert-repair.md'].split(HEADING, 1)[1]
    check('python3 - <<' not in section, 'the #7780 section carries no inline program')
    check('lib/failure_triage.py' in section, 'the #7780 section calls the shared helper')
    lines = target['alert-repair.md'].splitlines()
    first = next((i for i, l in enumerate(lines) if l.startswith('## Shadow Jev tier')), -1)
    check(all(l.startswith('## Shadow Jev tier')
              for l in lines[first:] if l.startswith('## ')),
          'alert-repair.md: only shadow sections after the first shadow section')
    for name in ('intake-repair.md', 'scout-repair.md'):
        check(len(target[name].splitlines()) <= PROMPT_CEILING[name],
              '%s stays at most %d lines (is %d)'
              % (name, PROMPT_CEILING[name], len(target[name].splitlines())))
    for klass in CLASSES:
        check(klass in target['alert-repair.md'] and klass in HELPER.read_text(),
              'the six-class taxonomy is stated in alert-repair.md and code (%s)' % klass)

    # 2 + 4. One call, tagged tail, a row that joins to the real unit outcome.
    for fixture, unit, repo, expected_class in (
            ('failure-triage-runner-gone.log', 'pi-issue@fleet-ops-9.service', None,
             'runner-gone'),
            ('failure-triage-concurrency-blocked.log', 'gha-runner.service', None,
             'concurrency-blocked'),
            ('failure-triage-real-failure.log', 'pi-intake@fleet-ops.service', None,
             'real-failure'),
            ('failure-triage-seat-wall.log', 'gha-runner.service', None,
             'seat-wall-429-or-empty'),
            ('failure-triage-deadline.log', 'gha-runner.service', None,
             'deadline')):
        STUB.update({'calls': 0, 'last_body': None, 'mode': 'ok',
                     'cause': 'L004', 'klass': expected_class})
        argv = ['--alertname', 'SystemUnitFailed',
                '--unit', unit or '-', '--decided', 'lane-fault']
        if repo:
            argv += ['--repo', repo]
        before = len(rows(log))
        got = run(log, endpoint, argv, evidence=pathlib.Path(FIXTURES / fixture).read_text())
        check(got.returncode == 0, '%s: exit 0 (stderr: %s)' % (fixture, got.stderr.strip()[:200]))
        out = got.stdout.strip().splitlines()
        check(len(out) == 1 and out[0].startswith('failure-triage:'),
              '%s: one failure-triage line on stdout' % fixture)
        check('stub-key-7780' not in got.stdout + got.stderr,
              '%s: key never printed' % fixture)
        check(STUB['calls'] == 1, '%s: exactly one Jev call' % fixture)
        check(len(rows(log)) == before + 1, '%s: one row appended' % fixture)
        row = rows(log)[-1]
        check(row.get('site') == 'failure-triage', '%s: row site' % fixture)
        check(row.get('advisory_only') is True and row.get('mode') == 'shadow',
              '%s: row is advisory-only shadow' % fixture)
        check(row.get('unit') == (unit or None) and row.get('repo') == repo,
              '%s: row records the unit and repo' % fixture)
        try:
            ts = datetime.datetime.fromisoformat(row['ts'])
            ok_ts = ts.tzinfo is not None
        except Exception:
            ok_ts = False
        check(ok_ts, '%s: row timestamp is a real stamped instant' % fixture)
        check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
              '%s: row carries a state digest' % fixture)
        check(row.get('act_hi') == 0.9 and row.get('review_lo') == 0.1,
              '%s: row stamps the table edges it ran under' % fixture)
        check(row.get('decided_by_prompt') == 'lane-fault',
              '%s: row carries the packet verdict beside Jev answer' % fixture)
        check(row.get('failure_class') == expected_class,
              '%s: row carries the classified class' % fixture)
        check(row.get('cause_line') == 'L004', '%s: row names the cause line' % fixture)
        check(row.get('cause_visible_p') == 0.9,
              '%s: row carries the visible probability' % fixture)
        check(row.get('usage', {}).get('total_tokens') == 310,
              '%s: row carries usage' % fixture)
        window = row.get('evidence_window') or {}
        stamps = [window.get('first_ts'), window.get('last_ts')]
        check(all(re.match(r'^\d{4}-\d{2}-\d{2}T', s or '') is not None for s in stamps),
              '%s: evidence window joins to the real unit timestamps' % fixture)
        last_body = STUB['last_body'] or {}
        lines_state = (last_body.get('state') or {}).get('lines') or []
        n_lines = len(lines_state)
        check(n_lines <= 255, '%s: tail never exceeds 255 lines' % fixture)
        check([l.get('id') for l in lines_state][:2] == ['L001', 'L002']
              and [l.get('id') for l in lines_state][-1] == 'L%03d' % n_lines,
              '%s: lines are tagged L001..' % fixture)
        # The decision is withheld from Jev's state.
        check('decided_by_prompt' not in json.dumps(last_body.get('state') or {}),
              '%s: the packet verdict is withheld from Jev' % fixture)

    # 2 + 5. The boolean answers from the probability and lands on the row.
    STUB.update({'calls': 0, 'last_body': None, 'mode': 'ok', 'klass': 'real-failure'})
    STUB.update({'visible': 0.35})
    got = run(log, endpoint, ['--alertname', 'X', '--unit', 'pi-intake@fleet-ops.service',
                              '--decided', 'x'],
              evidence=pathlib.Path(FIXTURES / 'failure-triage-real-failure.log').read_text())
    check(got.returncode == 0 and 'cause_visible=0.350' in got.stdout,
          'boolean below the midpoint prints the probability')
    row = rows(log)[-1]
    check(row.get('cause_visible_in_tail') is False,
          'boolean below the midpoint prints false')

    STUB.update({'visible': 0.55})
    got = run(log, endpoint, ['--alertname', 'X', '--unit', 'pi-intake@fleet-ops.service',
                              '--decided', 'x'],
              evidence=pathlib.Path(FIXTURES / 'failure-triage-real-failure.log').read_text())
    row = rows(log)[-1]
    check(row.get('cause_visible_in_tail') is True,
          'boolean above the midpoint prints true')

    # 2. Evidence beyond 255 lines is cut to the last 255, in code.
    for n_in, expect in ((300, 255), (900, 255), (120, 120)):
        STUB.update({'calls': 0, 'last_body': None, 'cause': 'L001'})
        text = "\n".join('2026-09-23T07:31:%02dZ looper %d' % (i % 60, i)
                         for i in range(n_in)) + '\n'
        before = len(rows(log))
        got = run(log, endpoint, ['--alertname', 'X', '--unit', 'pi-intake@fleet-ops.service',
                                  '--decided', 'x'], evidence=text)
        check(got.returncode == 0, '%d-line evidence: exit 0' % n_in)
        check(STUB['calls'] == 1, '%d-line evidence: one call' % n_in)
        row = rows(log)[-1]
        check(row['evidence_lines'] == expect,
              '%d-line evidence: row records %d tagged lines (is %r)'
              % (n_in, expect, row['evidence_lines']))
        ids = [l.get('id') for l in (STUB['last_body'].get('state') or {}).get('lines') or []]
        check(len(ids) == expect and ids[:2] == ['L001', 'L002'] and ids[-1] == 'L%03d' % expect,
              '%d-line evidence: tagged ids span L001..' % n_in)
        check(len(rows(log)) == before + 1, '%d-line evidence: one row' % n_in)

    # 6. Off flag: the helper prints one off line and writes nothing.
    before = len(rows(log))
    got = run(log, endpoint, ['--alertname', 'X', '--unit', '-', '--decided', 'x'],
              evidence='anything', extra={'JEV_FAILURE_TRIAGE': '0'})
    check(got.returncode == 0 and 'failure-triage: off; rules unchanged' in got.stdout,
          'flag=0 prints the off line')
    check(len(rows(log)) == before, 'flag=0 writes no row')

    # 6. Fail open: bad endpoint, garbage, bad answer, no evidence.
    STUB.update({'calls': 0, 'mode': 'ok'})
    before = len(rows(log))
    got = run(log, 'http://127.0.0.1:1/jev',
              ['--alertname', 'X', '--unit', '-', '--decided', 'x'],
              evidence='some tail\n')
    check(got.returncode == 0 and 'failure-triage: unavailable' in got.stdout,
          'dead endpoint: unavailable line, exit 0')
    for mode, label in (('garbage', 'garbage response'),
                        ('bad-choice', 'line id outside the tail'),
                        ('bad-class', 'unknown class'),
                        ('no-probability', 'probability left out')):
        STUB.update({'mode': mode, 'calls': 0})
        got = run(log, endpoint, ['--alertname', 'X', '--unit', '-', '--decided', 'x'],
                  evidence='some tail\n')
        check(got.returncode == 0 and 'failure-triage: unavailable' in got.stdout,
              '%s: unavailable line, exit 0' % label)
        check(STUB['calls'] == 1 and 'stub-key' not in got.stderr,
              '%s: one call, no leak' % label)
    check(len(rows(log)) == before, 'all fail-open paths wrote no row')
    STUB.update({'mode': 'ok'})

    got = run(log, endpoint, ['--alertname', 'X', '--unit', '-', '--decided', 'x'],
              evidence='')
    check(got.returncode == 0 and 'unavailable (no evidence)' in got.stdout,
          'no evidence: unavailable line, exit 0')

    # 7. Evidence is untrusted data: credential shapes never reach Jev.
    # Shapes are built at runtime so no fake literal lands in a committed
    # line (gitleaks), while still matching lib's SECRET_RE patterns.
    STUB.update({'calls': 0, 'last_body': None, 'mode': 'ok', 'cause': 'L001'})
    before = len(rows(log))
    sk_shape = 'sk-' + 'a' * 16
    bearer_shape = 'Bearer' + ' ' + 'b' * 16
    jwt_shape = 'eyJ' + 'c' * 30
    secret_tail = ('2026-09-23T07:00:00Z token=%s hello\n' % sk_shape
                   + '2026-09-23T07:00:01Z Authorization: %s\n' % bearer_shape
                   + '2026-09-23T07:00:02Z fallback=%s\n' % jwt_shape)
    got = run(log, endpoint, ['--alertname', 'X', '--unit', 'pi-intake@fleet-ops.service',
                              '--decided', 'x'], evidence=secret_tail)
    check(got.returncode == 0 and len(rows(log)) == before + 1, 'secret tail: triage still runs')
    sent = json.dumps(STUB.get('last_body') or {})
    for shape in (sk_shape, bearer_shape, jwt_shape):
        check(shape not in sent, 'credential shape scrubbed from the Jev payload (%s)' % shape)
    check(any('<redacted>' in l['text']
              for l in (STUB.get('last_body').get('state') or {}).get('lines') or []),
          'the scrubbed lines still land in the payload')

    # 8. The row carries the long-tail trim and a long line is truncated.
    STUB.update({'calls': 0, 'last_body': None, 'cause': 'L001'})
    before = len(rows(log))
    long_line = 'x' * 5000
    got = run(log, endpoint, ['--alertname', 'X', '--unit', 'pi-intake@fleet-ops.service',
                              '--decided', 'x'],
              evidence='2026-09-23T07:00:00Z ok\n' + long_line + '\n')
    check(got.returncode == 0 and len(rows(log)) == before + 1, 'long line: triage still runs')
    lines_state = (STUB.get('last_body').get('state') or {}).get('lines') or []
    check(lines_state and all(len(l['text']) <= 800 for l in lines_state),
          'each line is truncated to 800 chars before it reaches Jev')

    # 8. Replay: rows re-validate; a tampered cause line is rejected.
    got = subprocess.run([sys.executable, str(HELPER), '--replay', log],
                         capture_output=True, text=True, timeout=60)
    check(got.returncode == 0 and re.search(r'\d+ rows, 0 invalid', got.stderr) is not None,
          'replay of the clean log passes (%s)' % got.stderr.strip().splitlines()[-1:])
    replay_rows = rows(log)
    replay_rows[-1]['cause_line'] = 'L999'
    tampered = log + '.tampered'
    pathlib.Path(tampered).write_text('\n'.join(json.dumps(r) for r in replay_rows) + '\n')
    got = subprocess.run([sys.executable, str(HELPER), '--replay', tampered],
                         capture_output=True, text=True, timeout=60)
    check(got.returncode != 0, 'replay rejects a cause line outside the tagged tail')

    SERVER.shutdown()
    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
