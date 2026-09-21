#!/usr/bin/env python3
"""fleet-ops#7414 phase 1: escalation-shadow rows for the surviving matrix
decision classes the glue sweep left standing. Runs the real
bin/fleet-claim-release and bin/fleet-silent-pr-close-check end-to-end
against a stub gh and a stub /jev, drives the prompts/intake.md gate-eval
block directly, then replays the emitted JSONL rows.
Run: python3 tests/escalation-shadow.test.py
"""
import json, os, pathlib, re, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLAIM = ROOT / 'bin' / 'fleet-claim-release'
SILENT = ROOT / 'bin' / 'fleet-silent-pr-close-check'
INTAKE = ROOT / 'prompts' / 'intake.md'
DOC = ROOT / 'docs' / 'escalation-matrix-split.md'
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def extract_block(text, needle):
    blocks = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY\b", text, re.S)
    for b in blocks:
        if needle in b:
            return b
    return None


class JevStub(BaseHTTPRequestHandler):
    """Answers every question in the request with a configurable boolean p."""
    prob = 0.8
    hits = []

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        JevStub.hits.append(body)
        if self.headers.get('Authorization') != 'Bearer test-key-7414':
            self.send_response(401); self.end_headers(); return
        answers = {}
        for qid, q in (body.get('questions') or {}).items():
            if (q or {}).get('type') == 'boolean':
                answers[qid] = {'type': 'boolean', 'answer': JevStub.prob >= 0.5,
                                'probability': JevStub.prob}
        out = json.dumps({'answers': answers, 'usage': {'total_tokens': 120}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def write_stub_gh(d):
    """Stub gh for fleet-claim-release: canned JSON per MOCK_* env."""
    s = d / 'gh'
    s.write_text('''#!/usr/bin/env bash
printf 'gh' >> "$GH_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$GH_LOG"; done
printf '\\n' >> "$GH_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
    token) echo "stub gh: token mint must never run" >&2; exit 1 ;;
    api)
        endpoint="${1:-}"
        case "$endpoint" in
            -X) printf '{}' ;;
            "repos/"*"/pulls?state=open"*)
                [ "${MOCK_PULLS_RC:-0}" != "0" ] && exit "$MOCK_PULLS_RC"
                printf '%s' "${MOCK_OPEN_PRS:-[]}" ;;
            "repos/"*"/pulls?state=closed"*)
                printf '%s' "${MOCK_CLOSED_PRS:-[]}" ;;
            "repos/"*"/git/refs/heads/wip/"*) exit 1 ;;
            "repos/"*"/git/refs/heads/"*)
                [ "${MOCK_BRANCH_EXISTS:-yes}" = "yes" ] \\
                    && printf '{"ref":"x","object":{"sha":"%s"}}' "${MOCK_CLAIM_SHA:-c1a1c1a1c}" || exit 1 ;;
            "repos/"*"/compare/"*)
                if [ -n "${MOCK_COMPARE:-}" ]; then printf '%s' "$MOCK_COMPARE"; else printf '%s' '{"ahead_by":0}'; fi ;;
            *"timeline?"*)
                num=$(printf '%s' "$endpoint" | sed 's/.*issues\\/\\([0-9]*\\)\\/timeline.*/\\1/')
                eval "printf '%s' \\"\\${MOCK_TIMELINE_$num:-[]}\\"" ;;
            "repos/"*"/issues/"*)
                num="${endpoint##*/}"
                v="MOCK_ISSUE_$num"
                if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; else printf '{"state":"open"}'; fi ;;
            "repos/"*) printf '{"default_branch":"main"}' ;;
            *) printf '[]' ;;
        esac ;;
    issue)
        case "$1" in
            view)
                if [ "${MOCK_ISSUE_RC:-0}" != "0" ]; then exit "$MOCK_ISSUE_RC"; fi
                if [ -n "${MOCK_ISSUE:-}" ]; then printf '%s' "$MOCK_ISSUE"; else printf '%s' '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}'; fi ;;
            comment|edit) : ;;
        esac ;;
esac
exit 0
''')
    s.chmod(0o755)
    return s


def claim_env(d, endpoint, log_path, extra=None):
    e = dict(os.environ)
    e.update(dict(
        HOME=str(d), GH=str(d / 'gh'), GH_LOG=str(d / 'gh-calls.log'),
        GITHUB_ACTIONS='true',
        LITELLM_JEV_KEY='test-key-7414',
        JEV_ESCALATION_SHADOW_ENDPOINT=endpoint,
        JEV_ESCALATION_SHADOW_LOG=str(log_path),
        PATH='%s:/usr/bin:/bin' % d,
    ))
    e.pop('JEV_ESCALATION_SHADOW', None)
    for k in list(e):
        if k.startswith('MOCK_'):
            e.pop(k)
    e.update(extra or {})
    return e


def silent_env(d, endpoint, log_path, extra=None):
    e = claim_env(d, endpoint, log_path, extra)
    e['SILENT_CLOSE_STATE_DIR'] = str(d / 'silent-state')
    e['SILENT_CLOSE_APP_RE'] = '^nishfleet-worker'
    return e


def rows(log_path):
    p = pathlib.Path(log_path)
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def main():
    text_c = CLAIM.read_text()
    text_s = SILENT.read_text()
    text_i = INTAKE.read_text()
    text_d = DOC.read_text()

    # ---- static contract -------------------------------------------------
    for needle in ('escalation-shadow', 'SHADOW_DECISION', 'release_is_safe',
                   'claim-release', 'JEV_ESCALATION_SHADOW', 'fleet-ops#7414'):
        check(needle in text_c, 'claim-release names %s' % needle)
    for needle in ('escalation-shadow', 'shadow_candidate', 'matches_silent_close',
                   'silent-pr-close', 'JEV_ESCALATION_SHADOW_MAX', 'fleet-ops#7414'):
        check(needle in text_s, 'silent-close names %s' % needle)
    for needle in ('escalation-shadow', 'parked-gate-eval', 'gate_resolved',
                   'matrix_decision', 'JEV_ESCALATION_SHADOW', 'fleet-ops#7414'):
        check(needle in text_i, 'intake names %s' % needle)
    for needle in ('escalation-shadow', 'matrix_decision', 'release_is_safe',
                   'gate_resolved', 'matches_silent_close', 'parked-gate-eval',
                   'claim-release', 'silent-pr-close', 'f8b567588', '9f0cba02c',
                   'pi-issue-start', 'systemd restart', 'conference', 'notify'):
        check(needle in text_d, 'split doc names %s' % needle)

    for name, text in (('claim-release', text_c), ('silent-close', text_s),
                       ('intake', text_i)):
        b = extract_block(text, 'escalation-shadow')
        check(b is not None, '%s block extracted' % name)
        if b is None:
            continue
        try:
            compile(b, '%s-block' % name, 'exec')
            check(True, '%s embedded python compiles' % name)
        except SyntaxError as exc:
            check(False, '%s embedded python compiles (%s)' % (name, exc))
            continue
        for var in ('VERCEL_AI_GATEWAY_JEV_KEY', 'GH_TOKEN', 'TELEGRAM_BOT_TOKEN'):
            check(var not in b, '%s block never references %s' % (name, var))
        check(not re.search(r'(?:print|note)\([^)]*(?:\+\s*key\b|%\s*key\b|,\s*key\b)', b),
              '%s key variable never interpolated into a print/note call' % name)

    # ---- functional: real bins end-to-end --------------------------------
    srv = HTTPServer(('127.0.0.1', 0), JevStub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    endpoint = 'http://127.0.0.1:%d/jev' % srv.server_port

    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        write_stub_gh(td)
        log = td / 'escalation-shadow.jsonl'

        # -- fleet-claim-release ------------------------------------------
        # 1. release path: no open PR, open in-progress issue, branch 0 ahead
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9001'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, endpoint, log))
        check(r.returncode == 0, 'claim release: exit 0 (rc=%s %s)' % (r.returncode, r.stderr[-300:]))
        check('RELEASED' in r.stderr, 'claim release: RELEASED logged')
        check(len(JevStub.hits) == 1, 'claim release: one shadow POST')
        rs = rows(log)
        check(len(rs) == 1 and rs[0]['site'] == 'escalation-shadow'
              and rs[0]['decision_class'] == 'claim-release'
              and rs[0]['matrix_decision'] == 'released'
              and rs[0]['advisory_only'] is True
              and rs[0]['answers']['release_is_safe']['probability'] == 0.8,
              'claim release row %s' % (rs[-1] if rs else None))
        st = JevStub.hits[0].get('state') or {}
        check(st.get('matrix_decision') == 'released'
              and st.get('decision_class') == 'claim-release',
              'claim release POST state carries the matrix decision')

        # 2. held-open-pr: open PR on the claim branch
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9002'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, endpoint, log,
                                         {'MOCK_OPEN_PRS': '[{"number": 9007}]'}))
        check(r.returncode == 0 and 'HELD' in r.stderr, 'held-open-pr: exit 0, HELD')
        rs = rows(log)
        check(len(rs) == 1 and rs[0]['matrix_decision'] == 'held-open-pr',
              'held-open-pr row %s' % (rs[-1] if rs else None))
        st = JevStub.hits[0].get('state') or {}
        check(st.get('open_prs') == ['9007'], 'held-open-pr state carries the PR list')

        # 3. fail-closed hold: open-PR check errors
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9003'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, endpoint, log, {'MOCK_PULLS_RC': '22'}))
        check(r.returncode == 0 and 'OPEN-PR-CHECK-FAILED' in r.stderr,
              'failclosed: exit 0, check failed')
        rs = rows(log)
        check(len(rs) == 1 and rs[0]['matrix_decision'] == 'held-failclosed-pr-check',
              'failclosed row %s' % (rs[-1] if rs else None))

        # 4. shadow off: no POST, no row, decision still acts
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9004'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, endpoint, log,
                                         {'JEV_ESCALATION_SHADOW': '0'}))
        check(r.returncode == 0 and 'RELEASED' in r.stderr
              and len(JevStub.hits) == 0 and len(rows(log)) == 0,
              'shadow off: released, zero POSTs, zero rows')

        # 5. dead endpoint: decision still acts, no row
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9005'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, 'http://127.0.0.1:1/jev', log))
        check(r.returncode == 0 and 'RELEASED' in r.stderr and len(rows(log)) == 0,
              'dead endpoint: released anyway (fail-open)')

        # 6. dry-run: no shadow row (a dry run is not a real decision)
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(CLAIM), 'fleet-ops-9006', '--dry-run'],
                           capture_output=True, text=True, timeout=60,
                           env=claim_env(td, endpoint, log))
        check(r.returncode == 0 and len(JevStub.hits) == 0 and len(rows(log)) == 0,
              'dry-run: no shadow call')

        # -- fleet-silent-pr-close-check -----------------------------------
        closed_prs = json.dumps([
            {'number': 7101, 'head': {'ref': 'claim/issue-7101'}, 'merged_at': None},
            {'number': 7102, 'head': {'ref': 'claim/issue-7102'}, 'merged_at': None},
        ])
        flag_timeline = json.dumps([
            {'event': 'closed', 'created_at': '2026-09-22T00:10:00Z',
             'actor': {'login': 'nishfleet-worker[bot]'}},
        ])
        merged_timeline = json.dumps([
            {'event': 'closed', 'created_at': '2026-09-22T00:05:00Z',
             'actor': {'login': 'nishfleet-worker[bot]'}},
            {'event': 'merged', 'created_at': '2026-09-22T00:05:01Z',
             'actor': {'login': 'nishfleet-worker[bot]'}},
        ])

        # 7. flag + skip in one run: two shadow rows with the right verdicts
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(SILENT), 'fleet-ops'],
                           capture_output=True, text=True, timeout=90,
                           env=silent_env(td, endpoint, log, {
                               'MOCK_CLOSED_PRS': closed_prs,
                               'MOCK_TIMELINE_7101': flag_timeline,
                               'MOCK_TIMELINE_7102': merged_timeline}))
        check(r.returncode == 1 and 'SILENT-PR-CLOSE' in r.stdout,
              'silent-close: flags the #6258 shape (rc=%s)' % r.returncode)
        check(len(JevStub.hits) == 2, 'silent-close: one POST per evaluated candidate')
        rs = rows(log)
        check(len(rs) == 2
              and rs[0]['decision_class'] == 'silent-pr-close'
              and rs[0]['matrix_decision'].startswith('flag')
              and rs[1]['matrix_decision'] == 'skip\tmerged',
              'silent-close rows %s' % [r0.get('matrix_decision') for r0 in rs])

        # 8. dead endpoint: flag still lands, exit code unchanged
        JevStub.hits.clear(); log.unlink(missing_ok=True)
        r = subprocess.run(['bash', str(SILENT), 'fleet-ops'],
                           capture_output=True, text=True, timeout=90,
                           env=silent_env(td, 'http://127.0.0.1:1/jev', log, {
                               'MOCK_CLOSED_PRS': closed_prs,
                               'MOCK_TIMELINE_7101': flag_timeline,
                               'MOCK_TIMELINE_7102': merged_timeline}))
        check(r.returncode == 1 and 'SILENT-PR-CLOSE' in r.stdout
              and len(rows(log)) == 0,
              'silent-close dead endpoint: flag still lands (fail-open)')

        # -- prompts/intake.md gate-eval block ------------------------------
        block = extract_block(text_i, 'parked-gate-eval')
        check(block is not None, 'intake gate-eval block found')
        if block:
            bfile = td / 'gate-eval-block.py'
            bfile.write_text(block)
            ev = td / 'evidence.json'
            ev.write_text(json.dumps({'gate_text': 'blocked-on: Nishfleet/fleet-ops#9999',
                                      'probe': 'gh issue view 9999',
                                      'result_summary': 'state: CLOSED'}))

            # 9. released verdict -> one row, gate_resolved logged
            JevStub.hits.clear(); log.unlink(missing_ok=True)
            env = dict(os.environ)
            env.update(dict(LITELLM_JEV_KEY='test-key-7414',
                            JEV_ESCALATION_SHADOW_ENDPOINT=endpoint,
                            JEV_ESCALATION_SHADOW_LOG=str(log)))
            env.pop('JEV_ESCALATION_SHADOW', None)
            r = subprocess.run(['python3', '-', 'gate-eval', 'fleet-ops', '8888',
                                'blocked-on-issue', 'released', str(ev)],
                               stdin=open(bfile), capture_output=True, text=True,
                               timeout=60, env=env)
            check(r.returncode == 0 and 'gate_resolved' in r.stdout,
                  'gate-eval released: row + printed line (rc=%s %s%s)'
                  % (r.returncode, r.stdout[-120:], r.stderr[-120:]))
            rs = rows(log)
            check(len(rs) == 1 and rs[0]['decision_class'] == 'parked-gate-eval'
                  and rs[0]['matrix_decision'] == 'released'
                  and rs[0]['gate_form'] == 'blocked-on-issue'
                  and rs[0]['answers']['gate_resolved']['probability'] == 0.8,
                  'gate-eval row %s' % (rs[-1] if rs else None))
            st = JevStub.hits[0].get('state') or {}
            check(st.get('gate_text') == 'blocked-on: Nishfleet/fleet-ops#9999',
                  'gate-eval state carries the untrusted gate text')

            # 10. bad decision arg -> no row, exit 0
            JevStub.hits.clear(); log.unlink(missing_ok=True)
            r = subprocess.run(['python3', '-', 'gate-eval', 'fleet-ops', '8888',
                                'blocked-on-issue', 'bogus', str(ev)],
                               stdin=open(bfile), capture_output=True, text=True,
                               timeout=60, env=env)
            check(r.returncode == 0 and 'unavailable' in r.stdout
                  and len(JevStub.hits) == 0,
                  'gate-eval bad decision: unavailable, no POST')

            # 11. stayed-parked verdict -> row with that matrix decision
            JevStub.hits.clear(); log.unlink(missing_ok=True)
            r = subprocess.run(['python3', '-', 'gate-eval', 'fleet-ops', '8889',
                                'runtime-gate', 'stayed-parked', str(ev)],
                               stdin=open(bfile), capture_output=True, text=True,
                               timeout=60, env=env)
            rs = rows(log)
            check(r.returncode == 0 and len(rs) == 1
                  and rs[0]['matrix_decision'] == 'stayed-parked'
                  and rs[0]['gate_form'] == 'runtime-gate',
                  'gate-eval stayed-parked row')

    # ---- replay: re-validate every emitted row ----------------------------
    # regenerate a corpus: rerun scenarios into one log
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        write_stub_gh(td)
        log = td / 'escalation-shadow.jsonl'
        subprocess.run(['bash', str(CLAIM), 'fleet-ops-9101'],
                       capture_output=True, text=True, timeout=60,
                       env=claim_env(td, endpoint, log))
        subprocess.run(['bash', str(CLAIM), 'fleet-ops-9102'],
                       capture_output=True, text=True, timeout=60,
                       env=claim_env(td, endpoint, log,
                                     {'MOCK_OPEN_PRS': '[{"number": 9150}]'}))
        corpus = rows(log)
        check(len(corpus) == 2, 'replay corpus: two rows')
        for row in corpus:
            check(row.get('site') == 'escalation-shadow'
                  and row.get('decision_class') in
                  ('claim-release', 'silent-pr-close', 'parked-gate-eval')
                  and isinstance(row.get('matrix_decision'), str)
                  and row.get('advisory_only') is True
                  and isinstance((row.get('answers') or {}), dict),
                  'replay: row shape %s' % row.get('ref'))
            p = (row.get('probabilities') or {}).get(
                list(row.get('probabilities') or {'x': None})[0])
            check(isinstance(p, float) and 0.0 <= p <= 1.0,
                  'replay: probability in [0,1]')

    srv.shutdown()
    if FAILS:
        print('\n%d failures' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('escalation-shadow: all scenarios passed (fleet-ops#7414)')


if __name__ == '__main__':
    main()
