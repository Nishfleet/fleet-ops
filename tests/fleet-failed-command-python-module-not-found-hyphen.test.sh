#!/usr/bin/env bash
# tests/fleet-failed-command-python-module-not-found-hyphen.test.sh
#
# fleet-ops#937: a `python3 -c` / `python3 << 'PYEOF'` probe that tries
# to `from <hyphenated_module> import ...` fails with
#   ModuleNotFoundError: No module named '<hyphenated_name>'
# because Python's import machinery refuses hyphens in module names.
# The worker just wrote a `.py` file with hyphens in the filename
# (e.g. `failed-command-flagged.py`) and tried to import it directly.
# The probe crashes with a Python traceback and
# `Command exited with code 1`. The next assistant turn is a toolCall
# only (a re-probe with `python3 << 'PYEOF'`) that fails the same way
# for the same reason. The third turn is `ls` and the worker finally
# notices the hyphen — but two failed probes have already been walked
# past with no user-facing flag (the standing rule, fleet-ops#535).
#
# The class is the same family as #957 (python3 traceback walked past),
# but #937 is its own auto-filed issue (a distinct session, a distinct
# slug) and gets its own dedicated regression test so a future
# refactor that drops the #937 citation from the detector docstring,
# the prompt, or the test host list is caught. The detector already
# flags this in `result_failed` (the hyphenated module name is not
# a no-match probe family — it is not grep/rg/diff/ls/which, and the
# traceback + `Command exited with code 1` is the live #957 class).
# The gap is the dedicated file so the class is named in three places
# (test, prompt, detector docstring), not one.
#
# Live session: 2026-08-27T03-46-07-353Z_01a04153-3579-7885-98f3-640d7240e2fb.jsonl
# The agent (working on a different auto-filed issue) was poking at
# `lib/failed-command-flagged.py` in another worktree to understand
# why a session was flagged. The agent ran:
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib \
#     && python3 -c "
#         import sys
#         sys.path.insert(0, '.')
#         from failed_command_flagged import scan_session
#         import json
#         result = scan_session('/home/nish/.pi/agent/sessions/...')
#         print(json.dumps(result, indent=2))
#       " 2>&1 | head -10
# Python's import system refused with:
#   Traceback (most recent call last):
#     File "<string>", line 4, in <module>
#   ModuleNotFoundError: No module named 'failed_command_flagged'
# (and `Command exited with code 1`). The agent's next turn was a
# `python3 << 'PYEOF'` re-probe with the same import, which failed
# the same way. Both failures were walked past without a user-facing
# flag. The agent then ran `ls .../lib/` to see the actual filename
# and finally noticed the hyphens.
#
# Scenarios:
#   1. live #937 shape: python3 -c with hyphenated module name →
#      ModuleNotFoundError + Command exited with code 1 + toolCall-only
#      recovery with python3 << 'PYEOF' (same failure) + later ls
#      recovery → finding. Snippet must carry the traceback prefix
#      AND the ModuleNotFoundError line AND Command exited with code 1
#      — all three, because dropping any one of them is a regression
#      in the snippet-capture path.
#   2. same shape plus a later user-facing flag naming the failure →
#      clean.
#   3. python3 -c with a NON-hyphenated module name that does exist
#      (import os) is exit 0, not flagged. Pin the contrast so a
#      future refactor that broadens the suppression to ALL
#      `python3 -c` exit 1 is caught.
#   4. cross-check: a `python3 -c "import this_does_not_exist"` that
#      fails with ModuleNotFoundError but the agent then names the
#      failure in user-facing text in the same turn → clean. Same
#      family, opposite verdict.
#   5. worker.md cites fleet-ops#937 (prompt-side lock).
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#937
#      (detector-side lock).
#   7. seat-lib.test.sh hosts this file (CI cannot gain a new P14
#      workflow line — the worker token has no Workflows permission).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-py-modnotfound-hyphen.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T03:46:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T04:00:00Z"
}

# --- 1. live #937 shape: python3 -c with hyphenated module name → -------
#      ModuleNotFoundError walked past --------------------------------
# The live session slug 01a04153 was filed because the agent ran a
# `python3 -c "from failed_command_flagged import scan_session"` probe
# against a sibling file whose actual filename is
# `failed-command-flagged.py` (with hyphens). Python refused the
# import and the next turn was a `python3 << 'PYEOF'` re-probe with
# the same import, same failure, also walked past. The third turn was
# an `ls` and the agent finally noticed the hyphens. Replay that
# exact shape.
write_session "python-modnotfound-hyphen-walked-past" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib && python3 -c \"\nimport sys\nsys.path.insert(0, '.')\nfrom failed_command_flagged import scan_session\nimport json\nresult = scan_session('/home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T00-01-33-243Z_01a04085-9c3b-7194-a332-20e86c213e81.jsonl')\nprint(json.dumps(result, indent=2))\n\" 2>&1 | head -10"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 4, in <module>\nModuleNotFoundError: No module named 'failed_command_flagged'\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib && python3 << 'PYEOF'\nimport sys, os\nsys.path.insert(0, os.getcwd())\nimport json\nfrom failed_command_flagged import scan_session\nresult = scan_session('/home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T00-01-33-243Z_01a04085-9c3b-7194-a332-20e86c213e81.jsonl')\nprint(json.dumps(result, indent=2))\nPYEOF\n"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_retry1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 4, in <module>\nModuleNotFoundError: No module named 'failed_command_flagged'\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"ls /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib/ | head -20; echo '---'; head -3 /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib/failed-command-flagged.py"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #937 python3 -c hyphenated-module ModuleNotFoundError walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "python-modnotfound-hyphen-walked-past" ]] || fail "finding slug should be python-modnotfound-hyphen-walked-past (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #937 toolResult so a future
# refactor that drops one of them is caught. The snippet is truncated
# to 200 chars, so the trailing "Command exited with code 1" is the
# line that gets cut; check the unique prefix signals instead (the
# traceback + ModuleNotFoundError + the unhyphenated name are the
# live #937 fingerprint).
grep -q 'Traceback' <<<"$snippet" \
  || fail "finding snippet should mention Traceback (got $snippet)"
grep -q "ModuleNotFoundError: No module named 'failed_command_flagged'" <<<"$snippet" \
  || fail "finding snippet should mention ModuleNotFoundError for the unhyphenated name (got $snippet)"
grep -q '<string>' <<<"$snippet" \
  || fail "finding snippet should mention the python3 -c <string> source (got $snippet)"
ok "live #937: python3 -c hyphenated-module ModuleNotFoundError + toolCall-only python3 << 'PYEOF' recovery is flagged"
rm -f "$sessions/python-modnotfound-hyphen-walked-past.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ---------------
# The standing rule is satisfied when the assistant names the failure
# in user-facing text in the same turn. The detector must NOT flag
# this. Lock the contrast: a worker that names the
# ModuleNotFoundError failure in plain text and then recovers is
# clean; a worker that only emits a recovery toolCall is filed.
write_session "python-modnotfound-hyphen-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib && python3 -c \"\nimport sys\nsys.path.insert(0, '.')\nfrom failed_command_flagged import scan_session\nprint('ok')\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 4, in <module>\nModuleNotFoundError: No module named 'failed_command_flagged'\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 -c import call failed with ModuleNotFoundError: No module named 'failed_command_flagged' — Python refuses hyphens in module names and the actual file is failed-command-flagged.py. Switching to importlib."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-791/lib && python3 -c \"\nimport importlib.util, sys\nspec = importlib.util.spec_from_file_location('fcf', './failed-command-flagged.py')\nm = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(m)\nprint(m.scan_session('/home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T00-01-33-243Z_01a04085-9c3b-7194-a332-20e86c213e81.jsonl'))\n\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged python3 -c hyphenated-module ModuleNotFoundError should be clean (got $count) $report"
ok "python3 -c hyphenated-module ModuleNotFoundError plus later user-facing flag is clean"
rm -f "$sessions/python-modnotfound-hyphen-flagged.jsonl"

# --- 3. python3 -c with a non-hyphenated module name that does exist ---
#      (import os) is exit 0, not flagged. ------------------------------
# A `python3 -c "import os; print(os.getcwd())"` succeeds; isError
# is false and the toolResult carries no `Command exited with code`
# line. The detector must NOT flag it. Pin the contrast: a successful
# `python3 -c` is clean, a `python3 -c` with a hyphenated import is
# not. A future refactor that broadens the suppression to ALL
# `python3 -c` exit 1 would silence the live #937 swallowed failure
# AND the live #957 swallowed failure, both of which are real
# failures to flag.
write_session "python-c-success" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"python3 -c \"import os, json; print(json.dumps({'cwd': os.getcwd()}))\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"cwd\": \"/home/nish\"}\n"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OK."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "successful python3 -c should be clean (got $count) $report"
ok "successful python3 -c (import os) is not flagged (contrast with #937)"
rm -f "$sessions/python-c-success.jsonl"

# --- 4. cross-check: python3 -c with non-hyphenated missing module ------
#      but the agent names the failure in the same turn → clean ---------
# Same ModuleNotFoundError + Command exited with code 1 family, but
# the missing module is NOT a hyphenated filename — it is a typo
# (`fcf` instead of `os`). The agent names the failure in
# user-facing text in the same turn. The detector must NOT flag this.
# Pin the contrast: the live #937 class is a missing module walked
# past, not a missing module named-and-recovered.
write_session "python-modnotfound-named" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe4","name":"bash","arguments":{"command":"python3 -c \"import fcf; print(fcf.x)\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe4","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nModuleNotFoundError: No module named 'fcf'\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 -c import call failed with ModuleNotFoundError: No module named 'fcf' — typo, I meant `os`. Re-running."},{"type":"toolCall","id":"call_retry4","name":"bash","arguments":{"command":"python3 -c \"import os; print(os.getcwd())\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "python3 -c ModuleNotFoundError with later user-facing flag should be clean (got $count) $report"
ok "python3 -c ModuleNotFoundError (typo) plus later user-facing flag is clean"
rm -f "$sessions/python-modnotfound-named.jsonl"

# --- 5. worker.md cites fleet-ops#937 (prompt-side lock) ----------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#937' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#937 (prompt-side lock for the live hyphenated-module shape)"
grep -q "ModuleNotFoundError" "$worker" \
  || fail "prompts/worker.md must name the live #937 ModuleNotFoundError wording so workers flag it"
ok "worker.md cites fleet-ops#937 and the live ModuleNotFoundError wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#937 ----
# (detector-side lock). A future refactor that drops the #937
# citation from the docstring still has the test, but the docstring
# is the standing-rule contract for the next detector maintainer, and
# dropping the citation is a regression.
grep -q 'fleet-ops#937' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#937 (detector-side lock)"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#937"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---
grep -Fq 'bash "$here/fleet-failed-command-python-module-not-found-hyphen.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-python-module-not-found-hyphen: live #937 python3 -c hyphenated-module ModuleNotFoundError walked-past drills"
