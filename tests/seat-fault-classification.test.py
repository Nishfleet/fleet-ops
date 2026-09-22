#!/usr/bin/env python3
"""fleet-ops#7772 (jev T5): the seat-fault classification contract.

The repair prompts must classify a failed unit on HTTP status and retry
semantics, deterministically, in code — and may only ask Jev choice(3) when
the status is genuinely ambiguous, behind a flag that is OFF by default. This
test pins the contract:

1. Both repair prompts call the shared classifier; neither carries an inline
   program of its own, and both stayed shorter than the prose they replaced.
2. The anchor table is code: 402/quota_exhausted/credentials_bad/corpse money,
   429/rate_limited/overload/connection-refused/spawn-timeout lane.
3. Deterministic evidence never reaches Jev, even with the shadow tier armed.
4. Uncovered or absent status falls back to the prose reading with the flag
   off, and no shadow row is written.
5. Armed shadow: one JSONL row at the site, carrying Jev's answer beside the
   prompt's own reading, acting on neither.
6. Armed flip: a confident answer steers the verdict; below the bands floor
   it parks for the orchestrator — the floor comes from config/jev-bands.json.
7. Any Jev-side failure falls back to the prose reading and still exits 0.
8. The shadow log replays: re-deriving every row's table verdict reproduces
   it, and a row whose evidence changed fails the replay.

Run: python3 tests/seat-fault-classification.test.py
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / 'lib' / 'seat_fault.py'
PROMPTS = [ROOT / 'prompts' / 'intake-repair.md', ROOT / 'prompts' / 'scout-repair.md']
# The prompt line counts the deterministic table replaced (fleet-ops#7772).
PROMPT_CEILING = {'intake-repair.md': 11, 'scout-repair.md': 17}
FAILS = []

# The stub /jev tier: what it answers, how many calls it saw, and the last
# state it was handed.
STUB = {'choice': 'lane-fault', 'p': 0.9, 'calls': 0, 'state': None, 'mode': 'json'}


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


class JeV(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        STUB['calls'] += 1
        STUB['state'] = body.get('state')
        if STUB['mode'] == 'garbage':
            payload = b'not json at all'
        else:
            probs = {'lane-fault': STUB['p'], 'money-wall': 0.0, 'other': 0.0}
            probs[STUB['choice']] = STUB['p']
            probs['other'] = round(1.0 - STUB['p'], 4)
            if STUB['p'] == 0.9:
                probs = {'lane-fault': 0.9, 'money-wall': 0.05, 'other': 0.05}
            payload = json.dumps({'answers': {'seat_fault_class': {
                'choice': STUB['choice'], 'probabilities': probs}},
                'usage': {'total_tokens': 42}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def run(evidence, *extra, env=None):
    environ = dict(os.environ)
    environ.update({
        'JEV_BANDS_FILE': str(ROOT / 'config' / 'jev-bands.json'),
        'JEV_SEATFAULT_ENDPOINT': 'http://127.0.0.1:%d/jev' % SERVER.server_port,
        'JEV_SEATFAULT_LOG': LOG,
        'LITELLM_JEV_KEY': 'stub-key',
    })
    environ.pop('JEV_SEATFAULT_SHADOW', None)
    environ.pop('JEV_SEATFAULT_ACT', None)
    environ.update(env or {})
    return subprocess.run([sys.executable, str(HELPER), '--decided', 'other', '--unit',
                           'pi-intake@fleet-ops.service', *extra],
                          input=evidence, capture_output=True, text=True, env=environ,
                          timeout=90)


def rows():
    if not pathlib.Path(LOG).exists():
        return []
    return [json.loads(line) for line in pathlib.Path(LOG).read_text().splitlines() if line.strip()]


def clear_log():
    pathlib.Path(LOG).unlink(missing_ok=True)


def main():
    global SERVER, LOG
    tmp = tempfile.mkdtemp(prefix='seat-fault-')
    LOG = os.path.join(tmp, 'intake-repair-seatfault.jsonl')
    SERVER = HTTPServer(('127.0.0.1', 0), JeV)
    threading.Thread(target=SERVER.serve_forever, daemon=True).start()

    # 1. The prompts call the shared classifier and did not grow.
    for path in PROMPTS:
        text = path.read_text()
        check('lib/seat_fault.py' in text, '%s calls the shared classifier' % path.name)
        check('python3 - <<' not in text, '%s carries no inline program' % path.name)
        check(len(text.splitlines()) <= PROMPT_CEILING[path.name],
              '%s is at most %d lines (is %d)'
              % (path.name, PROMPT_CEILING[path.name], len(text.splitlines())))

    # 2. The anchor table is code, and only the helper carries it.
    src = HELPER.read_text()
    for literal in ('402', '429', 'quota_exhausted', 'credentials_bad', 'corpse',
                    'seat_dead', 'rate_limited', 'overloaded_error', 'overload',
                    'connection refused', 'spawn timeout'):
        check(literal in src, 'table anchors %r in code' % literal)
    for path in PROMPTS:
        check('quota_exhausted' not in path.read_text(),
              '%s no longer restates the classification table' % path.name)

    # 3. Deterministic evidence never reaches Jev, even with shadow armed.
    for evidence, expected in (
            ('litellm: HTTP 429 rate_limited from grok-4.6, retry-after 30', 'lane-fault'),
            ('HTTP 402 quota_exhausted: credit balance depleted', 'money-wall'),
            ('HTTP 429 overloaded_error and HTTP 402 insufficient credits', 'money-wall'),
            ('ERROR ConnectionRefusedError; pi spawn timeout after 1800s', 'lane-fault'),
            ('channel closed unexpectedly; no seat evidence recorded', 'ambiguous')):
        clear_log()
        STUB['calls'] = 0
        got = run(evidence, env={'JEV_SEATFAULT_SHADOW': '1'})
        verdict = [w for w in got.stdout.split() if w.startswith('verdict=')][0]
        deterministic = expected != 'ambiguous'
        check(verdict == 'verdict=%s' % expected,
              '%r -> %s' % (evidence[:34], expected))
        check(STUB['calls'] == (0 if deterministic else 1),
              ('no Jev call for covered status' if deterministic
               else 'Jev called for the ambiguous record'))
        check(len(rows()) == (0 if deterministic else 1),
              'shadow row count %d' % (0 if deterministic else 1))

    # 4. Flag off: ambiguous evidence falls back to prose, writes nothing.
    clear_log()
    STUB['calls'] = 0
    got = run('HTTP 500 internal server error; upstream returned garbage')
    check('verdict=ambiguous source=fallback' in got.stdout,
          'uncovered status falls back with the flag off')
    check(STUB['calls'] == 0 and not rows(), 'flag off: no Jev call and no row')

    # 5. Armed shadow: Jev answers on an ambiguous record, nothing is acted on.
    clear_log()
    STUB.update({'calls': 0, 'choice': 'money-wall', 'p': 0.9, 'mode': 'json'})
    got = run('HTTP 500 upstream error, wording suggests a quota problem',
              env={'JEV_SEATFAULT_SHADOW': '1'})
    check('verdict=ambiguous source=shadow' in got.stdout,
          'shadow reports ambiguous and acts on neither answer')
    check(STUB['calls'] == 1, 'shadow asked Jev once')
    row = (rows() or [None])[0] or {}
    check(row.get('site') == 'intake-repair-seatfault' and row.get('advisory_only') is True,
          'shadow row lands at the site, advisory-only')
    check(row.get('jev', {}).get('choice') == 'money-wall'
          and row.get('decided_by_prompt') == 'other',
          "row carries Jev's answer beside the prompt's own reading")
    check(row.get('verdict_table') is None and row.get('park') is False,
          'row records that the table found nothing and nothing was parked')
    state = STUB['state'] or {}
    for key in ('http_trail', 'retry_semantics', 'money_boundary', 'seat_health_ledger'):
        check(key in state, 'Jev state carries %s' % key)
    check('balance' in state.get('money_boundary', ''),
          'Jev state carries the canonical money boundary')
    check(row.get('act_hi') == 0.6 and row.get('review_lo') == 0.6,
          'row stamps the floor it would have used, from config/jev-bands.json')

    # 6. The flip: a confident answer steers, a hesitant one parks.
    clear_log()
    STUB.update({'calls': 0, 'choice': 'lane-fault', 'p': 0.9})
    got = run('HTTP 500 upstream error', env={'JEV_SEATFAULT_ACT': '1'})
    check('verdict=lane-fault source=jev' in got.stdout, 'flip: confident answer steers')
    STUB.update({'choice': 'money-wall', 'p': 0.25})
    got = run('HTTP 500 upstream error', env={'JEV_SEATFAULT_ACT': '1'})
    check('verdict=ambiguous source=jev' in got.stdout and 'park=yes' in got.stdout,
          'flip: below the floor parks for the orchestrator')

    # 7. Any Jev-side failure falls back and still exits 0.
    for mode, label in (('garbage', 'unparseable response'),):
        clear_log()
        STUB.update({'mode': mode, 'calls': 0})
        got = run('HTTP 500 upstream error', env={'JEV_SEATFAULT_SHADOW': '1'})
        check(got.returncode == 0 and 'verdict=ambiguous source=fallback' in got.stdout,
              '%s falls back to prose, exit 0' % label)
        check((rows() or [{}])[0].get('jev_error'), '%s is recorded in the row' % label)
    clear_log()
    got = run('HTTP 500 upstream error', env={'JEV_SEATFAULT_SHADOW': '1',
                                             'JEV_SEATFAULT_ENDPOINT': 'http://127.0.0.1:1/jev'})
    check(got.returncode == 0 and 'verdict=ambiguous source=fallback' in got.stdout,
          'a dead endpoint falls back to prose, exit 0')
    STUB['mode'] = 'json'

    # 8. The log replays, and a tampered row does not.
    clear_log()
    STUB.update({'calls': 0, 'choice': 'lane-fault', 'p': 0.9})
    run('HTTP 500 upstream error', env={'JEV_SEATFAULT_SHADOW': '1'})
    got = subprocess.run([sys.executable, str(HELPER), '--replay', LOG],
                         capture_output=True, text=True, timeout=60)
    check(got.returncode == 0 and '1 rows, 0 invalid' in got.stderr, 'shadow log replays clean')
    log_rows = rows()
    log_rows[0]['evidence'] = 'HTTP 402 quota_exhausted: balance depleted'
    pathlib.Path(LOG).write_text(json.dumps(log_rows[0]) + '\n')
    got = subprocess.run([sys.executable, str(HELPER), '--replay', LOG],
                         capture_output=True, text=True, timeout=60)
    check(got.returncode == 1 and 'table verdict moved' in got.stderr,
          'a row whose evidence changed fails the replay')

    SERVER.shutdown()
    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
