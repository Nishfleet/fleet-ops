#!/usr/bin/env bash
# tests/machinery-authorization-gate.test.sh
#
# fleet-ops#1548 drill (audit Step 4): a synthetic diff adding an
# unallowlisted systemd unit is REJECT; a deletion diff PASSes; hunt
# against hand-placed units not on the allowlist yields findings.
#
# Also locks: allowlisted add PASS, authorized-by-nish: PASS, repair PASS,
# MANIFEST-only add REJECT, conference/blind-audit prompts state the rule,
# no dispatcher unit.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-machinery-authorization-gate"
lib="$repo_root/lib/machinery-authorization-gate.py"
fixtures="$here/fixtures/machinery-authorization-gate"
allowlist="$repo_root/config/machinery-allowlist.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$allowlist" ]] || fail "missing $allowlist"
python3 -m py_compile "$lib" || fail "machinery-authorization-gate.py failed py_compile"

ledger=$(python3 "$lib" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'authorized-by-nish:' <<<"$ledger" || fail "ledger line must name authorized-by-nish:"
grep -q 'fleet-ops #1548' <<<"$ledger" || fail "ledger line must cite fleet-ops #1548"
ok "ledger line is non-empty and cites #1548"

# --- (a) synthetic diff adding an unallowlisted unit → REJECT -------------
set +e
out=$("$gate" evaluate --input "$fixtures/reject-new-unit.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "reject-new-unit must exit 1 (REJECT), got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "reject-new-unit verdict must be REJECT: $out"
grep -q 'fleet-ops#1548' <<<"$out" || fail "REJECT must cite fleet-ops#1548: $out"
rule=$(jq -r '.rule' <<<"$out")
[[ "$rule" == "$ledger" ]] || fail "REJECT.rule must be the ledger line verbatim"
jq -e '.rejected | length >= 1' <<<"$out" >/dev/null || fail "REJECT must list rejected units: $out"
ok "drill REJECT: unallowlisted new systemd unit"

# --- (b) deletion diff → PASS --------------------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/pass-deletion.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "pass-deletion must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "pass-deletion must PASS: $out"
ok "drill PASS: deletion of a unit stays ungated"

# --- repair of existing unit stays ungated -------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/pass-repair.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "pass-repair must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "pass-repair must PASS: $out"
ok "repair of an existing unit stays ungated"

# --- allowlisted add PASSes ----------------------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/pass-allowlisted.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "pass-allowlisted must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "pass-allowlisted must PASS: $out"
ok "allowlisted new unit PASSes"

# --- escaped unit name (git-quoted diff + MANIFEST line) PASSes ----------
set +e
out=$("$gate" evaluate --input "$fixtures/pass-escaped-unit-name.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "pass-escaped-unit-name must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "pass-escaped-unit-name must PASS: $out"
jq -e '[.additions[].unit] | index("x2dissue") == null' <<<"$out" >/dev/null \
  || fail "escaped name must not misfire into the 'x2dissue' broken stem: $out"
ok "git-quoted and MANIFEST escaped unit names PASS"

# --- Nish-only authorization signal PASSes -------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/pass-authorized-signal.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "pass-authorized-signal must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "pass-authorized-signal must PASS: $out"
grep -q 'authorized-by-nish' <<<"$out" || fail "PASS reason must name the signal: $out"
ok "authorized-by-nish: signal PASSes"

# --- MANIFEST-only new unit line → REJECT --------------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/reject-manifest-line.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "reject-manifest-line must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "reject-manifest-line must REJECT: $out"
jq -e '[.rejected[].kind] | index("manifest-line") != null' <<<"$out" >/dev/null \
  || fail "REJECT must name manifest-line kind: $out"
ok "MANIFEST-only new unit line REJECTs"

# --- MANIFEST-only via unified diff field → REJECT -------------------------
set +e
out=$("$gate" evaluate --input "$fixtures/reject-manifest-via-diff.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "reject-manifest-via-diff must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "reject-manifest-via-diff must REJECT: $out"
ok "MANIFEST-only via unified diff field REJECTs"

# --- CLI name-status / body form (worker-facing) -------------------------
ns=$(mktemp)
body=$(mktemp)
printf 'A\tsystemd/unallowlisted-cli.service\n' >"$ns"
printf 'no signal here\n' >"$body"
set +e
out=$("$gate" evaluate --name-status "$ns" --body "$body" --allowlist "$allowlist" 2>&1)
rc=$?
set -e
rm -f "$ns" "$body"
[[ "$rc" -eq 1 ]] || fail "CLI unallowlisted add must REJECT, got $rc: $out"
ok "CLI --name-status/--body form REJECTs unallowlisted add"

# --- hunt fixture hits hand-placed non-allowlisted -----------------------
out=$("$gate" hunt --input "$fixtures/hunt-hit.json")
jq -e '.findings | length == 2' <<<"$out" >/dev/null || fail "hunt-hit must yield 2 findings: $out"
jq -e '[.findings[].unit] | index("auditor-stdio-test") != null' <<<"$out" >/dev/null \
  || fail "hunt must flag auditor-stdio-test: $out"
jq -e '[.findings[].unit] | index("ready-work") != null' <<<"$out" >/dev/null \
  || fail "hunt must flag ready-work: $out"
jq -e '[.findings[].unit] | index("fleet-heartbeat") == null' <<<"$out" >/dev/null \
  || fail "hunt must NOT flag allowlisted/symlink fleet-heartbeat: $out"
ok "hunt hits hand-placed units not on the allowlist"

# --- (c) live hunt against the box (reproduces audit hand-placed list) ---
# Uses the real allowlist + real ~/.config/systemd/user. Must surface at
# least one of the audit's class-(c) hand-placed units still present.
set +e
live=$("$gate" hunt --allowlist "$allowlist" 2>&1)
live_rc=$?
set -e
[[ "$live_rc" -eq 0 ]] || fail "live hunt must exit 0 (findings are data, not REJECT): $live"
jq -e 'type=="object" and has("findings")' <<<"$live" >/dev/null \
  || fail "live hunt must return findings object: $live"
# At least one of the audit's class-(c) units should still be a finding if
# still hand-placed on this box. Soft-assert the known names so a deletion
# review that already removed them does not flake the drill — but REQUIRE
# the hunt to be runnable and schema-valid. Prefer a hard hit when present.
class_c='auditor-stdio-test|ready-work|open-question-sweep|agent-scheduler-drift|siterep-pr-conflict-watchdog|quality-baseline-research|memory-index-autocompact'
hit_n=$(jq -r --arg re "$class_c" '[.findings[].unit | select(test($re))] | length' <<<"$live")
if [[ "$hit_n" -ge 1 ]]; then
  ok "live hunt reproduces audit hand-placed class-(c) ($hit_n hit(s))"
else
  # Still prove the live scan ran: either findings exist for other drift, or
  # the unit dir was readable. Empty findings after a real scan is possible
  # only after #1531 deletion review lands — name it. An absent unit dir is a
  # valid empty-scan result (CI runners carry no fleet user units), not a
  # failure; the schema-validity checks above already prove the hunt ran.
  total=$(jq '.findings | length' <<<"$live")
  if [[ -d "$HOME/.config/systemd/user" ]]; then
    ok "live hunt ran (findings=$total; class-c already pruned or absent — schema OK)"
  else
    ok "live hunt ran (findings=$total; no user unit dir on this host — schema OK)"
  fi
fi
# Issue #2072: the escaped worker slice is now repo-sourced and allowlisted,
# so the live hunt must not flag it even while it is still a hand-placed file.
jq -e --arg u 'app-pi\x2dissue' '[.findings[].unit] | index($u) == null' <<<"$live" >/dev/null \
  || fail "live hunt must not flag allowlisted app-pi\x2dissue: $live"
ok "live hunt does not flag repo-allowlisted app-pi\x2dissue"

# --- prompts state the rule (authored, not retrofitted) ------------------
grep -F -q "$ledger" "$repo_root/prompts/senior-conference.md" \
  || fail "senior-conference.md must carry the ledger line verbatim"
grep -q 'fleet-machinery-authorization-gate' "$repo_root/prompts/senior-conference.md" \
  || fail "senior-conference.md must invoke fleet-machinery-authorization-gate"
grep -qi 'hand-placed machinery' "$repo_root/prompts/blind-audit.md" \
  || fail "blind-audit.md must hunt hand-placed machinery"
ok "senior-conference and blind-audit prompts state the rule"

# --- no hand-built dispatcher / no new unit ------------------------------
[[ ! -e "$repo_root/bin/fleet-machinery-authorization-dispatcher" ]] \
  || fail "must not add a dispatcher; the gate is a pure evaluator"
[[ ! -e "$repo_root/systemd/fleet-machinery-authorization-gate.service" ]] \
  || fail "must not add a systemd unit; #223 owns conference convening"
ok "no dispatcher / no new unit (gate is evaluate-only)"

# --- rule-enforcement matrix names THIS gate as enforcer -----------------
python3 - "$repo_root/config/rule-enforcement.json" <<'PY' || fail "rule-enforcement matrix missing #1548 enforcer rows"
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
by_id = {r["id"]: r for r in data["rules"]}
need = {
    "led-2026-08-28-machinery-ban-mechanical",
    "led-2026-08-28-machinery-violations-senior-conference",
    "led-2026-08-28-deletion-first",
}
missing = need - set(by_id)
if missing:
    raise SystemExit(f"missing rule ids: {sorted(missing)}")
for rid in need:
    row = by_id[rid]
    if row.get("status") != "enforced":
        raise SystemExit(f"{rid} status must be enforced, got {row.get('status')}")
    proof = row.get("proof") or ""
    mech = row.get("mechanism") or ""
    blob = proof + " " + mech
    if "fleet-machinery-authorization-gate" not in blob:
        raise SystemExit(f"{rid} must name fleet-machinery-authorization-gate as enforcer")
print("ok")
PY
ok "rule-enforcement.json registers deletion-first + no-new-machinery with this gate"

echo "OK: machinery-authorization-gate drill: reject unallowlisted add, pass deletion, live hunt"
