#!/usr/bin/env bash
# tests/same-repo-closes-gate.test.sh
#
# fleet-ops#695 drill: a same-repo PR that uses the cross-repo short
# form `Closes fleet-ops#N` does not auto-close the issue. The same
# rule rejects a body that says `Closes #N` (line-anchored, the form
# GitHub parses) but whose `closingIssuesReferences` from the live
# GraphQL query is empty. The cross-check against
# `closingIssuesReferences` permits prose mentions like
# "Close fleet-ops#480 ..." when the close already fired via a sibling
# `Closes #480` line.
#
# Also locks: ledger line is non-empty, the cross-repo short form is
# allowed, fully-qualified same-repo is allowed, empty body / no closes
# is allowed, no dispatcher / no new unit (gate is evaluate-only).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-same-repo-closes-gate"
lib="$repo_root/lib/same-repo-closes-gate.py"
fixtures="$here/fixtures/same-repo-closes-gate"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "same-repo-closes-gate.py failed py_compile"

# --- ledger line ----------------------------------------------------------
ledger=$(python3 "$lib" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'fleet-ops #695' <<<"$ledger" || fail "ledger line must cite fleet-ops #695"
grep -q 'Closes #N' <<<"$ledger" || fail "ledger line must name the correct form"
grep -q 'PR #591' <<<"$ledger" || fail "ledger line must cite the origin PR #591"
ok "ledger line is non-empty and cites the rule"

# --- drill: REJECT the same-repo short-owner form (PR #591) ---------------
set +e
out=$("$gate" evaluate --input "$fixtures/same-repo-short-owner.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "same-repo-short-owner must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "same-repo-short-owner must REJECT: $out"
grep -q 'fleet-ops#695' <<<"$out" || fail "REJECT must cite fleet-ops#695: $out"
rule=$(jq -r '.rule' <<<"$out")
[[ "$rule" == "$ledger" ]] || fail "REJECT.rule must be the ledger line verbatim"
jq -e '.bad_references | length == 2' <<<"$out" >/dev/null \
  || fail "same-repo-short-owner must yield 2 bad references: $out"
jq -e '.bad_references[0].match | test("Closes fleet-ops#567")' <<<"$out" >/dev/null \
  || fail "bad_references[0] must name Closes fleet-ops#567: $out"
ok "drill REJECT: same-repo short-owner 'Closes fleet-ops#N' (PR #591)"

# --- drill: REJECT the mid-line short-owner form (PR #780) ---------------
set +e
out=$("$gate" evaluate --input "$fixtures/mid-line-short-owner.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "mid-line-short-owner must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "mid-line-short-owner must REJECT: $out"
jq -e '.bad_references | length == 1' <<<"$out" >/dev/null \
  || fail "mid-line-short-owner must yield 1 bad reference: $out"
ok "drill REJECT: mid-line short-owner ('Closes the loop. Closes fleet-ops#768.', PR #780)"

# --- drill: REJECT when body says `Closes #N` but platform parsed nothing --
set +e
out=$("$gate" evaluate --input "$fixtures/silent-bare-close-missing.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "silent-bare-close-missing must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "must REJECT: $out"
jq -e '.missing_closes | length == 1' <<<"$out" >/dev/null \
  || fail "must yield 1 missing_closes entry: $out"
ok "drill REJECT: body says 'Closes #567' but closingIssuesReferences=[]"

# --- drill: PASS the same-repo bare form (the correct syntax) -------------
set +e
out=$("$gate" evaluate --input "$fixtures/same-repo-bare-with-closing.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "same-repo-bare-with-closing must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: same-repo 'Closes #N' with closingIssuesReferences populated"

# --- drill: PASS the same-repo fully-qualified form -----------------------
set +e
out=$("$gate" evaluate --input "$fixtures/same-repo-fully-qualified.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "same-repo-fully-qualified must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: same-repo 'Closes Nishfleet/fleet-ops#N' (fully-qualified)"

# --- drill: PASS a genuine cross-repo short-owner form --------------------
set +e
out=$("$gate" evaluate --input "$fixtures/cross-repo-short-owner.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "cross-repo-short-owner must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: cross-repo short-owner (siterep-public PR closes Nishfleet/fleet-ops#N)"

# --- drill: PASS an empty body / no closes --------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/no-closing-references.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no-closing-references must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: empty body / no closing references (out of scope)"

# --- drill: PASS a prose mention when the close fired (PR #594) -----------
set +e
out=$("$gate" evaluate --input "$fixtures/prose-mention-with-closing.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "prose-mention-with-closing must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: prose 'Close fleet-ops#480' is benign when 480 is in closingIssuesReferences"

# --- drill: PASS backticked prose mention (no platform parse needed) ----
set +e
out=$("$gate" evaluate --input "$fixtures/prose-mention.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "prose-mention must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "must PASS: $out"
ok "PASS: prose mention inside backticks is excluded (negative lookbehind wins)"

# --- drill: REJECT prose mention without a real closing reference ---------
# (The body has `Close fleet-ops#480` in prose but no `Closes #480` line;
# the platform did not parse a close. The user intended to close 480 but
# used the wrong syntax; the gate forces them to add the right line.)
set +e
out=$("$gate" evaluate --input "$fixtures/prose-mention-without-closing.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "prose-mention-without-closing must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "must REJECT: $out"
ok "drill REJECT: prose mention without a real closing reference (worker must add 'Closes #N')"

# --- senior conference references the gate verbatim -----------------------
grep -F -q 'fleet-same-repo-closes-gate evaluate' "$repo_root/prompts/senior-conference.md" \
  || fail "senior-conference.md must reference the gate"
grep -F -q "$ledger" "$repo_root/prompts/senior-conference.md" \
  || fail "senior-conference.md must carry the ledger line verbatim"
ok "senior-conference.md carries the gate and the ledger line"

# --- no hand-built dispatcher / no new unit (gate is evaluate-only) -------
[[ ! -e "$repo_root/bin/fleet-same-repo-closes-dispatcher" ]] \
  || fail "must not add a dispatcher; the gate is a pure evaluator"
[[ ! -e "$repo_root/systemd/fleet-same-repo-closes-gate.service" ]] \
  || fail "must not add a systemd unit; #223 owns conference convening"
ok "no dispatcher / no new unit (gate is evaluate-only)"

echo "OK: same-repo-closes-gate drill: REJECT same-repo short-owner and silent-bare-missing, PASS bare/fully-qualified/cross-repo/prose-when-closed"
