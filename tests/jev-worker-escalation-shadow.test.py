#!/usr/bin/env python3
"""fleet-ops#7773: worker.md carries the worker-escalation-target shadow —
one log-only Jev boolean (nish_reserved) recorded beside the worker's own
step-4 park choice, behind a flag that defaults OFF. Static prompt-contract
assertions plus a functional pass that runs the embedded block against a
stub /jev endpoint, plus a replay mode that re-reads a shadow JSONL log and
recomputes the p-vs-worker_choice comparison per row.

Run:
python3 tests/jev-worker-escalation-shadow.test.py
python3 tests/jev-worker-escalation-shadow.test.py --replay <path-to.jsonl>
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKER = ROOT / 'prompts' / 'worker.md'
SITE = 'worker-escalation-target'
REF_RE = re.compile(r'^Nishfleet/[A-Za-z0-9._-]{1,100}#\d{1,7}$')
SHA_RE = re.compile(r'^[0-9a-f]{64}$')
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


def replay_log(path):
    """Re-read a shadow JSONL log and recompute the comparison the site
    exists for: nish_reserved p vs the worker_choice that was actually
    parked. Returns (rows, stats) — stats carries agree/disagree/unknown
    tallies against each row's own stamped act_hi edge."""
    rows = []
    bad = []
    for i, line in enumerate(pathlib.Path(path).read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            bad.append(i)
            continue
        rows.append(row)
    stats = dict(n=len(rows), bad_lines=len(bad), agree=0, disagree=0,
                 unknown=0, nish_decision=0, orchestrator=0, other=0)
    valid = True
    for row in rows:
        ok = (row.get('site') == SITE
              and isinstance(row.get('ref'), str) and REF_RE.match(row['ref'])
              and isinstance(row.get('state_sha256'), str)
              and SHA_RE.match(row['state_sha256'])
              and isinstance(row.get('p'), (int, float))
              and not isinstance(row.get('p'), bool)
              and 0 <= row['p'] <= 1
              and isinstance(row.get('worker_choice'), str)
              and row['worker_choice'])
        if not ok:
            valid = False
            bad.append('schema')
            continue
        choice = row['worker_choice']
        stats['nish_decision' if choice == 'nish-decision'
              else 'orchestrator' if choice == 'orchestrator'
              else 'other'] += 1
        edge = row.get('act_hi')
        if not isinstance(edge, (int, float)) or isinstance(edge, bool):
            stats['unknown'] += 1
            continue
        predicted = row['p'] >= edge
        actual = choice == 'nish-decision'
        stats['agree' if predicted == actual else 'disagree'] += 1
    return rows, stats, valid and not bad


def main():
    if '--replay' in sys.argv:
        path = sys.argv[sys.argv.index('--replay') + 1]
        rows, stats, clean = replay_log(path)
        print('replay: n=%d bad=%d agree=%d disagree=%d unknown=%d '
              '(choices: nish-decision=%d orchestrator=%d other=%d)'
              % (stats['n'], stats['bad_lines'], stats['agree'],
                 stats['disagree'], stats['unknown'], stats['nish_decision'],
                 stats['orchestrator'], stats['other']))
        for row in rows[:5]:
            print('  %s ref=%s p=%.3f choice=%s' % (
                row.get('ts', '?'), row.get('ref'), row.get('p', -1),
                row.get('worker_choice')))
        sys.exit(0 if clean else 1)

    wtext = WORKER.read_text()

    check('## Shadow Jev tier — worker escalation target (fleet-ops#7773' in wtext,
          'worker.md: escalation-target section heading present')
    check('JEV_WORKER_ESCALATION_TARGET' in wtext,
          'worker.md: step-4 wires the enable flag')

    block = extract(wtext, '"Nishfleet/<repo>#<N>" "<card-path>"')
    check(block is not None, 'worker.md: escalation-target block extracted')
    if block is None:
        print('FAILED: missing embedded block', file=sys.stderr)
        sys.exit(1)
    try:
        compile(block, 'worker.md-block', 'exec')
        check(True, 'worker.md: embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'worker.md: embedded python block compiles (%s)' % exc)
        return

    for needle in ('JEV_WORKER_ESCALATION_TARGET', 'worker-escalation-target',
                   'nish_reserved', 'worker_choice', 'reconcile_outcome',
                   '127.0.0.1:4000/jev', 'LITELLM_JEV_KEY', 'typesafe-ai/jev',
                   'advisory_only', 'state_sha256', 'money_boundary',
                   'reserved_classes'):
        check(needle in block, 'worker.md block names %s' % needle)
    check("os.environ.get('JEV_WORKER_ESCALATION_TARGET', '') not in ('1', 'on', 'true')" in block,
          'worker.md: flag defaults OFF branch present')
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'worker.md: block never references %s' % var)
    check("req.add_header('Authorization', 'Bearer ' + key)" in block,
          'worker.md: key reaches only the Authorization header')
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|\{\s*key\s*\}|%\s*key\b|,\s*key\b)', block),
          'worker.md: key variable never interpolated into a print call')

    class Stub(BaseHTTPRequestHandler):
        p = 0.8
        posts = []
        fail = False

        def do_POST(self):
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.posts.append(body)
            if Stub.fail:
                self.send_response(500); self.end_headers(); return
            if self.headers.get('Authorization') != 'Bearer test-key-7773':
                self.send_response(401); self.end_headers(); return
            out = json.dumps({'answers': {'nish_reserved': {
                'type': 'boolean', 'probability': Stub.p}},
                'usage': {'total_tokens': 200}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    CARD = {'item': 'needs a paid Sentry plan to keep error reporting',
            'issue': 'fleet-ops#1 worker errors are silent',
            'worker_choice': 'nish-decision',
            'reconcile_outcome': 'disagreement=false; needsNish=p=0.9/p=0.8',
            'context': 'reserved classes list'}

    run_counter = [0]

    def run_block(td, flag='1', fail=False, card=CARD, key='test-key-7773',
                  ref='Nishfleet/fleet-ops#1', bands={'act_hi': 0.5, 'review_lo': 0.5}):
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
            bpath.write_text(json.dumps({'sites': {SITE: bands}}))
        log = rundir / 'wet.jsonl'
        env = dict(os.environ,
                   JEV_WORKER_ESCALATION_ENDPOINT=endpoint,
                   JEV_WORKER_ESCALATION_LOG=str(log),
                   JEV_BANDS_FILE=str(bpath))
        env.pop('JEV_WORKER_ESCALATION_TARGET', None)
        if flag is not None:
            env['JEV_WORKER_ESCALATION_TARGET'] = flag
        if key is None:
            env.pop('LITELLM_JEV_KEY', None)
            env['HOME'] = str(rundir / 'nohome')  # no seat file there
        else:
            env['LITELLM_JEV_KEY'] = key
        r = subprocess.run(['python3', str(bfile), ref, str(cfile)],
                           capture_output=True, text=True, env=env, timeout=30)
        rows = [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []
        return r, rows, list(Stub.posts)

    with tempfile.TemporaryDirectory() as td:
        # 1. flag unset -> OFF by default: no post, no row, exit 0
        r, rows, posts = run_block(td, flag=None)
        check(r.returncode == 0, 'default-off: exit 0')
        check('off' in r.stdout, 'default-off: prints off (%s)' % r.stdout.strip())
        check(posts == [] and rows == [], 'default-off: no call, no row')

        # 2. flag=0 -> off
        r, rows, posts = run_block(td, flag='0')
        check(posts == [] and 'off' in r.stdout, 'flag-0: disabled')

        # 3. flag=1 + stub -> one post, one spec-shaped row
        r, rows, posts = run_block(td)
        check(r.returncode == 0, 'enabled: exit 0')
        check(len(posts) == 1, 'enabled: one POST (got %d)' % len(posts))
        check(posts and posts[0].get('model') == 'typesafe-ai/jev',
              'enabled: model is typesafe-ai/jev')
        check(posts and list((posts[0].get('questions') or {}).keys()) == ['nish_reserved'],
              'enabled: exactly one boolean question')
        st = posts[0].get('state') if posts else {}
        check(isinstance(st, dict) and 'money/pricing' in (st.get('reserved_classes') or [])
              and 'blocker' in st and 'issue_text' in st
              and st.get('worker_choice') == 'nish-decision',
              'enabled: state carries classes, money boundary, issue, blocker, choice')
        check(len(rows) == 1, 'enabled: one JSONL row (got %d)' % len(rows))
        row = rows[0] if rows else {}
        check(row.get('site') == SITE and row.get('ref') == 'Nishfleet/fleet-ops#1',
              'enabled: row site/ref')
        check(row.get('p') == 0.8 and row.get('worker_choice') == 'nish-decision'
              and row.get('reconcile_outcome', '').startswith('disagreement'),
              'enabled: row carries p + worker_choice + reconcile_outcome')
        check(isinstance(row.get('state_sha256'), str) and SHA_RE.match(row['state_sha256']),
              'enabled: state_sha256 is 64-hex')
        check(row.get('advisory_only') is True and row.get('act_hi') == 0.5
              and row.get('review_lo') == 0.5,
              'enabled: advisory_only + band edges stamped')
        check('nish_reserved p=0.800' in r.stdout and 'choice' in r.stdout,
              'enabled: verdict line (%s)' % r.stdout.strip())

        # 4. forced Jev failure -> unavailable, exit 0, no row
        r, rows, posts = run_block(td, fail=True)
        check(r.returncode == 0, 'jev-fail: exit 0 (escalation proceeds)')
        check('unavailable' in r.stdout, 'jev-fail: unavailable line (%s)' % r.stdout.strip())
        check(rows == [], 'jev-fail: no row written')

        # 5. no seat key -> unavailable, exit 0, no posts
        r, rows, posts = run_block(td, key=None)
        check(r.returncode == 0 and 'unavailable (no seat key)' in r.stdout,
              'nokey: unavailable, exit 0')
        check(posts == [], 'nokey: no posts made')

        # 6. card missing worker_choice -> unavailable, exit 0
        r, rows, _ = run_block(td, card={'item': 'x'})
        check('unavailable (card needs item and worker_choice)' in r.stdout,
              'badcard: unavailable, exit 0')

        # 7. bad ref -> unavailable, exit 0
        r, rows, _ = run_block(td, ref='not-a-ref')
        check('unavailable (bad ref)' in r.stdout, 'badref: unavailable, exit 0')

        # 8. determinism: same card twice -> identical state_sha256
        _, rows_a, _ = run_block(td)
        _, rows_b, _ = run_block(td)
        check(rows_a and rows_b
              and rows_a[0]['state_sha256'] == rows_b[0]['state_sha256'],
              'replayable: same inputs -> same state hash')

        # 9. missing bands table -> row still lands with null edges
        r, rows, _ = run_block(td, bands=None)
        check(rows and rows[0].get('act_hi') is None,
              'missing table: row records null edges')

        # 10. replay the functional log end to end
        allrows = []
        for rd in sorted(pathlib.Path(td).glob('run*')):
            lg = rd / 'wet.jsonl'
            if lg.exists():
                allrows += [json.loads(l) for l in lg.read_text().splitlines()]
        fixture = pathlib.Path(td) / 'fixture.jsonl'
        fixture.write_text('\n'.join(json.dumps(x) for x in allrows) + '\n')
        rows, stats, clean = replay_log(fixture)
        check(clean and stats['n'] == len(allrows) and stats['bad_lines'] == 0,
              'replay: every emitted row re-validates (n=%d)' % stats['n'])
        check(stats['agree'] >= 1, 'replay: agreement recomputed from rows')

    print('---')
    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('all checks passed')


if __name__ == '__main__':
    main()
