#!/usr/bin/env bash
# tests/senior-conference-gate.test.sh
#
# fleet-ops#3756 drill: a PR that trips the seriousness gate (lines changed
# > 500 OR files touched > 10 OR touches a critical path: deploy, migrations,
# security, branch-protection) is REJECT unless it carries the
# `conference-approved` label. The 0509#1712 incident merged 721 additions
# across 10 files with no conference verdict because the seriousness gate
# was prose-only; this evaluator is the deterministic core the senior
# conference (automatic criterion) and a CI status check both call.
#
# Also locks: ledger line is non-empty and cites fleet-ops #223, the bypass
# label is `conference-approved`, custom thresholds/globs override the
# defaults, and the gate is evaluate-only (no dispatch, no GitHub writes).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-senior-conference-gate"
lib="$repo_root/lib/senior-conference-gate.py"
fixtures="$here/fixtures/senior-conference-gate"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "senior-conference-gate.py failed py_compile"

# --- ledger line ----------------------------------------------------------
ledger=$(python3 "$lib" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'fleet-ops #223' <<<"$ledger" || fail "ledger line must cite fleet-ops #223"
grep -q 'serious builds get the senior conference' <<<"$ledger" \
  || fail "ledger line must name the rule"
grep -q 'seriousness gate' <<<"$ledger" || fail "ledger line must name the seriousness gate"
ok "ledger line is non-empty and cites the rule"

# --- drill: REJECT large diff, no label (0509#1712 shape) -----------------
set +e
out=$("$gate" evaluate --input "$fixtures/large-diff-no-label.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "large-diff-no-label must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "large-diff-no-label must REJECT: $out"
jq -e '.serious==true' <<<"$out" >/dev/null || fail "must be serious: $out"
jq -e '.label_bypass==false' <<<"$out" >/dev/null || fail "must report no bypass: $out"
jq -e '.lines_changed==731' <<<"$out" >/dev/null || fail "lines_changed must be 731: $out"
jq -e '.reasons[0] | test("lines_changed=731 > 500")' <<<"$out" >/dev/null \
  || fail "must name the lines reason: $out"
rule=$(jq -r '.rule' <<<"$out")
[[ "$rule" == "$ledger" ]] || fail "REJECT.rule must be the ledger line verbatim"
ok "drill REJECT: large diff (731 lines) without conference-approved (0509#1712)"

# --- drill: PASS large diff WITH conference-approved label ----------------
set +e
out=$("$gate" evaluate --input "$fixtures/large-diff-approved.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "large-diff-approved must exit 0 (PASS), got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "large-diff-approved must PASS: $out"
jq -e '.serious==true' <<<"$out" >/dev/null || fail "still serious: $out"
jq -e '.label_bypass==true' <<<"$out" >/dev/null || fail "must report bypass: $out"
ok "drill PASS: large diff WITH conference-approved bypass"

# --- drill: REJECT critical path (migrations), small diff -----------------
set +e
out=$("$gate" evaluate --input "$fixtures/critical-path-migrations-no-label.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "critical-path-migrations must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "critical-path-migrations must REJECT: $out"
jq -e '.critical_path_hits[0].glob=="migrations/**"' <<<"$out" >/dev/null \
  || fail "must hit migrations/** glob: $out"
jq -e '.reasons[0] | test("critical_path")' <<<"$out" >/dev/null \
  || fail "must name critical_path reason: $out"
ok "drill REJECT: critical path (migrations) small diff, no label"

# --- drill: PASS critical path (deploy) WITH conference-approved ----------
set +e
out=$("$gate" evaluate --input "$fixtures/critical-path-deploy-approved.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "critical-path-deploy-approved must exit 0 (PASS), got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "critical-path-deploy-approved must PASS: $out"
jq -e '.critical_path_hits | length == 1' <<<"$out" >/dev/null \
  || fail "must still record the critical hit: $out"
ok "drill PASS: critical path (deploy) WITH conference-approved"

# --- drill: REJECT many files (>10), small line count ---------------------
set +e
out=$("$gate" evaluate --input "$fixtures/many-files-no-label.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "many-files-no-label must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "many-files must REJECT: $out"
jq -e '.reasons[0] | test("files_touched=11 > 10")' <<<"$out" >/dev/null \
  || fail "must name files reason: $out"
ok "drill REJECT: many files (11) without conference-approved"

# --- drill: PASS small diff, no critical path, no label -------------------
set +e
out=$("$gate" evaluate --input "$fixtures/small-diff-pass.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "small-diff-pass must exit 0 (PASS), got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "small-diff must PASS: $out"
jq -e '.serious==false' <<<"$out" >/dev/null || fail "must not be serious: $out"
ok "drill PASS: small diff, no critical path"

# --- drill: REJECT critical path (branch-protection) ---------------------
set +e
out=$("$gate" evaluate --input "$fixtures/critical-path-branch-protection-no-label.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "critical-path-branch-protection must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null \
  || fail "critical-path-branch-protection must REJECT: $out"
jq -e '.critical_path_hits[0].path==".github/scripts/repo-standards-apply.mjs"' <<<"$out" >/dev/null \
  || fail "must hit the branch-protection path: $out"
ok "drill REJECT: critical path (branch-protection) small diff"

# --- drill: custom thresholds/globs override defaults --------------------
set +e
out=$("$gate" evaluate --input "$fixtures/custom-globs-override.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "custom-globs-override must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "custom-globs must REJECT: $out"
jq -e '.thresholds.lines==1000' <<<"$out" >/dev/null || fail "must use custom lines threshold: $out"
jq -e '.thresholds.files==50' <<<"$out" >/dev/null || fail "must use custom files threshold: $out"
jq -e '.critical_path_hits[0].glob=="products/0509/**"' <<<"$out" >/dev/null \
  || fail "must use the custom glob: $out"
ok "drill: custom thresholds (lines=1000, files=50) and globs override defaults"

# --- drill: stdin input works (default --input is stdin) -----------------
set +e
out=$(echo '{"additions":600,"deletions":0,"changedFiles":1,"files":[{"path":"x"}],"labels":[]}' | "$gate" evaluate)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "stdin large diff must REJECT, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "stdin must REJECT: $out"
ok "drill: stdin input (default) works"

# --- drill: labels as bare strings and as {name} objects both work --------
set +e
out=$(echo '{"additions":600,"deletions":0,"changedFiles":1,"files":[{"path":"x"}],"labels":["conference-approved"]}' | "$gate" evaluate)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "bare-string label bypass must PASS, got $rc: $out"
jq -e '.label_bypass==true' <<<"$out" >/dev/null || fail "bare-string label must bypass: $out"
ok "drill: labels as bare strings bypass the same as {name} objects"

# --- the gate is evaluate-only: no dispatch / no GitHub writes -----------
# A grep for gh/dispatch/requests in the lib confirms purity (defensive —
# this catches a future edit that adds a network call to a "pure evaluator").
if grep -E 'subprocess|os\.system|requests|urllib|http\.client|socket' "$lib" | grep -v '^\s*#'; then
  fail "lib must not make network/process calls (pure evaluator): $(grep -nE 'subprocess|os\.system|requests|urllib|http\.client|socket' "$lib" | grep -v "^\s*#")"
fi
ok "gate lib is a pure evaluator (no subprocess/network calls)"

echo "OK: senior-conference-gate.test.sh: all drills passed (fleet-ops#3756)"
