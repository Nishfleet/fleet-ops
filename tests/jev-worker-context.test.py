#!/usr/bin/env python3
"""fleet-ops#7454: the intake prompt carries the advisory worker-context
relevance tier. Static prompt-contract assertions plus a functional pass that
runs the embedded block against a stub gh, stub packet files and a stub /jev
endpoint. Run: python3 tests/jev-worker-context.test.py
"""
import hashlib, json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'intake.md'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"python3 - \"<repo>\" \"<issue>\" <<'PY_WCX'\n(.*?)\nPY_WCX\n", text, re.S)
    return m.group(1) if m else None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    text = PROMPT.read_text()

    # --- static prompt contract -------------------------------------------
    heading = '## Jev worker-context economy (fleet-ops#7454)'
    check(heading in text, 'worker-context shadow section heading present')
    lines = text.splitlines()
    sec_i = next((i for i, l in enumerate(lines) if l.startswith(heading)), -1)
    smoke_i = next((i for i, l in enumerate(lines)
                    if l.startswith('## Jev cascade — seat smoke')), -1)
    check(0 <= smoke_i < sec_i, 'worker-context section follows the smoke section')
    check(sec_i >= 0 and len(lines) - sec_i > 30, 'worker-context section is not empty')
    check('e2. Context advisory, best-effort' in text, 'step 5 wires the block in')
    check(text.index('e2. Context advisory') < text.index(heading),
          'the step-5 reference precedes the block section')

    blocks = re.findall(r"python3 - \"<repo>\" \"<issue>\" <<'PY_WCX'\n", text)
    check(len(blocks) == 1, 'exactly one PY_WCX block, got %d' % len(blocks))
    block = extract_block(text)
    check(block is not None, 'block extracted')
    if block is None:
        sys.exit(1)
    try:
        compile(block, 'jev-wcx-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('worker-context.jsonl', "SITE = 'worker-context'",
                   '127.0.0.1:4000/jev', 'JEV_WORKER_CONTEXT', 'advisory_only',
                   'would_drop_default', 'would_drop_by_threshold',
                   'token_delta_est_by_threshold', 'counts_toward_flip_bar',
                   'builder_decision', 'shadow_disagreement', 'flip_gate',
                   'chars/%d', 'LITELLM_JEV_KEY'):
        check(needle in text, 'prompt names %s' % needle)
    check("os.environ.get('JEV_WORKER_CONTEXT')" in block, 'off-flag branch present')
    check("os.environ.get('JEV_WORKER_CONTEXT') in ('0', 'off', 'false', 'no')" in block,
          'off-flag accepts 0/off/false/no')
    for var in ('GH_TOKEN', 'VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("'Authorization': 'Bearer ' + key" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|note|log)\([^)]*(?:\+\s*key\b|,\s*key\b|%\s*key\b|\{\s*key\s*\})', block),
          'key variable never interpolated into a print call')
    for mutator in ('write_text(', 'unlink(', 'rmtree', 'os.remove('):
        check(mutator not in block, 'block never mutates a packet file (%s)' % mutator)

    # --- functional pass: stub gh + stub packet root + stub /jev ----------
    class Stub(BaseHTTPRequestHandler):
        calls = 0
        bad_answer = False

        def do_POST(self):
            Stub.calls += 1
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            Stub.last_auth = self.headers.get('Authorization')
            if self.headers.get('Authorization') != 'Bearer test-key-7454':
                self.send_response(401); self.end_headers(); return
            questions = body.get('questions') or {}
            probs = [0.05, 0.4, 0.7]
            answers = {}
            for i, qid in enumerate(sorted(questions, key=lambda q: int(q.split('_')[1]))):
                answers[qid] = {'type': 'boolean', 'probability': probs[i % len(probs)]}
            if Stub.bad_answer and answers:
                answers.pop(sorted(answers, key=lambda q: int(q.split('_')[1]))[0])
            out = json.dumps({'answers': answers, 'usage': {'inputTokens': 12000,
                                                            'outputTokens': 30}}).encode()
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
        blockfile = td / 'block.py'
        blockfile.write_text(block)

        packetroot = td / 'packetroot'
        (packetroot / 'prompts').mkdir(parents=True)
        (packetroot / 'AGENTS.md').write_text('agents body ' * 40)
        (packetroot / 'prompts' / 'worker.md').write_text('worker body ' * 200)
        before = {p: digest(p) for p in (packetroot / 'AGENTS.md',
                                         packetroot / 'prompts' / 'worker.md')}

        comments = [{'id': 9001, 'author': 'nish3451', 'body': 'decision-resolved: advisory only'}]
        cfile = td / 'comments.json'
        cfile.write_text(json.dumps(comments))
        ifile = td / 'issue.json'
        ifile.write_text(json.dumps({'title': 'jev: worker-side context economy',
                                     'body': 'each candidate gets relevance p'}))

        ghbin = td / 'bin' / 'gh'
        ghbin.parent.mkdir()
        ghbin.write_text('#!/bin/sh\n'
                         'for a in "$@"; do\n'
                         '  case "$a" in *comments*) cat "${GH_WCX_COMMENTS:?}"; exit 0;; esac\n'
                         'done\n'
                         'cat "${GH_WCX_ISSUE:?}"\n')
        ghbin.chmod(0o755)

        logfile = td / 'worker-context.jsonl'

        def run(env):
            return subprocess.run([sys.executable, str(blockfile),
                                   'Nishfleet/fleet-ops', '7454'],
                                  capture_output=True, text=True, env=env, timeout=90)

        base_env = dict(os.environ,
                        PATH='%s:%s' % (ghbin.parent, os.environ.get('PATH', '')),
                        LITELLM_JEV_KEY='test-key-7454',
                        JEV_WORKER_CONTEXT_ENDPOINT=endpoint,
                        JEV_WORKER_CONTEXT_LOG=str(logfile),
                        JEV_WORKER_CONTEXT_ROOT=str(packetroot),
                        GH_WCX_COMMENTS=str(cfile),
                        GH_WCX_ISSUE=str(ifile))
        base_env.pop('JEV_WORKER_CONTEXT', None)
        base_env.pop('JEV_WORKER_CONTEXT_THRESHOLD', None)

        # real call -> one row, would-drop set at the default band
        r = run(base_env)
        check(r.returncode == 0, 'exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev-context: Nishfleet/fleet-ops#7454 items=3 '
                        r'would_drop\(p<=0\.1\)=rel_0 delta_est=~[0-9]+ tokens; '
                        r'advisory-only; builder unchanged', r.stdout, re.M) is not None,
              'run prints the relevance summary; got %r' % r.stdout.strip()[:200])
        check('test-key-7454' not in r.stdout + r.stderr, 'key never printed')
        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'exactly one row appended, got %d' % len(rows))
        if rows:
            row = rows[0]
            check(row.get('site') == 'worker-context', 'row site')
            check(row.get('mode') == 'shadow' and row.get('advisory_only') is True, 'row is shadow/advisory')
            check(row.get('counts_toward_flip_bar') is False, 'row not flip-bar credited')
            check(row.get('builder_decision', '').startswith('unchanged'), 'row records the unchanged builder')
            check(row.get('shadow_disagreement') == row.get('would_drop_default'), 'disagreement = would-drop set')
            check(row.get('would_drop_default') == ['rel_0'], 'default band drops the weakest item')
            check(row.get('would_drop_by_threshold', {}).get('0.5') == ['rel_0', 'rel_1'],
                  'sensitivity bands reported')
            check(row.get('threshold_default') == 0.1, 'default threshold is the standing lo band')
            check(re.match(r'^pi-intake:Nishfleet/fleet-ops#7454:\d{4}-', row.get('ref') or '') is not None,
                  'row ref names repo/issue/time')
            check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
                  'row state_sha256')
            check(len(row.get('items') or []) == 3, 'row carries one item per candidate')
            check(all(0.0 <= p <= 1.0 for p in (row.get('probabilities') or {}).values()),
                  'row probabilities in range')
            check(row.get('token_estimate_basis', '').startswith('chars/4'),
                  'token estimate is an explicitly labelled chars/4 estimate')
            delta = (row.get('token_delta_est_by_threshold') or {}).get('0.1')
            check(isinstance(delta, int) and delta == (row['items'][0]['tokens_est']),
                  'token delta counts the would-drop item')
            check('test-key-7454' not in json.dumps(row), 'row carries no key')
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'request model id')
        check(Stub.last_auth == 'Bearer test-key-7454', 'request auth header only')
        qids = sorted((Stub.last_body.get('questions') or {}).keys())
        check(qids == ['rel_0', 'rel_1', 'rel_2'], 'one batched boolean per candidate, got %s' % qids)
        state = Stub.last_body.get('state') or {}
        check('answers' not in state and 'probabilities' not in state,
              'state carries the question, never an answer')
        check('worker-side context economy' in json.dumps(state), 'state carries the issue title')
        check(state.get('candidate_source', '').startswith('code'), 'candidates are enumerated from code')
        after = {p: digest(p) for p in (packetroot / 'AGENTS.md',
                                        packetroot / 'prompts' / 'worker.md')}
        check(before == after, 'packet bytes are unchanged by the block')

        # threshold override widens the default would-drop set
        logfile.unlink()
        env = dict(base_env, JEV_WORKER_CONTEXT_THRESHOLD='0.5')
        r = run(env)
        check(r.returncode == 0, 'threshold override exit 0')
        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(rows and rows[0].get('would_drop_default') == ['rel_0', 'rel_1'],
              'override threshold widens the would-drop set')

        # rollback flag -> no call, no row
        calls_before = Stub.calls
        logfile.unlink()
        env = dict(base_env, JEV_WORKER_CONTEXT='off')
        r = run(env)
        check(r.returncode == 0 and 'off (JEV_WORKER_CONTEXT=off); builder unchanged' in r.stdout,
              'flag=off disables')
        check(Stub.calls == calls_before, 'flag=off makes no Jev call')
        check(not logfile.exists(), 'flag=off writes no row')

        # dead endpoint -> advisory unavailable, exit 0, no row
        env = dict(base_env, JEV_WORKER_CONTEXT_ENDPOINT='http://127.0.0.1:1/jev')
        r = run(env)
        check(r.returncode == 0 and 'unavailable' in r.stdout and 'builder unchanged' in r.stdout,
              'dead endpoint -> unavailable')
        check(not logfile.exists(), 'dead endpoint writes no row')

        # partial answers -> unavailable, no row
        Stub.bad_answer = True
        r = run(base_env)
        check(r.returncode == 0 and 'unavailable' in r.stdout, 'partial answers -> unavailable')
        check(not logfile.exists(), 'partial answers write no row')
        Stub.bad_answer = False

        # gh failure -> unavailable, no row
        ghbin.write_text('#!/bin/sh\nexit 1\n')
        r = run(base_env)
        check(r.returncode == 0 and 'gh comment read failed' in r.stdout, 'gh failure -> unavailable')
        check(not logfile.exists(), 'gh failure writes no row')

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
