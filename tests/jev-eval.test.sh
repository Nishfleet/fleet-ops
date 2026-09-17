#!/bin/bash
# bin/jev-eval contract tests (fleet-ops#7371). No network, no key, no SDK: everything
# runs under a throwaway HOME so real logs and spend are never touched.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
J="$here/bin/jev-eval.mjs"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v node >/dev/null || fail "node missing"
export HOME="$(mktemp -d)"; trap 'rm -rf "$HOME"' EXIT
L="$HOME/.local/state/pi-packet/jev/test-dry.jsonl"

# 1. dry-run: shape of stdout and of the per-site JSONL line
out=$(echo '{"state":"x","questions":{"q":{"type":"boolean","instructions":"x"}},"ref":"issue#7371"}' | "$J" --site test-dry --dry-run) || fail "dry-run exit"
echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["site"]=="test-dry" and d["ref"]=="issue#7371" and len(d["state_sha256"])==64 and "q" in d["answers"]' || fail "dry-run stdout shape"
[ -f "$L" ] || fail "per-site log missing: $L"
tail -1 "$L" | python3 -c 'import sys,json;d=json.loads(sys.stdin.read());[d[k] for k in ("ts","site","ref","state_sha256","answers","probabilities","usage","ms")];assert d["synthetic"] is True and d["dry_run"] is True' || fail "JSONL line shape / synthetic flag"
[ "$(stat -c %a "$L" 2>/dev/null || stat -f %Lp "$L")" = "600" ] || fail "log perms must be 600"

# 2. refusals: any non-Jev model, bad stdin, missing questions -> exit 2
echo '{"model":"gpt-5","state":"x","questions":{"q":{"type":"boolean","instructions":"x"}}}' | "$J" --dry-run >/dev/null 2>&1; [ $? -eq 2 ] || fail "non-Jev model must exit 2"
echo 'not json' | "$J" --dry-run >/dev/null 2>&1; [ $? -eq 2 ] || fail "bad stdin must exit 2"
echo '{"state":"x"}' | "$J" --dry-run >/dev/null 2>&1; [ $? -eq 2 ] || fail "missing questions must exit 2"

# 3. --synthetic marks the row; --ref flag wins over input.ref; site is sanitised
echo '{"state":"y","questions":{"q":{"type":"boolean","instructions":"y"}},"ref":"in"}' | "$J" --site 'a/b c' --ref flag --synthetic --dry-run >/dev/null || fail "synthetic run"
tail -1 "$HOME/.local/state/pi-packet/jev/a_b_c.jsonl" | python3 -c 'import sys,json;d=json.loads(sys.stdin.read());assert d["synthetic"] is True and d["ref"]=="flag" and d["site"]=="a_b_c"' || fail "synthetic/ref/site sanitise"

# 4. spend cap: a spend file at the cap makes the next call exit 3 before any network
printf '{"usd":1,"calls":1,"inputTokens":0}' > "$HOME/.local/state/pi-packet/jev/spend.json"
echo '{"state":"x","questions":{"q":{"type":"boolean","instructions":"x"}}}' | "$J" --dry-run >/dev/null 2>&1; [ $? -eq 3 ] || fail "spend cap must exit 3"

# 5. no key material anywhere in the logs
grep -rq "VERCEL_AI_GATEWAY_JEV_KEY=" "$HOME/.local/state/pi-packet/jev" && fail "key leaked into log"
grep -q "console.log" "$J" && fail "helper must not console.log (key hygiene)"
# 6. Second opinion CLI contract. The SDK alone is stubbed; the real helper,
# logs, framing, accounting and comparison all run. Invented fixtures stay synthetic.
python3 - "$J" <<'PY' || fail "second-opinion contracts"
import json, os, pathlib, subprocess, sys
home = pathlib.Path(os.environ['HOME'])
root = home / '.local/state/pi-packet/jev'
spend = root / 'spend.json'
lib = home / 'sdk'
(lib / 'node_modules/ai').mkdir(parents=True)
(lib / 'package.json').write_text('{}')
(lib / 'node_modules/ai/package.json').write_text('{"main":"index.js"}')
(lib / 'node_modules/ai/index.js').write_text('''
let n = 0;
exports.experimental_evaluate = async (input) => {
  require('node:fs').appendFileSync(process.env.CAPTURE, JSON.stringify(input) + '\\n');
  if (++n === 2 && process.env.FAIL_SECOND) throw new Error('second call failed');
  return {answers: JSON.parse(process.env.ANSWERS)[n-1], usage: {inputTokens: 100, outputTokens: 2, totalTokens: 102}};
};
''')
key = home / '.config/fleet-ops/seats/typesafe-jev.env'
key.parent.mkdir(parents=True)
key.write_text('VERCEL_AI_GATEWAY_JEV_KEY=unit-test-only\n')
card = {'state': {'context': 'rules', 'item': 'card', 'history': ['record']},
        'questions': {'q': {'type': 'boolean', 'instructions': 'needs approval?'}},
        'site': 'ensemble', 'ref': 'synthetic-unit-test'}
def run(pair, *, payload=card, flags=(), env=None, cap=1):
    spend.write_text('{"usd":0,"calls":0,"inputTokens":0}')
    capture = home / 'capture.jsonl'
    capture.write_text('')
    e = dict(os.environ, JEV_EVAL_LIB=str(lib), CAPTURE=str(capture), ANSWERS=json.dumps(pair))
    e.update(env or {})
    p = subprocess.run([sys.executable.replace('python3', 'node')] if False else
        ['node', sys.argv[1], '--second-opinion', '--synthetic', '--cap-usd', str(cap), *flags],
        input=json.dumps(payload), text=True, capture_output=True, env=e)
    calls = [json.loads(x) for x in capture.read_text().splitlines()]
    return p, calls

def answer(kind, value):
    return {'q': {'type': kind, {'boolean':'probability','choice':'choice','score':'score'}[kind]: value}}
for kind, a, b, expected in [('boolean', .9, .8, False), ('boolean', .9, .1, True),
                            ('boolean', .5, .9, None), ('choice', 'yes', 'no', True),
                            ('choice', 'yes', 'yes', False), ('score', 2, 3, True),
                            ('score', 2, 2, False)]:
    payload = dict(card, questions={'q': {'type': kind, 'instructions': 'compare', 'criteria': {'yes':'yes','no':'no'}}})
    pair = [answer(kind, a), answer(kind, b)]
    p, calls = run(pair, payload=payload)
    assert p.returncode == 0, p.stderr
    d = json.loads(p.stdout)
    assert 'second_opinion' in d, 'stdout missing second_opinion'
    so = d['second_opinion']
    assert so['disagreement'] is expected, so
    assert so['a']['answers'] == pair[0] and so['b']['answers'] == pair[1]
    assert len(calls) == 2 and calls[0]['questions'] == calls[1]['questions'] == payload['questions']
    states = [json.loads(c['state']) for c in calls]
    assert states[0] == states[1] == card['state']
    assert list(states[0])[:2] == ['item','context'] and list(states[1])[:2] == ['context','item']
    assert so['a']['state_sha256'] != so['b']['state_sha256']
    assert json.loads(spend.read_text())['calls'] == 2
    assert json.loads(spend.read_text())['inputTokens'] == 200
    rows = [json.loads(x) for x in (root / 'ensemble.jsonl').read_text().splitlines()]
    assert rows[-1]['second_opinion'] == so and rows[-1]['synthetic']
    assert rows[-1]['ref'] == card['ref']
pair = [answer('boolean', .9), answer('boolean', .1)]
p, calls = run(pair, flags=['--dry-run'])
assert p.returncode == 0 and not calls
assert json.loads(p.stdout)['second_opinion']['disagreement'] is None
p, calls = run(pair, env={'JEV_SECOND_OPINION':'0'})
assert p.returncode == 0 and len(calls) == 1 and 'second_opinion' not in json.loads(p.stdout)
p, calls = run(pair, payload=dict(card, state='no context'))
assert p.returncode == 2 and not calls
p, calls = run(pair, env={'FAIL_SECOND':'1'})
assert p.returncode == 1 and not p.stdout and len(calls) == 2
assert json.loads(spend.read_text())['calls'] == 1
p, calls = run(pair, cap=.000001)
assert p.returncode == 3 and len(calls) == 1 and not p.stdout
assert json.loads(spend.read_text())['calls'] == 1
p, calls = run([{}, {}])
assert p.returncode == 0 and json.loads(p.stdout)['second_opinion']['disagreement'] is None
assert 'unit-test-only' not in (root / 'ensemble.jsonl').read_text()
PY

echo "jev-eval tests: green"
