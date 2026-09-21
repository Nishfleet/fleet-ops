#!/usr/bin/env bash
# fleet-ops#7389: the intake tick prompt carries the advisory Jev shadow tier
# (spec-quality 0-3, scope tier choice, duplicate probability per shortlisted
# candidate). Static prompt contract + a python syntax gate + two offline
# execution cases on the embedded block. The prompt is the intake organ since
# the 2026-09-18 glue sweep, so these are content assertions on
# prompts/intake.md, not shell behaviour.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

prompt=prompts/intake.md
[[ -f "$prompt" ]] || fail "prompt missing: $prompt"

# 1. Shadow section sits after the numbered steps (it runs on the step-5
#    claims) and before nothing else — it is the last section of the prompt.
grep -q '^## Shadow Jev tier — advisory, never a gate (fleet-ops#7389)$' "$prompt" \
  || fail "shadow section heading missing"
python3 - "$prompt" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
shadow = next(i for i, l in enumerate(lines) if l.startswith('## Shadow Jev tier'))
steps = [i for i, l in enumerate(lines) if l.startswith('6. Print one line per issue')]
assert steps, 'step 6 summary line missing'
assert shadow > steps[0], 'shadow must follow the tick steps'
assert len(lines) - shadow > 20, 'shadow section is empty'
PY
ok "shadow section follows the tick steps"

# 2. Exactly one python heredoc block; extract and syntax-check it.
blocks=$(grep -cE "^python3 - .*<<'PY'$" "$prompt")
[[ "$blocks" == 1 ]] || fail "expected exactly one python heredoc, got $blocks"
sed -n "/^python3 - .*<<'PY'$/,/^PY$/p" "$prompt" | sed '1d;$d' > /tmp/jev-intake-shadow-block.py
python3 -c "compile(open('/tmp/jev-intake-shadow-block.py').read(), 'jev-intake-shadow-block', 'exec')"
ok "embedded python block compiles"

# 3. Off-by-default flag, site name, log path and the sanctioned proxy
#    endpoint are named.
grep -q "JEV_PI_INTAKE" "$prompt" || fail "flag JEV_PI_INTAKE missing"
grep -q "JEV_PI_INTAKE') == '1'" "$prompt" || fail "enable branch missing"
grep -q "pi-intake.jsonl" "$prompt" || fail "JSONL log path missing"
grep -q "site='pi-intake'" "$prompt" || fail "site name missing in rows"
grep -q "127.0.0.1:4000/jev" "$prompt" || fail "sanctioned pass-through endpoint missing"
ok "flag, site name, log path, endpoint present"

# 4. All three advisory families and their question types are present:
#    score 0-3 spec, choice scope tier, boolean duplicate per candidate.
grep -q "advisory_only=True" "$prompt" || fail "advisory_only marker missing"
grep -q "type='score'" "$prompt" || fail "score question type missing"
grep -q "type='choice'" "$prompt" || fail "choice question type missing"
grep -q "type='boolean'" "$prompt" || fail "boolean question type missing"
grep -q "'light', 'normal', 'heavy', 'keystone'" "$prompt" || fail "scope tiers missing"
grep -q "0 - no acceptance criteria" "$prompt" || fail "spec-quality 0-3 criteria missing"
grep -q "possible-duplicate-of" "$prompt" || fail "duplicate marker missing"
grep -q "family = 'spec'" "$prompt" || fail "spec family missing"
grep -q "else 'dup'" "$prompt" || fail "dup family missing"
ok "spec/scope/dup families and question types present"

# 5. The duplicate candidate list is built in code; Jev only answers about
#    supplied candidates and never searches.
grep -q "SHORTLIST_N" "$prompt" || fail "shortlist size missing"
grep -q "def overlap(" "$prompt" || fail "token-overlap scorer missing"
grep -q "Jev never searches" "$prompt" || fail "no-search rule missing"
grep -q "shortlist" "$prompt" || fail "shortlist wiring missing"
ok "duplicate shortlist is computed in code, not by Jev"

# 6. Privacy: the block reads the virtual key from the seat file, never the raw
#    gateway variable, and the key only reaches the Authorization header.
grep -q "LITELLM_JEV_KEY" "$prompt" || fail "virtual key read missing"
if grep -q "VERCEL_AI_GATEWAY_JEV_KEY" "$prompt"; then fail "raw gateway key must not be referenced"; fi
python3 - <<'PY'
import re
block = open('/tmp/jev-intake-shadow-block.py').read()
assert "add_header('Authorization', 'Bearer ' + key)" in block, 'key never reaches the header'
assert "print(key)" not in block and "log(key)" not in block, 'key printed'
assert "Bearer ' + key" in block
PY
ok "key comes from the seat file and only reaches the header"

# 7. Failure isolation and the tick's unchanged job: any failure prints
#    "advisory unavailable" and the tick still labels, claims, summarises and
#    exits 0. Advice can never block a claim.
grep -q "advisory unavailable" "$prompt" || fail "failure-isolation note missing"
grep -q "rules unchanged" "$prompt" || fail "rules-unchanged note missing"
grep -q "skipped-noise-class" "$prompt" || fail "step-6 summary mandate missing"
grep -q "never close an issue" "$prompt" || fail "never-close rule missing"
grep -q "at most one" "$prompt" || fail "one-comment-per-issue cap missing"
ok "tick job unchanged; advice can never block a claim or the exit code"

# 8. Offline execution cases: flag off is inert, and enabled-without-issues
#    never reaches the network or the key.
out=$(env -u JEV_PI_INTAKE -u LITELLM_JEV_KEY python3 /tmp/jev-intake-shadow-block.py 2>&1) \
  || fail "off-by-default path exited non-zero"
grep -q "advisory off" <<<"$out" || fail "off-by-default path did not report itself off"
out=$(env -u LITELLM_JEV_KEY JEV_PI_INTAKE=1 python3 /tmp/jev-intake-shadow-block.py 2>&1) \
  || fail "enabled-without-issues path exited non-zero"
grep -q "no claimed issues passed" <<<"$out" || fail "missing no-issues guard"
ok "off path inert, empty-args path inert"

echo "all intake-jev-shadow cases passed"
