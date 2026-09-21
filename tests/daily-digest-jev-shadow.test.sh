#!/usr/bin/env bash
# fleet-ops#7393: the daily-digest prompt carries the advisory Jev shadow tier.
# Static prompt contract + a python syntax gate on the embedded block. The
# prompt is the digest organ since the 2026-09-18 glue sweep, so these are
# content assertions on prompts/daily-digest.md, not shell behaviour.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

prompt=prompts/daily-digest.md
[[ -f "$prompt" ]] || fail "prompt missing: $prompt"

# 1. Shadow section sits between the gather steps and the send section.
grep -q '^## Shadow Jev tier — advisory, never a gate (fleet-ops#7393)$' "$prompt" \
  || fail "shadow section heading missing"
grep -q '^## Send — THIS IS THE DELIVERABLE$' "$prompt" \
  || fail "send section heading missing"
python3 - "$prompt" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
shadow = next(i for i, l in enumerate(lines) if l.startswith('## Shadow Jev tier'))
send = next(i for i, l in enumerate(lines) if l.startswith('## Send —'))
assert shadow < send, 'shadow must precede send'
assert send - shadow > 5, 'shadow section is empty'
PY
ok "shadow section precedes the send section"

# 2. Exactly one python heredoc block; extract and syntax-check it.
blocks=$(grep -c "^python3 - <<'PY'$" "$prompt")
[[ "$blocks" == 1 ]] || fail "expected exactly one python heredoc, got $blocks"
python3 - "$prompt" <<'PY'
import sys
text = open(sys.argv[1]).read()
start = text.index("python3 - <<'PY'")
block = text[start + len("python3 - <<'PY'"):]
end = block.index("\nPY\n")
block = block[:end]
compile(block, 'jev-shadow-block', 'exec')
PY
embedded=$(sed -n "/^python3 - <<'PY'$/,/^PY$/p" "$prompt" | sed '1d;$d')
printf '%s\n' "$embedded" > /tmp/jev-shadow-block.py
python3 -c "compile(open('/tmp/jev-shadow-block.py').read(), 'jev-shadow-block', 'exec')"
ok "embedded python block compiles"

# 3. Off-flag, site name, log path and the sanctioned proxy endpoint are named.
grep -q "JEV_HERMES" "$prompt" || fail "off flag JEV_HERMES missing"
grep -q "JEV_HERMES') == '0'" "$prompt" || fail "off-flag branch missing"
grep -q "hermes-digest.jsonl" "$prompt" || fail "JSONL log path missing"
grep -q "site='hermes-digest'" "$prompt" || fail "site name missing in rows"
grep -q "127.0.0.1:4000/jev" "$prompt" || fail "sanctioned pass-through endpoint missing"
ok "off flag, site name, log path, endpoint present"

# 4. Advisory semantics: rows are advisory_only, rule tier digest, disagree
#    field driven by the site's act_hi edge from config/jev-bands.json
#    (fleet-ops#7439) — never a local constant.
grep -q "advisory_only=True" "$prompt" || fail "advisory_only marker missing"
grep -q "rule_tier='digest'" "$prompt" || fail "rule_tier missing"
grep -q "p >= act_hi" "$prompt" || fail "disagree edge check missing"
grep -q "jev-bands.json" "$prompt" || fail "bands table reference missing"
if grep -q "p >= 0\.5" "$prompt"; then fail "local 0.5 threshold constant crept back"; fi
ok "advisory markers present"

# 5. Privacy: the block reads the virtual key from the seat file, never the
#    raw gateway variable, never the bot token, and never prints a key.
grep -q "LITELLM_JEV_KEY" "$prompt" || fail "virtual key read missing"
grep -q "never.*inline.*key\|never printed" "$prompt" || fail "key-hygiene line missing"
if grep -q "VERCEL_AI_GATEWAY_JEV_KEY" "$prompt"; then fail "raw gateway key must not be referenced by the digest"; fi
if grep -q "TELEGRAM_BOT_TOKEN" "$prompt" && ! grep -qi "never print" "$prompt"; then
  fail "token hygiene line missing"
fi
python3 - <<'PY'
import re
block = open('/tmp/jev-shadow-block.py').read()
for var in ('TELEGRAM_BOT_TOKEN', 'VERCEL_AI_GATEWAY_JEV_KEY', 'TELEGRAM_CHAT_ID'):
    assert var not in block, var
# the key variable must never be expanded into a print/log call
for m in re.finditer(r"(?:print|log)\(.*(?:'{|\"{%s|{key)" % 'key', block, re.S):
    assert 'Bearer' not in m.group(0), 'key leaked into a print call'
assert "add_header('Authorization', 'Bearer ' + key)" in block
PY
ok "no credential or token reference inside the block; key only reaches the header"

# 6. Failure isolation: the send mandate survives unchanged after the shadow
#    step — sending is still the deliverable and is never gated on advice.
grep -q "You are NOT done" "$prompt" || fail "send mandate missing"
grep -q "the send MUST still run" "$prompt" || fail "send-not-gated rule missing"
grep -q "api.telegram.org" "$prompt" || fail "send curl missing"
ok "send mandate intact; advice can never block the send"

echo "all daily-digest-jev-shadow cases passed"
