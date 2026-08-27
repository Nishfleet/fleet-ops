#!/usr/bin/env bash
# tests/fleet-failed-command-python-c-shell-unterminated-quote.test.sh
#
# fleet-ops#1141: a `python3 -c "..."` whose script text contains a
# Python single-quoted string (e.g. `print('Scout JSON:', ...)`) is run
# by the harness under `bash -c` with the command wrapped in a quoting
# context that makes bash treat the inner `'` as the OPEN of a shell
# single-quote. Bash then scans to EOF looking for the close, and fails
# with:
#   /bin/bash: -c: line 12: unexpected EOF while looking for matching `''
#   Command exited with code 2
# isError=true. The command is NOT a no-match probe (it is not
# grep/rg/diff/ls/which/git-ref), so the generic `isError or code != 0`
# path flags it. The assistant walked past the failure with a sibling
# `grep -oP` toolCall in the SAME turn (no user-facing text), then a
# 503 from the upstream model, then a NEW turn with a different
# shell-embedded regex (also unfixed) — the failure was never named
# in user-facing text.
#
# The detector already flags this class via the generic
# `isError or code != 0` path. No `lib/failed-command-flagged.py`
# detection-logic change is needed — a suppression would silence a
# real signal. The fix is the three-place citation lock so a future
# refactor cannot regress the live shape:
#   - treat a `python3 -c "..."` whose snippet carries
#     "unexpected EOF while looking for matching" + "Command exited
#     with code 2" as a probe (it is not)
#   - let a same-turn sibling `grep -oP` toolCall mask the failure
#   - let a later thinking-only recovery turn discharge the class
#   - let later unrelated user-facing prose discharge the class
#   - let the harness's 503/retry cycle swallow a non-recovered
#     python3-c failure
# The auto-filed issue closes via observe-to-close (fleet-ops#650)
# when the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T12-14-06-249Z_01a04324-47a9-7f32-9e76-2d25b1b903d4.jsonl
# The minimax-m3-free worker on fleet-ops#1141 fired TWO bash toolCalls
# in one turn (slug a1e538b9, 2026-08-27T12:29:14Z):
#   1. `curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c "
#      import sys, re
#      ...
#      json_data = re.findall(r'\\\\\"scout\\\\\"...', html, re.DOTALL)
#      if json_data:
#          print('Scout JSON:', json_data[0][:1000])
#      "`  (failed: bash parse error on the `'` in `print('Scout JSON:'`,
#      the harness's quoting context makes bash open a shell
#      single-quote that never closes; harness reported
#      `/bin/bash: -c: line 12: unexpected EOF while looking for
#      matching `''` + `Command exited with code 2`, isError=true)
#   2. `curl -sS 'https://0509.io/pricing' 2>&1 | grep -oP
#      '"scout_monthly_v1".*?"scout_annual_v1"' | head -1 |
#      python3 -c "import sys; line = sys.stdin.read(); print(...)"`
#      (succeeded — the same turn's sibling, no user-facing flag).
# The next turn was empty content (stopReason: error, 503 from
# upstream). The turn after that fired a third bash toolCall with a
# DIFFERENT shell-embedded regex (also unfixed) — the python3-c
# failure was never named.
#
# Distinct from:
#   - #957: `python3 -c` probe that crashes with a Python traceback
#     (KeyError, NameError) + "Command exited with code 1" — the
#     python actually RAN, the traceback is a Python-level error, not
#     a bash parse error. The live #1141 snippet is
#     "unexpected EOF while looking for matching `''" — a BASH parse
#     error, not a Python traceback.
#   - #793: `bash /tmp/<fresh-script>` exit 1 with the same empty
#     snippet — the script's `set -e` killed it before any echo. The
#     live #1141 snippet is NOT empty; it carries
#     "unexpected EOF while looking for matching `''" + the
#     "Command exited with code 2" trailer.
#   - #1217: same-turn sibling of a `git clone` that races with
#     `cd /tmp/<fresh-clone> 2>/dev/null && ls` — the snippet is
#     `(no output)  Command exited with code 1`. The live #1141
#     snippet is "unexpected EOF while looking for matching `''" +
#     "Command exited with code 2" (different wording, different
#     code).
#   - #1061: compound bash chain with `ls ... Permission denied` —
#     different snippet (real `ls: cannot access` line) and different
#     code (1, not 2).
#   - python3-hyphen #937: `python3 -c "from <hyphen> import ..."`
#     ModuleNotFoundError — Python runs, ModuleNotFoundError, exit 1.
#     The live #1141 is a BASH parse error before python even starts.
#
# Scenarios:
#   1. live #1141 shape: python3 -c with script containing
#      `print('Scout JSON:', ...)` + sibling grep -oP in the same turn
#      -> finding. Snippet must carry "unexpected EOF while looking
#      for matching" and "Command exited with code 2".
#   2. same shape plus a later thinking-only recovery -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: the live #1141 sibling `grep -oP` toolCall on its
#      own (no python3 -c, no isError) stays clean. The point is the
#      python3-c failure must be the finding, not the sibling.
#   6. worker.md cites fleet-ops#1141 and the live
#      "unexpected EOF while looking for matching" wording (prompt-side
#      lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1141
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-python-c-shell-unterminated-quote.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T12:14:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T13:00:00Z"
}

# --- 1. live #1141 shape: python3 -c parse error + sibling grep walked past
# Replay the exact same-turn pair from slug 01a04324: a python3 -c whose
# script carries a `print('Scout JSON:', ...)` line, and a sibling
# `grep -oP '..."scout_monthly_v1"...'` in the same turn. The python3 -c
# fails with "unexpected EOF while looking for matching `''" + "Command
# exited with code 2" (bash parse error, isError=true). The sibling grep
# succeeds. The next assistant turn is a 503 (upstream error). No
# user-facing text names the failure. Detector must flag.
write_session "python-c-shell-unterminated-quote-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The visible HTML shows €9 for Scout. Let me check the embedded JSON for the real USD price."},{"type":"toolCall","id":"call_python_c","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nscout_block = re.search(r'scout.*?\\\"display\\\":\\\"€225\\\".*?scout.*?\\\"display\\\":\\\"€9\\\".*?scout.*?\\\"display', html, re.DOTALL)\nscout_match = re.findall(r'\\\"scout.*?monthly.*?€9.*?€72', html, re.DOTALL)\njson_data = re.findall(r'\\\\\\\\\\\"scout\\\\\\\\\\\".*?\\\\\\\\\\\"scout_monthly_v1\\\\\\\\\"', html, re.DOTALL)\nif json_data:\n    print('Scout JSON:', json_data[0][:1000])\n\""}},{"type":"toolCall","id":"call_sibling_grep","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | grep -oP '\"scout_monthly_v1\".*?\"scout_annual_v1\"' | head -1 | python3 -c \"\nimport sys\nline = sys.stdin.read()\nprint('Scout plan JSON snippet:', line[:500])\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_python_c","toolName":"bash","content":[{"type":"text","text":"/bin/bash: -c: line 12: unexpected EOF while looking for matching `''\n\n\nCommand exited with code 2"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_sibling_grep","toolName":"bash","isError":false,"content":[{"type":"text","text":"Scout plan JSON snippet: "}]}}
{"type":"message","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"commandcode","model":"poolside/laguna-s-2.1-free","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","timestamp":1787833754727,"errorMessage":"503: {\"message\":\"Upstream model provider is temporarily unavailable. Please try again in a moment.\",\"type\":\"overloaded_error\"}"}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry_reprobe","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | grep -oE 'scoutSaleOpen.*?\"scout\".*?monthlyLabel.*?\"Scout\"' | head -1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1141 python3 -c shell-unterminated-quote walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'unexpected EOF while looking for matching' <<<"$snippet" \
  || fail "finding snippet should mention 'unexpected EOF while looking for matching' (got $snippet)"
grep -q 'Command exited with code 2' <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 2' (got $snippet)"
ok "live #1141: python3 -c shell-unterminated-quote with sibling grep recovery is flagged"
rm -f "$sessions/python-c-shell-unterminated-quote-walked.jsonl"

# --- 2. same shape plus later thinking-only recovery is still a finding -
# The live session's 503 turn was followed by a recovery turn with a
# thinking block that rationalised the failure ("The script has an
# unescaped single-quote in the Python `print('...')` line..."). A
# thinking block is not a user-facing flag (fleet-ops#535 / #953).
# Pin that a future `_text_chunks` change that starts collecting
# `thinking` fields still cannot discharge this class.
write_session "python-c-shell-unterminated-quote-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_python_c2","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nif True:\n    print('Scout JSON:')\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_python_c2","toolName":"bash","content":[{"type":"text","text":"/bin/bash: -c: line 12: unexpected EOF while looking for matching `''\n\n\nCommand exited with code 2"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The python3 -c failed because the script has an unescaped single-quote in the Python `print('...')` line. The harness's quoting context makes bash open a shell single-quote on the inner `'`. I should rewrite the probe to avoid the single-quote entirely (use double-quoted Python strings with backslash escapes)."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nm = re.search(r'\\\"Scout\\\"', html)\nprint(m)\n\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "python3 -c shell-unterminated-quote with thinking-only recovery should be a finding (got $count) $report"
ok "live #1141: python3 -c shell-unterminated-quote with later thinking-only recovery is still flagged"
rm -f "$sessions/python-c-shell-unterminated-quote-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ------------
# A later assistant turn that says "The page shows €9 for Scout and
# $11 USD/mo in the embedded JSON — the discrepancy is a pricing
# localisation artefact." is unrelated user-facing prose that does
# NOT name the python3-c failure. It must NOT clear the class.
write_session "python-c-shell-unterminated-quote-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_python_c3","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nif True:\n    print('Scout JSON:')\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_python_c3","toolName":"bash","content":[{"type":"text","text":"/bin/bash: -c: line 12: unexpected EOF while looking for matching `''\n\n\nCommand exited with code 2"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The page shows €9 for Scout and $11 USD/mo in the embedded JSON — the discrepancy is a pricing localisation artefact."},{"type":"toolCall","id":"call_retry3","name":"bash","arguments":{"command":"echo 'moving on'"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "python3 -c shell-unterminated-quote followed by unrelated prose should be a finding (got $count) $report"
ok "live #1141: python3 -c shell-unterminated-quote with unrelated user-facing prose is still flagged"
rm -f "$sessions/python-c-shell-unterminated-quote-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean --------------
# The standing rule is satisfied when the assistant names the failure
# in user-facing text in the same turn. The detector must NOT flag.
write_session "python-c-shell-unterminated-quote-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_python_c4","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nif True:\n    print('Scout JSON:')\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_python_c4","toolName":"bash","content":[{"type":"text","text":"/bin/bash: -c: line 12: unexpected EOF while looking for matching `''\n\n\nCommand exited with code 2"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 -c call failed with 'unexpected EOF while looking for matching' (the inner `print('Scout JSON:')` line has an unescaped single-quote that the harness's bash quoting treats as the open of a shell single-quote). fixing by rewriting the probe to use only double-quoted Python strings."},{"type":"toolCall","id":"call_retry4","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | python3 -c \"\nimport sys, re\nhtml = sys.stdin.read()\nm = re.search(r'\\\"Scout\\\"', html)\nprint(m)\n\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "python3 -c shell-unterminated-quote with later user-facing flag should be clean (got $count) $report"
ok "python3 -c shell-unterminated-quote plus later user-facing flag is clean"
rm -f "$sessions/python-c-shell-unterminated-quote-flagged.jsonl"

# --- 5. cross-check: the live #1141 sibling grep -oP on its own stays clean
# The live session's second toolCall in the same turn was a
# `curl ... | grep -oP '..."scout_monthly_v1"...' | head -1 | python3 -c`
# that SUCCEEDED. A single-turn with only the sibling grep -oP (no
# python3-c parse error) must stay clean. Pin that locking #1141
# must not collapse into "every multi-call turn is a failure".
write_session "python-c-shell-unterminated-quote-sibling-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Looking for the Scout plan JSON in the embedded stream."},{"type":"toolCall","id":"call_sibling_grep2","name":"bash","arguments":{"command":"curl -sS 'https://0509.io/pricing' 2>&1 | grep -oP '\"scout_monthly_v1\".*?\"scout_annual_v1\"' | head -1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_sibling_grep2","toolName":"bash","isError":false,"content":[{"type":"text","text":"scout_monthly_v1\","},"]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Found the embedded JSON block for the Scout plan."},{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"echo 'moving on'"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "sibling grep -oP on its own (no python3-c parse error) must stay clean (got $count) $report"
ok "sibling grep -oP on its own stays clean (contrast with #1141)"
rm -f "$sessions/python-c-shell-unterminated-quote-sibling-only.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1141 (prompt-side lock) ------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1141' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1141 (prompt-side lock for the live python3-c shell-unterminated-quote shape)"
grep -q 'unexpected EOF while looking for matching' "$worker" \
  || fail "prompts/worker.md must name the live 'unexpected EOF while looking for matching' wording so workers flag it"
ok "worker.md cites fleet-ops#1141 and the live 'unexpected EOF while looking for matching' wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1141 ---
# (detector-side lock). The docstring is the standing-rule contract
# for the next detector maintainer, and dropping the #1141 citation
# is a regression even if the drill still passes. Same pattern as
# #1217 scenario 7: a future refactor that drops the citation from
# the docstring still has the prompt lock and the drill, but the
# docstring is what the next maintainer reads to know which
# session/signal the class came from.
grep -q 'fleet-ops#1141' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1141 (detector-side lock)"
grep -q 'unexpected EOF while looking for matching' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'unexpected EOF while looking for matching' wording"
grep -q "print('Scout JSON:'" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'print('Scout JSON:')' python-script wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1141 and the shell-unterminated-quote shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---
grep -Fq 'bash "$here/fleet-failed-command-python-c-shell-unterminated-quote.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-python-c-shell-unterminated-quote: live #1141 walked-past drills"
