#!/usr/bin/env bash
# tests/fleet-failed-command-pem-deserialize.test.sh
#
# fleet-ops#1174: a `python3 - <<'PY'` stdin script that calls
# cryptography `serialization.load_pem_private_key` on the raw quoted
# value of `NISHFLEET_WORKER_PRIVATE_KEY` from the worker env file
# crashes with:
#   File "<stdin>", line 28, in <module>
#   .../serialization/base.py ... load_pem_private_key
#   ValueError: Could not deserialize key data
#   Command exited with code 1
# The env value is an env-via-heredoc (`cat <<'NISHFLEET_PEM_EOF'`),
# not the PEM itself. The assistant walked past with cause-explaining
# prose ("The PEM in the env may be malformed. Let me check:" then
# "the private key is stored inside a `cat <<'NISHFLEET_PEM_EOF'`
# heredoc") and a successful re-extract that minted a JWT. Cause-prose
# names the CAUSE, not the FAILURE. Never named the command failure.
#
# The detector already flags this class via the generic
# `isError or code != 0` path. No `lib/failed-command-flagged.py` logic
# change is needed — a suppression for "cryptography / PEM / JWT mint"
# or "successful later extract" would silence a real signal. The
# tempting future exemptions this file forbids:
#   - treating `load_pem_private_key` / `Could not deserialize key data`
#     as a benign crypto probe
#   - treating File `"<stdin>"` Python crashes as distinct from
#     File `"<string>"` (#957) and therefore suppressible
#   - letting cause-prose ("malformed", "env-via-heredoc",
#     `NISHFLEET_PEM_EOF`) discharge FLAG_RE
#   - letting a later successful JWT mint mask the earlier failure
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T13-43-46-261Z_01a04376-5f55-7726-9184-4e31bb7e54f2.jsonl
# Vacation-audit worker (check 10: worker-identity git push) ran:
#   python3 - <<'PY' 2>&1
#   ... envfile = "/home/nish/.config/fleet-worker/nishfleet-worker.env"
#   ... pem = env.get("NISHFLEET_WORKER_PRIVATE_KEY","")
#   ... key = serialization.load_pem_private_key(pem.encode(), password=None)
# Detector snippet (first 200 chars, newlines collapsed):
#   Traceback (most recent call last):   File "<stdin>", line 28, in
#   <module>   File ".../serialization/base.py", line 25, in
#   load_pem_private_key
#
# Distinct from:
#   - #957 / #966 / #1003: python3 -c / heredoc KeyError / NameError
#     (same class, different wording — no cryptography, no PEM)
#   - #937: ModuleNotFoundError on a hyphenated import
# The fixture carries no private-key material — only the traceback
# shape and the command text that names load_pem_private_key.
#
# Scenarios:
#   1. live #1174 shape: python3 stdin load_pem_private_key + cause-prose
#      recovery + successful re-extract -> finding. Snippet must carry
#      Traceback, File "<stdin>", and load_pem_private_key (the live
#      200-char window).
#   2. same shape plus a later thinking-only recovery -> still a finding.
#   3. same shape plus later unrelated user-facing prose ("Worker
#      identity confirmed live") that does NOT name the failure ->
#      still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. compact traceback that keeps `Could not deserialize key data`
#      and `Command exited with code 1` inside the 200-char snippet
#      -> finding (pins the ValueError wording the live 200-char
#      cutoff drops).
#   6. lib/failed-command-flagged.py cites fleet-ops#1174 and the live wording
#      (detector-side lock: case list moved to lib, fleet-ops#3246).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1174
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-pem-deserialize.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T14:11:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T16:00:00Z"
}

# --- 1. live #1174 shape: load_pem walked past with cause-prose recovery --
# Replay slug 01a04376-5f55: python3 stdin JWT mint hits
# load_pem_private_key ValueError, next turns explain the env-via-heredoc
# and re-extract successfully. Never names the failure.
# Fixture carries no private-key material.
write_session "pem-deserialize-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have a clear picture of the 0509 deploy chain. Let me also check the merge process for the worker-identity git push from Check 10:"},{"type":"toolCall","id":"call_jwt1","name":"bash","arguments":{"command":"python3 - <<'PY' 2>&1\nimport json, time\nenvfile = \"/home/nish/.config/fleet-worker/nishfleet-worker.env\"\nenv = {}\nfor line in open(envfile):\n    if line.startswith(\"#\") or \"=\" not in line: continue\n    k,v = line.strip().split(\"=\",1)\n    env[k]=v\napp_id = env.get(\"NISHFLEET_WORKER_APP_ID\",\"\")\npem = env.get(\"NISHFLEET_WORKER_PRIVATE_KEY\",\"\")\nfrom cryptography.hazmat.primitives import hashes, serialization\nfrom cryptography.hazmat.primitives.asymmetric import padding\nkey = serialization.load_pem_private_key(pem.encode(), password=None)\nprint(\"JWT minted\")\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_jwt1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 28, in <module>\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/primitives/serialization/base.py\", line 25, in load_pem_private_key\n    return ossl.load_pem_private_key(\n           ^^^^^^^^^^^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/backends/openssl/backend.py\", line 747, in load_pem_private_key\n    return self._load_key(\n           ^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/backends/openssl/backend.py\", line 929, in _load_key\n    self._handle_key_loading_error()\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/backends/openssl/backend.py\", line 984, in _handle_key_loading_error\n    raise ValueError(\nValueError: ('Could not deserialize key data. The data may be in an incorrect format, it may be encrypted with an unsupported algorithm, or it may be an unsupported key type (e.g. EC curves with explicit parameters).', [<OpenSSLError(code=503841036, lib=60, reason=524556, reason_text=unsupported)>])\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The PEM in the env may be malformed. Let me check:"},{"type":"toolCall","id":"call_inspect","name":"bash","arguments":{"command":"python3 - <<'PY'\nprint(\"begins_with_pem_header=\", False)\nprint(\"escaped_newlines_in_env=30\")\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_inspect","toolName":"bash","isError":false,"content":[{"type":"text","text":"begins_with_pem_header= False\nescaped_newlines_in_env=30"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ah — the private key is stored inside a `cat <<'NISHFLEET_PEM_EOF'` heredoc inside a quoted value. This is the env-via-heredoc pattern used so source can extract it. Let me extract it properly:"},{"type":"toolCall","id":"call_extract","name":"bash","arguments":{"command":"python3 - <<'PY'\nprint(\"JWT minted: app_id=4728578 exp_in_540s\")\nprint(\"installations=1 org=Nishfleet repo_selection=all\")\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_extract","toolName":"bash","isError":false,"content":[{"type":"text","text":"JWT minted: app_id=4728578 exp_in_540s\ninstallations=1 org=Nishfleet repo_selection=all"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1174 load_pem_private_key walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Traceback' <<<"$snippet" \
  || fail "finding snippet should mention Traceback (got $snippet)"
grep -q '<stdin>' <<<"$snippet" \
  || fail "finding snippet should mention File <stdin> (got $snippet)"
grep -q 'load_pem_private_key' <<<"$snippet" \
  || fail "finding snippet should mention load_pem_private_key (got $snippet)"
ok "live #1174: python3 stdin load_pem_private_key with cause-prose recovery is flagged"
rm -f "$sessions/pem-deserialize-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "pem-deserialize-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_jwt2","name":"bash","arguments":{"command":"python3 - <<'PY' 2>&1\nfrom cryptography.hazmat.primitives import serialization\nkey = serialization.load_pem_private_key(pem.encode(), password=None)\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_jwt2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 28, in <module>\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/primitives/serialization/base.py\", line 25, in load_pem_private_key\nValueError: Could not deserialize key data\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The PEM in the env is a heredoc wrapper, not the key. I will extract it properly."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"python3 - <<'PY'\nprint(\"extracted\")\nPY"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "load_pem_private_key with thinking-only recovery should be a finding (got $count) $report"
ok "live #1174: load_pem_private_key with later thinking-only recovery is still flagged"
rm -f "$sessions/pem-deserialize-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "pem-deserialize-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_jwt3","name":"bash","arguments":{"command":"python3 - <<'PY' 2>&1\nfrom cryptography.hazmat.primitives import serialization\nkey = serialization.load_pem_private_key(pem.encode(), password=None)\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_jwt3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 28, in <module>\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/primitives/serialization/base.py\", line 25, in load_pem_private_key\nValueError: Could not deserialize key data\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Worker identity confirmed live: App 4728578, installation under Nishfleet org, repo_selection=all. Now let me do an actual git push test on a scratch repo."},{"type":"toolCall","id":"call_next3","name":"bash","arguments":{"command":"gh api /app --jq .id"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "load_pem_private_key followed by unrelated prose should be a finding (got $count) $report"
ok "live #1174: load_pem_private_key with later 'Worker identity confirmed live' prose is still flagged"
rm -f "$sessions/pem-deserialize-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "pem-deserialize-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_jwt4","name":"bash","arguments":{"command":"python3 - <<'PY' 2>&1\nfrom cryptography.hazmat.primitives import serialization\nkey = serialization.load_pem_private_key(pem.encode(), password=None)\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_jwt4","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 28, in <module>\n  File \"/usr/lib/python3/dist-packages/cryptography/hazmat/primitives/serialization/base.py\", line 25, in load_pem_private_key\nValueError: Could not deserialize key data\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 stdin JWT mint failed with ValueError: Could not deserialize key data (load_pem_private_key on the raw env value). fixing."},{"type":"toolCall","id":"call_retry4","name":"bash","arguments":{"command":"python3 - <<'PY'\nprint(\"extracted from heredoc\")\nPY"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "load_pem_private_key with later user-facing flag should be clean (got $count) $report"
ok "load_pem_private_key plus later user-facing flag is clean"
rm -f "$sessions/pem-deserialize-flagged.jsonl"

# --- 5. compact traceback keeps deserialize wording inside 200 chars -------
# The live #1174 snippet is cut at load_pem_private_key. Pin the
# ValueError wording so a future snippet_for change that drops
# "Could not deserialize key data" still fails this drill.
write_session "pem-deserialize-compact" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_jwt5","name":"bash","arguments":{"command":"python3 - <<'PY' 2>&1\nfrom cryptography.hazmat.primitives import serialization\nkey = serialization.load_pem_private_key(pem.encode(), password=None)\nPY"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_jwt5","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 28, in <module>\nValueError: Could not deserialize key data\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry5","name":"bash","arguments":{"command":"python3 - <<'PY'\nprint(\"retry\")\nPY"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "compact load_pem deserialize traceback should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Could not deserialize key data' <<<"$snippet" \
  || fail "compact snippet should mention Could not deserialize key data (got $snippet)"
grep -q 'Command exited with code 1' <<<"$snippet" \
  || fail "compact snippet should mention Command exited with code 1 (got $snippet)"
ok "compact traceback keeps Could not deserialize key data inside the snippet"
rm -f "$sessions/pem-deserialize-compact.jsonl"

# --- 6. prompts/lib/failed-command-flagged.py cites fleet-ops#1174 (detector-side lock: case list moved to lib, fleet-ops#3246) ----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1174' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1174 (detector-side lock: case list moved to lib, fleet-ops#3246)"
grep -q 'load_pem_private_key' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live load_pem_private_key wording"
grep -q 'Could not deserialize key data' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live Could not deserialize key data wording"
grep -q 'NISHFLEET_PEM_EOF' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live NISHFLEET_PEM_EOF env-via-heredoc cause-prose"
ok "lib/failed-command-flagged.py cites fleet-ops#1174 and the live load_pem / deserialize / heredoc wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1174 ------
grep -q 'fleet-ops#1174' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1174 (detector-side lock)"
grep -q 'load_pem_private_key' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live load_pem_private_key wording"
grep -q 'Could not deserialize key data' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live Could not deserialize key data wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1174 and the load_pem shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ------
grep -Fq 'bash "$here/fleet-failed-command-pem-deserialize.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-pem-deserialize: live #1174 load_pem_private_key drills"
