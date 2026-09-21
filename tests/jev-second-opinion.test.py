#!/usr/bin/env python3
"""fleet-ops#7429: worker.md carries the advisory Jev second-opinion block —
same questions POSTed twice with the state serialized item-first then
context-first, plus a disagreement flag. Static prompt-contract assertions
plus a functional pass that runs the embedded block against a stub /jev
endpoint that answers per framing. Run:
python3 tests/jev-second-opinion.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKER = ROOT / 'prompts' / 'worker.md'
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


def main():
    wtext = WORKER.read_text()

    check('## Second-opinion Jev call — reserved-class decisions (fleet-ops#7429' in wtext,
          'worker.md: second-opinion section heading present')
    check('second-opinion-reserved' in wtext, 'worker.md: step-4 wires the reserved site')

    block = extract(wtext, '"<site>" "<ref>" "<card-path>"')
    check(block is not None, 'worker.md: second-opinion block extracted')
    if block is None:
        print('FAILED: missing embedded block', file=sys.stderr)
        sys.exit(1)
    try:
        compile(block, 'worker.md-block', 'exec')
        check(True, 'worker.md: embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'worker.md: embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_SECOND_OPINION', 'second-opinion-summary', 'item-first',
                   'context-first', 'disagreement', '127.0.0.1:4000/jev',
                   'LITELLM_JEV_KEY', 'typesafe-ai/jev', 'needsNish', 'reservedClass',
                   'advisory_only'):
        check(needle in block or needle in wtext, 'worker.md names %s' % needle)
    check("os.environ.get('JEV_SECOND_OPINION', '') in ('0', 'off')" in block,
          'worker.md: off-flag branch present')
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'worker.md: block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'worker.md: key reaches only the Authorization header')
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'worker.md: key variable never interpolated into a print call')

    class Stub(BaseHTTPRequestHandler):
        # per-framing answers table: {'item-first': {...}, 'context-first': {...}}
        table = {}
        posts = []
        fail = False

        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            state = body.get('state')
            state = state if isinstance(state, str) else json.dumps(state)
            framing = ('item-first'
                       if state.find('"item"') < state.find('"context"')
                       else 'context-first')
            Stub.posts.append(framing)
            if Stub.fail:
                self.send_response(500); self.end_headers(); return
            if self.headers.get('Authorization') != 'Bearer test-key-7429':
                self.send_response(401); self.end_headers(); return
            out = json.dumps({'answers': Stub.table.get(framing) or {},
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

    CARD = {'item': {'title': 'buy a GitHub Team plan', 'cost': '$4/user/mo'},
            'context': 'reserved classes: money/pricing, privacy, security, legal, brand, '
                       'product direction, customer-data deletion, destructive/irreversible '
                       'steps, authority Nish explicitly reserved',
            'extra_state': 'kept'}

    run_counter = [0]

    def run_block(td, table=None, fail=False, off=False, card=CARD, key='test-key-7429',
                  bands={'act_hi': 0.5, 'review_lo': 0.5}):
        Stub.table = table or {}
        Stub.posts = []
        Stub.fail = fail
        td = pathlib.Path(td)
        run_counter[0] += 1
        rundir = td / ('run%d' % run_counter[0])
        rundir.mkdir()
        cfile = rundir / 'card.json'
        cfile.write_text(json.dumps(card))
        bfile = rundir / 'block.py'
        bfile.write_text(block)
        bpath = rundir / 'jev-bands.json'
        if bands is not None:
            bpath.write_text(json.dumps({'sites': {'second-opinion-test': bands}}))
        env = dict(os.environ,
                   JEV_SECOND_OPINION_ENDPOINT=endpoint,
                   JEV_SECOND_OPINION_LOG_DIR=str(rundir / 'jev'),
                   JEV_BANDS_FILE=str(bpath))
        if key is None:
            env.pop('LITELLM_JEV_KEY', None)
            env['HOME'] = str(rundir / 'nohome')  # no seat file there
        else:
            env['LITELLM_JEV_KEY'] = key
        if off:
            env['JEV_SECOND_OPINION'] = '0'
        else:
            env.pop('JEV_SECOND_OPINION', None)
        r = subprocess.run(['python3', str(bfile), 'second-opinion-test',
                            'Nishfleet/fleet-ops#1', str(cfile)],
                           capture_output=True, text=True, env=env, timeout=30)
        log = rundir / 'jev' / 'second-opinion-test.jsonl'
        rows = [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []
        return r, rows, list(Stub.posts)

    BOOL = dict(type='boolean')
    QBOOL = {'needsNish': BOOL}

    with tempfile.TemporaryDirectory() as td:
        # 1. agreement: both framings p=0.9 -> disagreement=false, 2 posts, 3 rows
        table = {'item-first': {'needsNish': {'type': 'boolean', 'probability': 0.9}},
                 'context-first': {'needsNish': {'type': 'boolean', 'probability': 0.8}}}
        card = dict(CARD, questions=dict(QBOOL))
        r, rows, posts = run_block(td, table, card=card)
        check(r.returncode == 0, 'agree: exit 0')
        check(posts == ['item-first', 'context-first'],
              'agree: two posts in framing order (got %s)' % posts)
        check('disagreement=false' in r.stdout, 'agree: verdict false (%s)' % r.stdout.strip())
        kinds = [x.get('kind', 'call') for x in rows]
        check(kinds == ['call', 'call', 'second-opinion-summary'],
              'agree: two call rows + summary (got %s)' % kinds)
        check([x.get('framing') for x in rows[:2]] == ['item-first', 'context-first'],
              'agree: call rows carry framing')
        check(rows[-1].get('second_opinion', {}).get('disagreement') is False,
              'agree: summary disagreement false')
        check(all(x.get('advisory_only') is True for x in rows), 'agree: rows advisory_only')
        check(all(x.get('act_hi') == 0.5 and x.get('review_lo') == 0.5 for x in rows),
              'agree: rows stamp the site band edges from the table')
        check(rows[-1].get('edge') == 0.5, 'agree: summary records the split edge')
        check('extra_state' not in json.dumps(rows), 'agree: raw state not logged')

        # 2. disagreement: opposite sides of 0.5 -> true
        table = {'item-first': {'needsNish': {'type': 'boolean', 'probability': 0.9}},
                 'context-first': {'needsNish': {'type': 'boolean', 'probability': 0.2}}}
        r, rows, posts = run_block(td, table, card=card)
        check('disagreement=true' in r.stdout, 'disagree-bool: verdict true (%s)' % r.stdout.strip())
        check(rows and rows[-1].get('second_opinion', {}).get('disagreement') is True,
              'disagree-bool: summary true')

        # 3. boundary: a boolean exactly 0.5 -> null
        table = {'item-first': {'needsNish': {'type': 'boolean', 'probability': 0.5}},
                 'context-first': {'needsNish': {'type': 'boolean', 'probability': 0.9}}}
        r, rows, posts = run_block(td, table, card=card)
        check('disagreement=null' in r.stdout, 'boundary: verdict null (%s)' % r.stdout.strip())

        # 4. choice differs -> true
        qchoice = {'reservedClass': dict(type='choice', criteria={'a': 'A', 'b': 'B'})}
        table = {'item-first': {'reservedClass': {'type': 'choice', 'choice': 'a'}},
                 'context-first': {'reservedClass': {'type': 'choice', 'choice': 'b'}}}
        r, rows, posts = run_block(td, table, card=dict(CARD, questions=qchoice))
        check('disagreement=true' in r.stdout, 'choice-diff: verdict true (%s)' % r.stdout.strip())

        # 5. score differs -> true; equal scores -> false
        qscore = {'quality': dict(type='score')}
        table = {'item-first': {'quality': {'type': 'score', 'score': 3}},
                 'context-first': {'quality': {'type': 'score', 'score': 4}}}
        r, _, _ = run_block(td, table, card=dict(CARD, questions=qscore))
        check('disagreement=true' in r.stdout, 'score-diff: verdict true (%s)' % r.stdout.strip())
        table['context-first'] = {'quality': {'type': 'score', 'score': 3}}
        r, _, _ = run_block(td, table, card=dict(CARD, questions=qscore))
        check('disagreement=false' in r.stdout, 'score-same: verdict false (%s)' % r.stdout.strip())

        # 6. off flag -> single call, no summary row
        table = {'item-first': {'needsNish': {'type': 'boolean', 'probability': 0.9}}}
        r, rows, posts = run_block(td, table, off=True, card=card)
        check(len(posts) == 1, 'off: one post only (got %s)' % posts)
        check('JEV_SECOND_OPINION=0' in r.stdout, 'off: verdict names the flag')
        check(not any(x.get('kind') == 'second-opinion-summary' for x in rows),
              'off: no summary row')

        # 7. endpoint failure -> unavailable, exit 0, no rows beyond what logged
        r, rows, posts = run_block(td, fail=True, card=card)
        check(r.returncode == 0, 'fail: exit 0')
        check('unavailable' in r.stdout, 'fail: unavailable line (%s)' % r.stdout.strip())

        # 8. no seat key -> unavailable, exit 0, no posts
        r, rows, posts = run_block(td, key=None, card=card)
        check(r.returncode == 0 and 'unavailable (no seat key)' in r.stdout,
              'nokey: unavailable, exit 0')
        check(posts == [], 'nokey: no posts made')

        # 9. card missing context -> unavailable, exit 0
        r, _, _ = run_block(td, card={'item': {'x': 1}})
        check('unavailable (card needs item and context)' in r.stdout,
              'badcard: unavailable, exit 0')

        # 10. custom questions in the card drive the calls (generic pattern)
        q = {'risky': BOOL}
        table = {'item-first': {'risky': {'type': 'boolean', 'probability': 0.1}},
                 'context-first': {'risky': {'type': 'boolean', 'probability': 0.9}}}
        r, rows, posts = run_block(td, table, card=dict(CARD, questions=q))
        check('risky=' in r.stdout and 'disagreement=true' in r.stdout,
              'custom-q: verdict uses card questions (%s)' % r.stdout.strip())

        # 11. fleet-ops#7439: the table's act_hi is the split edge — 0.55 vs
        # 0.7 agree at the 0.5 default but disagree at a tuned 0.6 edge, and
        # a missing table leaves booleans unknown -> disagreement=null.
        table = {'item-first': {'needsNish': {'type': 'boolean', 'probability': 0.55}},
                 'context-first': {'needsNish': {'type': 'boolean', 'probability': 0.7}}}
        r, rows, _ = run_block(td, table, card=card)
        check('disagreement=false' in r.stdout,
              'default edge 0.5: 0.55 vs 0.7 agree (%s)' % r.stdout.strip())
        r, rows, _ = run_block(td, table, card=card,
                               bands={'act_hi': 0.6, 'review_lo': 0.4})
        check('disagreement=true' in r.stdout,
              'tuned edge 0.6: 0.55 vs 0.7 disagree (%s)' % r.stdout.strip())
        check(rows and rows[-1].get('edge') == 0.6, 'summary records tuned edge')
        r, rows, _ = run_block(td, table, card=card, bands=None)
        check('disagreement=null' in r.stdout,
              'missing table: boolean pairs unknown -> null (%s)' % r.stdout.strip())
        check(rows and rows[-1].get('edge') is None
              and rows[-1].get('act_hi') is None,
              'missing table: rows record null edges')

    print('---')
    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('all checks passed')


if __name__ == '__main__':
    main()
