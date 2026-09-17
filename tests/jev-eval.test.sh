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
echo "jev-eval tests: green"

# Exercise the worker's shared-helper integration in the existing CI entry.
PI_SEAT_LIB_CHECK_TRANSPORT=0 bash "$here/tests/pi-issue-run-app-identity.test.sh"

# Offline death-report inventory coverage, using this existing CI entry (#7444).
python3 "$here/tests/seat-reliability.test.py" || fail "seat reliability inventory"
