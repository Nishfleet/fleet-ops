#!/usr/bin/env bash
# tests/failure-mechanism-gate.test.sh
#
# fleet-ops#366 drill: a fixture failure-fix PR with no mechanism and no
# declared reason is auto-rejected by the conference gate with the ledger
# line cited; the same PR with a regression test passes.
#
# Also locks: mechanism-impossible: pass, non-failure-fix pass, recurrence
# hunt hit/miss, auditor packet verbatim ledger line, worker/scout/audit
# prompts state the rule, no dispatcher unit.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-failure-mechanism-gate"
lib="$repo_root/lib/failure-mechanism-gate.py"
fixtures="$here/fixtures/failure-mechanism-gate"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "failure-mechanism-gate.py failed py_compile"

ledger=$(python3 "$lib" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'mechanism-impossible:' <<<"$ledger" || fail "ledger line must name mechanism-impossible:"
grep -q 'fleet-ops #366' <<<"$ledger" || fail "ledger line must cite fleet-ops #366"
ok "ledger line is non-empty and cites #366"

# --- drill: reject a failure-fix with no mechanism --------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/no-mechanism.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "no-mechanism fixture must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "no-mechanism verdict must be REJECT: $out"
grep -q 'fleet-ops#366' <<<"$out" || fail "REJECT must cite fleet-ops#366: $out"
rule=$(jq -r '.rule' <<<"$out")
[[ "$rule" == "$ledger" ]] || fail "REJECT.rule must be the ledger line verbatim"
ok "drill REJECT: failure-fix with no mechanism cites the rule"

# --- drill: same PR with a regression test passes ---------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/with-regression.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "with-regression fixture must exit 0, got $rc: $out"
jq -e '.verdict=="PASS" and .mechanism=="regression-test"' <<<"$out" >/dev/null \
  || fail "with-regression must PASS as regression-test: $out"
ok "drill PASS: same PR with a regression test"

# --- mechanism-impossible: is an explicit declared reason -------------------
set +e
out=$("$gate" evaluate --input "$fixtures/with-impossible.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "with-impossible must exit 0, got $rc: $out"
jq -e '.verdict=="PASS" and .mechanism=="mechanism-impossible"' <<<"$out" >/dev/null \
  || fail "with-impossible must PASS as mechanism-impossible: $out"
ok "mechanism-impossible: declaration PASSes the automatic half"

# --- feat PRs are outside the rule -----------------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/not-failure-fix.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "not-failure-fix must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "not-failure-fix must PASS: $out"
ok "non-failure-fix is out of scope (PASS)"

# --- recurrence hunt: same signal key after a closed fix -------------------
out=$("$gate" hunt --input "$fixtures/hunt-hit.json")
jq -e '.findings | length == 1' <<<"$out" >/dev/null || fail "hunt-hit must yield 1 finding: $out"
jq -e '.findings[0].title | test("recurred failure class")' <<<"$out" >/dev/null \
  || fail "hunt-hit title must name recurred failure class: $out"
ok "hunt hits a recurred failure class"

out=$("$gate" hunt --input "$fixtures/hunt-miss.json")
jq -e '.findings | length == 0' <<<"$out" >/dev/null || fail "hunt-miss must yield 0 findings: $out"
ok "hunt stays quiet when the closed issue is not a failure-fix"

# --- auditor packet carries the ledger line verbatim -----------------------
# shellcheck source=/dev/null
source "$repo_root/lib/packet-assembly.sh"
pkt=$(packet_mechanical_fix_rule) || fail "packet_mechanical_fix_rule failed"
grep -F -q "$ledger" <<<"$pkt" || fail "auditor packet missing verbatim ledger line"
ok "packet_mechanical_fix_rule emits the ledger line verbatim"

grep -F -q "$ledger" "$repo_root/prompts/senior-conference.md" \
  || fail "senior-conference.md must carry the ledger line verbatim"
ok "senior-conference.md carries the ledger line verbatim"

# --- worker / scout / blind-audit state the rule so it is authored, not retrofitted
grep -q 'mechanism-impossible:' "$repo_root/prompts/worker.md" \
  || fail "worker.md must tell workers to declare mechanism-impossible:"
grep -q 'fleet-ops#366' "$repo_root/prompts/worker.md" \
  || fail "worker.md must cite fleet-ops#366"
grep -q 'mechanism-impossible:' "$repo_root/prompts/scout.md" \
  || fail "scout.md must require mechanism-impossible: on fix-shaped issues"
grep -q 'Recurred failure classes' "$repo_root/prompts/blind-audit.md" \
  || fail "blind-audit.md must hunt recurred failure classes"
ok "worker, scout, and blind-audit prompts state the rule"

# --- no hand-built conference dispatcher -----------------------------------
[[ ! -e "$repo_root/bin/fleet-failure-mechanism-dispatcher" ]] \
  || fail "must not add a dispatcher; the gate is a pure evaluator"
[[ ! -e "$repo_root/systemd/fleet-failure-mechanism-gate.service" ]] \
  || fail "must not add a systemd unit; #223 owns conference convening"
ok "no dispatcher / no new unit (gate is evaluate-only)"

echo "OK: failure-mechanism-gate drill: reject without mechanism, pass with regression test"
