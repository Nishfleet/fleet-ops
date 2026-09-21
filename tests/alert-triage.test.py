#!/usr/bin/env python3
"""fleet-ops#7414 T6: alert triage at the dispatch path, before any repair
session spawns. The resolved short-circuit is arithmetic in bash; the batched
Jev call (triage_class choice(4) + needs_nish boolean) rides the existing
alert-dispatch POST and logs site=alert-triage rows beside the path action.
Runs the real bin/am-executor-claim end-to-end against a stub /jev, then
replays the emitted JSONL rows. Run: python3 tests/alert-triage.test.py
"""
import json, os, pathlib, re, stat, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / 'bin' / 'am-executor-claim'
PROMPT = ROOT / 'prompts' / 'alert-repair.md'
SYNC = ROOT / 'systemd' / 'fleet-sync.service'
YAML = ROOT / 'config' / 'prometheus-am-executor.yml'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_bin_block(text):
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY", text, re.S)
    for b in blocks:
        if 'site=alert-dispatch' in b:
            return b
    return None


class JevStub(BaseHTTPRequestHandler):
    """Answers all three batched questions; prob/choice/nish configurable."""
    prob = 0.5          # needs_repair_session
    choice = 'repair-in-place'   # triage_class
    nish = 0.05         # needs_nish
    sparse = False      # answer only needs_repair_session (old-server shape)
    hits = []

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        JevStub.hits.append(body)
        if self.headers.get('Authorization') != 'Bearer test-key-7414':
            self.send_response(401); self.end_headers(); return
        answers = {'needs_repair_session': {'type': 'boolean',
                                            'answer': JevStub.prob >= 0.5,
                                            'probability': JevStub.prob}}
        if not JevStub.sparse:
            probs = {k: 0.0 for k in ('resolved-noop', 'repair-in-place',
                                      'file-issue', 'nish-escalation')}
            probs[JevStub.choice] = 1.0
            answers['triage_class'] = {'type': 'choice', 'choice': JevStub.choice,
                                       'probabilities': probs}
            answers['needs_nish'] = {'type': 'boolean', 'answer': JevStub.nish >= 0.5,
                                     'probability': JevStub.nish}
        out = json.dumps({'answers': answers,
                          'usage': {'total_tokens': 180}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def main():
    text_b = BIN.read_text()
    text_p = PROMPT.read_text()
    text_s = SYNC.read_text()

    # ---- static contract -------------------------------------------------
    for needle in ('resolved-noop', 'alert-triage', 'triage_class', 'needs_nish',
                   'reserved_classes', 'JEV_ALERT_TRIAGE_LOG', 'triage_row',
                   'fleet-ops#7414'):
        check(needle in text_b, 'bin names %s' % needle)
    check('resolved, nothing to do' not in text_p,
          'prompt no longer carries the resolved-check prose (code owns it)')
    check('fleet-ops#7414' in text_p, 'prompt notes the upstream short-circuit')
    check('Print what you did in one short block' in text_p, 'summary step intact')
    check('try-restart prometheus-am-executor' in text_s,
          'fleet-sync bounces the executor when the config changes across a pull')
    text_y = YAML.read_text()
    check(not re.search(r'^\s*ignore_resolved:', text_y, re.M),
          'yml no longer drops resolved upstream — the wrapper owns the verdict')
    check('exec "$HOME/.local/bin/pi"' in text_y,
          'dispatch command uses the absolute pi path (systemd PATH lacks ~/.local/bin)')
    am = (ROOT / 'config' / 'alertmanager.yml').read_text()
    check(re.search(r'repair-dispatch\n\s+webhook_configs:[\s\S]*?send_resolved: true', am)
          is not None,
          'repair-dispatch receiver delivers resolved payloads to the wrapper')

    block = extract_bin_block(text_b)
    check(block is not None, 'bin block extracted')
    if block is None:
        sys.exit(1)
    try:
        compile(block, 'bin-block', 'exec')
        check(True, 'bin embedded python compiles')
    except SyntaxError as exc:
        check(False, 'bin embedded python compiles (%s)' % exc)
        return
    for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'GH_TOKEN', 'TELEGRAM_BOT_TOKEN'):
        check(var not in block, 'block never references %s' % var)
    check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|%\s*key\b|,\s*key\b)', block),
          'key variable never interpolated into a print/note call')

    # ---- functional: real bin end-to-end ---------------------------------
    srv = HTTPServer(('127.0.0.1', 0), JevStub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        bindir = td / 'bin'
        bindir.mkdir()
        state = td / 'state'
        state.mkdir()
        log_t = td / 'alert-triage.jsonl'
        log_d = td / 'alert-dispatch.jsonl'
        actions = td / 'actions.log'
        actions.write_text('')
        runs = td / 'runs'
        runs.write_text('')
        units = td / 'live-units'

        (bindir / 'systemctl').write_text(
            '#!/bin/sh\nfor a in "$@"; do case "$a" in list-units)\n'
            '  [ -f "%s" ] && cat "%s";; esac; done\nexit 0\n' % (units, units))
        (bindir / 'systemctl').chmod(0o755)
        stub = td / 'stub-repair'
        stub.write_text('#!/bin/sh\necho run >> "%s"\ncat >/dev/null\n' % runs)
        stub.chmod(0o755)

        def bin_env(extra):
            e = dict(os.environ)
            e.update(dict(HOME=str(td), PATH='%s:/usr/bin:/bin' % bindir,
                          ALERT_STATE_DIR=str(state),
                          SYSTEMCTL=str(bindir / 'systemctl'),
                          AM_EXECUTOR_CLAIM_UNIT='am-executor-claim-test',
                          LITELLM_JEV_KEY='test-key-7414',
                          JEV_CASCADE_ALERT_DISPATCH_ENDPOINT=endpoint,
                          JEV_CASCADE_ALERT_DISPATCH_LOG=str(log_d),
                          JEV_CASCADE_ALERT_DISPATCH_ACTIONS_LOG=str(actions),
                          JEV_ALERT_TRIAGE_LOG=str(log_t)))
            e.pop('JEV_CASCADE', None)
            e.pop('JEV_CASCADE_ALERT_DISPATCH', None)
            e.update(extra)
            return e

        firing = ('{"status":"firing","commonLabels":{"alertname":"FakeGauge","severity":"warning"},'
                  '"groupLabels":{"alertname":"FakeGauge"},'
                  '"alerts":[{"status":"firing","labels":{"alertname":"FakeGauge","severity":"warning"},'
                  '"fingerprint":"aa01"}]}')
        resolved = ('{"status":"resolved","commonLabels":{"alertname":"FakeGauge","severity":"warning"},'
                    '"alerts":[{"status":"resolved","labels":{"alertname":"FakeGauge","severity":"warning"},'
                    '"fingerprint":"aa01","startsAt":"2026-09-22T00:00:00Z","endsAt":"2026-09-22T01:00:00Z"}]}')
        mixed = ('{"status":"firing","alerts":['
                 '{"status":"resolved","labels":{"alertname":"FakeGauge","severity":"warning"}},'
                 '{"status":"firing","labels":{"alertname":"FakeGauge","severity":"warning"}}]}')

        def fire(pl, env):
            return subprocess.run(['bash', str(BIN), str(stub)],
                                  input=pl, capture_output=True, text=True,
                                  timeout=90, env=env)

        def trows():
            if not log_t.exists():
                return []
            return [json.loads(l) for l in log_t.read_text().splitlines() if l.strip()]

        def drows():
            if not log_d.exists():
                return []
            return [json.loads(l) for l in log_d.read_text().splitlines() if l.strip()]

        def reset():
            JevStub.hits.clear()
            runs.write_text('')
            units.write_text('')
            log_t.unlink(missing_ok=True)
            log_d.unlink(missing_ok=True)

        # 1. resolved payload: short-circuit in code, zero Jev calls, no spawn
        reset()
        r = fire(resolved, bin_env({}))
        check(r.returncode == 0, 'resolved: exit 0 (rc=%s %s)' % (r.returncode, r.stderr[-200:]))
        check(runs.read_text() == '', 'resolved: repair session never ran')
        check(len(JevStub.hits) == 0, 'resolved: zero Jev calls')
        check(not (state / 'fake-gauge.json').exists(), 'resolved: no claim written')
        rs = trows()
        check(len(rs) == 1 and rs[0]['site'] == 'alert-triage'
              and rs[0]['decision'] == 'resolved-noop' and rs[0]['jev_calls'] == 0
              and rs[0]['path_action'] == 'resolved-noop'
              and rs[0]['alerts'][0]['fingerprint'] == 'aa01',
              'resolved: alert-triage row %s' % (rs[-1] if rs else None))
        check(len(drows()) == 0, 'resolved: no alert-dispatch row')

        # 2. mixed payload (one firing) is NOT resolved-noop
        reset()
        r = fire(mixed, bin_env({}))
        check(runs.read_text().strip() == 'run', 'mixed: session runs (a firing alert exists)')
        check(len(JevStub.hits) == 1, 'mixed: one batched Jev call')

        # 3. firing payload shadow: one POST, three questions, both site rows
        reset()
        JevStub.prob, JevStub.choice, JevStub.nish = 0.8, 'repair-in-place', 0.05
        r = fire(firing, bin_env({}))
        check(runs.read_text().strip() == 'run', 'firing shadow: session runs')
        check(len(JevStub.hits) == 1, 'firing shadow: one batched POST')
        qs = (JevStub.hits[0].get('questions') or {})
        check(set(qs) == {'needs_repair_session', 'triage_class', 'needs_nish'},
              'batched questions %s' % sorted(qs))
        check(set(qs['triage_class'].get('choices') or []) ==
              {'resolved-noop', 'repair-in-place', 'file-issue', 'nish-escalation'},
              'choice(4) candidate list built in code')
        st = JevStub.hits[0].get('state') or {}
        check('reserved_classes' in st and 'money_boundary' in st,
              'state carries the canonical reserved-class list and money boundary')
        rs = trows()
        check(len(rs) == 1 and rs[0]['site'] == 'alert-triage'
              and rs[0]['path_action'] == 'spawned' and rs[0]['jev_calls'] == 1
              and rs[0]['advisory_only'] is True
              and rs[0]['answers']['triage_class']['choice'] == 'repair-in-place'
              and rs[0]['answers']['needs_nish']['probability'] == 0.05,
              'firing shadow: alert-triage row %s' % (rs[-1] if rs else None))
        check(len(drows()) == 1 and drows()[0]['path_action'] == 'spawned',
              'firing shadow: alert-dispatch row carries path_action')

        # 4. act mode + resolved-noop answer: the only triage class that may act
        reset()
        JevStub.prob, JevStub.choice = 0.8, 'resolved-noop'
        r = fire(firing, bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}))
        check(runs.read_text() == '', 'act+resolved-noop: session not spawned')
        rs = trows()
        check(rs and rs[-1]['path_action'] == 'skipped-no-session'
              and rs[-1]['triage_skipped'] is True and rs[-1]['advisory_only'] is False,
              'act+resolved-noop row')
        check(drows() and drows()[-1]['skip_reason'] == 'resolved-noop',
              'alert-dispatch row names skip_reason=resolved-noop')

        # 5. shadow mode + resolved-noop answer: advisory, session still runs
        reset()
        r = fire(firing, bin_env({}))
        check(runs.read_text().strip() == 'run',
              'shadow+resolved-noop: session still runs (advisory)')
        check(trows() and trows()[-1]['triage_would_skip'] is True
              and trows()[-1]['triage_skipped'] is False,
              'shadow+resolved-noop: would_skip projected')

        # 6. needs_nish=yes stays advisory even in act mode (out-of-band path)
        reset()
        JevStub.choice, JevStub.nish = 'nish-escalation', 0.95
        r = fire(firing, bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}))
        check(runs.read_text().strip() == 'run',
              'act+nish-escalation: session still runs (never gated on needs_nish)')
        check(trows() and trows()[-1]['answers']['needs_nish']['probability'] == 0.95,
              'needs_nish answer logged')

        # 7. dead endpoint: fall back to today's path
        reset()
        dead = bin_env({'JEV_CASCADE_ALERT_DISPATCH_ENDPOINT': 'http://127.0.0.1:1/jev'})
        r = fire(firing, dead)
        check(r.returncode == 0 and runs.read_text().strip() == 'run',
              'dead endpoint: session runs (fallback on any Jev error)')

        # 8. flag off: no call, no rows, session runs
        reset()
        r = fire(firing, bin_env({'JEV_CASCADE_ALERT_DISPATCH': '0'}))
        check(len(JevStub.hits) == 0 and runs.read_text().strip() == 'run',
              'off: no Jev call, session runs')
        check(len(trows()) == 0 and len(drows()) == 0, 'off: no rows')

        # 9. severity=nish: never gated, code row records the bypass
        reset()
        nish = ('{"status":"firing","commonLabels":{"alertname":"NishEscalation","severity":"nish"},'
                '"alerts":[{"status":"firing","labels":{"alertname":"NishEscalation","severity":"nish"}}]}')
        r = fire(nish, bin_env({'JEV_CASCADE_ALERT_DISPATCH': 'act'}))
        check(runs.read_text().strip() == 'run' and len(JevStub.hits) == 0,
              'severity=nish: runs without any Jev call')
        check(trows() and trows()[-1]['decision'] == 'severity-never-gated'
              and trows()[-1]['jev_calls'] == 0,
              'severity=nish: code row logged')

        # 10. live worker: dedupe row, no spawn, no Jev
        reset()
        units.write_text('alert-repair-FakeGauge-20260922T000000Z.service loaded active running x\n')
        r = fire(firing, bin_env({}))
        check(runs.read_text() == '' and len(JevStub.hits) == 0,
              'skipped-live-worker: no spawn, no Jev call')
        check(trows() and trows()[-1]['decision'] == 'skipped-live-worker',
              'skipped-live-worker row logged')

        # 11. sparse answer (server answered only the first question): the
        # alert-dispatch row still lands, dispatch proceeds, no triage row
        reset()
        JevStub.sparse = True
        JevStub.prob = 0.5
        r = fire(firing, bin_env({}))
        check(runs.read_text().strip() == 'run', 'sparse answer: session runs')
        check(len(drows()) == 1, 'sparse answer: alert-dispatch row still lands')
        check(len(trows()) == 0, 'sparse answer: no triage row')
        JevStub.sparse = False

        # 12. replay: every emitted alert-triage row re-validates against the
        # decision it recorded (the replay check the issue asks for)
        reset()
        fire(resolved, bin_env({}))
        JevStub.choice = 'repair-in-place'
        fire(firing, bin_env({}))
        rows = trows()
        check(len(rows) == 2, 'replay corpus: two rows')
        for row in rows:
            check(row.get('site') == 'alert-triage' and row.get('ref')
                  and isinstance(row.get('jev_calls'), int)
                  and row.get('path_action') in ('resolved-noop', 'spawned',
                                                 'skipped-no-session',
                                                 'skipped-live-worker'),
                  'replay: row shape %s' % row.get('ref'))
            alerts = row.get('alerts') or []
            if alerts:
                recomputed = all(a.get('status') == 'resolved' for a in alerts)
                check((row['decision'] == 'resolved-noop') == recomputed,
                      'replay: resolved verdict recomputes from the row')
            if row.get('jev_calls') == 1:
                check(row['answers']['triage_class']['choice'] in
                      ('resolved-noop', 'repair-in-place', 'file-issue', 'nish-escalation'),
                      'replay: triage_class is a candidate member')

    srv.shutdown()
    if FAILS:
        print('\n%d failures' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('alert-triage: all scenarios passed (fleet-ops#7414)')


if __name__ == '__main__':
    main()
