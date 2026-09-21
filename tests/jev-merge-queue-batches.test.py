#!/usr/bin/env python3
"""fleet-ops#7419: the digest prompt carries the advisory merge-queue batch
proposal tier. Static prompt-contract assertions plus a functional pass that
runs the embedded block against a stub merge-queue answer and a stub /jev
endpoint. Run: python3 tests/jev-merge-queue-batches.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROMPT = ROOT / 'prompts' / 'daily-digest.md'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text):
    m = re.search(r"python3 - <<'PY_MQB'\n(.*?)\nPY_MQB\n", text, re.S)
    return m.group(1) if m else None


def queue_fixture(entries):
    nodes = []
    for i, (number, title, sha, files) in enumerate(entries):
        nodes.append({'position': i + 1, 'state': 'QUEUED',
                      'enqueuedAt': '2026-09-21T20:00:00Z',
                      'pullRequest': {'number': number, 'title': title, 'headRefOid': sha,
                                      'files': {'totalCount': len(files),
                                                'nodes': [{'path': p} for p in files]}}})
    return {'data': {'repository': {'mergeQueue': {'entries': {
        'totalCount': len(nodes), 'nodes': nodes}}}}}


def main():
    text = PROMPT.read_text()

    # --- static prompt contract -------------------------------------------
    heading = '## Shadow Jev tier — merge-queue batch proposals (fleet-ops#7419)'
    check(heading in text, 'batch shadow section heading present')
    lines = text.splitlines()
    batch_i = next((i for i, l in enumerate(lines) if l.startswith(heading)), -1)
    send_i = next((i for i, l in enumerate(lines) if l.startswith('## Send —')), -1)
    check(0 <= batch_i < send_i, 'batch shadow section precedes the send section')
    check(send_i - batch_i > 20, 'batch shadow section is not empty')

    blocks = re.findall(r"python3 - <<'PY_MQB'\n", text)
    check(len(blocks) == 1, 'exactly one PY_MQB block, got %d' % len(blocks))
    # The fleet-ops#7393 tier's own test requires exactly one `python3 - <<'PY'`.
    check(len(re.findall(r"^python3 - <<'PY'$", text, re.M)) == 1,
          'the #7393 PY block is still the only heredoc with that delimiter')
    block = extract_block(text)
    check(block is not None, 'block extracted')
    if block is None:
        sys.exit(1)
    try:
        compile(block, 'jev-mqb-block', 'exec')
        check(True, 'embedded python block compiles')
    except SyntaxError as exc:
        check(False, 'embedded python block compiles (%s)' % exc)
        return

    for needle in ('merge-queue-batches.jsonl', 'site=merge-queue-batches',
                   '127.0.0.1:4000/jev', 'JEV_MQB', 'counts_toward_flip_bar',
                   'advisory_only', 'docs/jev-benchmark-2026-09.md', 'jev-eval',
                   'files(first:50)'):
        check(needle in text, 'prompt names %s' % needle)
    check("os.environ.get('JEV_MQB') == '0'" in block, 'off-flag branch present')
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_BOT_TOKEN', 'GH_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check("'Authorization': 'Bearer ' + key" in block,
          'key reaches only the Authorization header')
    check(not re.search(r'(?:print|note|log)\([^)]*(?:\+\s*key\b|,\s*key\b|%\s*key\b|\{\s*key\s*\})', block),
          'key variable never interpolated into a print call')

    # --- functional pass: stub gh + stub /jev ------------------------------
    class Stub(BaseHTTPRequestHandler):
        calls = 0
        drop_one = False

        def do_POST(self):
            Stub.calls += 1
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            Stub.last_body = body
            Stub.last_auth = self.headers.get('Authorization')
            if self.headers.get('Authorization') != 'Bearer test-key-7419':
                self.send_response(401); self.end_headers(); return
            questions = body.get('questions') or {}
            answers = {qid: {'type': 'boolean', 'probability': 0.1 + 0.2 * (i % 3)}
                       for i, qid in enumerate(sorted(questions))}
            if Stub.drop_one and answers:
                answers.pop(sorted(answers)[0])
            out = json.dumps({'answers': answers, 'usage': {'inputTokens': 700,
                                                            'outputTokens': 40}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    three = [(8110, 'feat(jev): cascade gating', 'aaa111', ['prompts/intake.md', 'bin/x']),
             (8098, 'feat(intake): advisory tier', 'bbb222', ['prompts/intake.md']),
             (7952, 'move(config): rule-enforcement', 'ccc333', ['config/rule-enforcement.json'])]
    one = [three[0]]

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        blockfile = td / 'block.py'
        blockfile.write_text(block)
        ghbin = td / 'bin' / 'gh'
        ghbin.parent.mkdir()
        ghbin.write_text('#!/bin/sh\ncat "${GH_MQ_FIXTURE:?}"\n')
        ghbin.chmod(0o755)
        logfile = td / 'merge-queue-batches.jsonl'
        statefile = td / 'merge-queue-batches.state'
        threefile = td / 'three.json'
        threefile.write_text(json.dumps(queue_fixture(three)))
        onefile = td / 'one.json'
        onefile.write_text(json.dumps(queue_fixture(one)))

        base_env = dict(os.environ,
                        PATH='%s:%s' % (ghbin.parent, os.environ.get('PATH', '')),
                        LITELLM_JEV_KEY='test-key-7419',
                        JEV_MQB_ENDPOINT=endpoint,
                        JEV_MQB_LOG=str(logfile),
                        JEV_MQB_STATE=str(statefile),
                        JEV_MQB_REPOS='Nishfleet/fleet-ops',
                        GH_MQ_FIXTURE=str(threefile))
        base_env.pop('JEV_MQB', None)

        def run(env):
            return subprocess.run([sys.executable, str(blockfile)],
                                  capture_output=True, text=True, env=env, timeout=90)

        # real queue shape -> one proposal row
        r = run(base_env)
        check(r.returncode == 0, 'exit 0 (stderr: %s)' % r.stderr.strip()[:200])
        check(re.search(r'^jev batch proposal: Nishfleet/fleet-ops prs=8110,8098,7952 '
                        r'pairs=3 would_save_runs=2', r.stdout, re.M) is not None,
              'proposal line names the real batch + savings; got %r' % r.stdout.strip()[:200])
        check('test-key-7419' not in r.stdout + r.stderr, 'key never printed')
        rows = [json.loads(l) for l in logfile.read_text().splitlines() if l.strip()]
        check(len(rows) == 1, 'exactly one row appended, got %d' % len(rows))
        if rows:
            row = rows[0]
            check(row.get('site') == 'merge-queue-batches', 'row site')
            check(row.get('advisory_only') is True, 'row advisory_only')
            check(row.get('counts_toward_flip_bar') is False, 'row not flip-bar credited')
            check('NO-GO' in (row.get('calibration') or ''), 'row calibration names the NO-GO report')
            check(row.get('proposed_batch_prs') == [8110, 8098, 7952], 'row proposes real PR numbers')
            check(row.get('would_save_runs_if_batched') == 2, 'row savings estimate')
            check(re.match(r'^[0-9a-f]{64}$', row.get('state_sha256') or '') is not None,
                  'row state_sha256')
            check(row.get('ref') == 'Nishfleet/fleet-ops#8110@aaa111', 'row ref = head PR + sha')
            check(len(row.get('conflicts') or {}) == 3, 'row carries one probability per pair')
            check(all(0.0 <= p <= 1.0 for p in (row.get('conflicts') or {}).values()),
                  'row probabilities in range')
            check('test-key-7419' not in json.dumps(row), 'row carries no key')
        check(Stub.last_body.get('model') == 'typesafe-ai/jev', 'request model id')
        check(Stub.last_auth == 'Bearer test-key-7419', 'request auth header only')
        qids = sorted((Stub.last_body.get('questions') or {}).keys())
        check(qids == sorted(['pair_8110_8098', 'pair_8110_7952', 'pair_8098_7952']),
              'request asks one boolean per pair, got %s' % qids)

        def state_has_repo():
            try:
                d = json.loads(statefile.read_text())
            except (OSError, ValueError):
                return False
            return isinstance(d, dict) and bool(d.get('Nishfleet/fleet-ops'))

        check(state_has_repo(), 'successful round-trip records the proposed composition')
        check('8110' in json.dumps(Stub.last_body.get('state') or {}), 'state carries the batch')

        # dedupe: unchanged queue composition -> no second call, no second row
        calls_before = Stub.calls
        r = run(base_env)
        check(r.returncode == 0, 'dedupe run exit 0')
        check(Stub.calls == calls_before, 'unchanged queue makes no second Jev call')
        check(len(logfile.read_text().splitlines()) == 1, 'unchanged queue writes no second row')

        # queue with one entry -> skip, no call
        calls_before = Stub.calls
        env = dict(base_env, GH_MQ_FIXTURE=str(onefile))
        r = run(env)
        check(r.returncode == 0 and 'skipped' in r.stdout, 'single-entry queue skipped')
        check(Stub.calls == calls_before, 'single-entry queue makes no Jev call')

        # rollback flag
        calls_before = Stub.calls
        env = dict(base_env, JEV_MQB='0')
        r = run(env)
        check(r.returncode == 0 and 'off (JEV_MQB=0)' in r.stdout, 'flag=0 disables')
        check(Stub.calls == calls_before, 'flag=0 makes no Jev call')

        # dead endpoint -> advisory unavailable, exit 0, no row, no state
        statefile.unlink(missing_ok=True)
        env = dict(base_env, JEV_MQB_ENDPOINT='http://127.0.0.1:1/jev')
        r = run(env)
        check(r.returncode == 0 and 'unavailable' in r.stdout, 'dead endpoint -> unavailable')
        check(len(logfile.read_text().splitlines()) == 1, 'dead endpoint writes no row')
        check(not state_has_repo(), 'dead endpoint records no composition (retry next run)')

        # incomplete answers -> unavailable, no row, no state
        statefile.unlink(missing_ok=True)
        Stub.drop_one = True
        r = run(base_env)
        check(r.returncode == 0 and 'unavailable' in r.stdout, 'partial answers -> unavailable')
        check(len(logfile.read_text().splitlines()) == 1, 'partial answers write no row')
        check(not state_has_repo(), 'partial answers record no composition')
        Stub.drop_one = False

    srv.shutdown()

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
