#!/usr/bin/env bash
# tests/attest-identity-gate.test.sh
#
# fleet-ops#413 drill: a fixture where the same identity implements and
# attests is REJECT. Disjoint identities PASS. A worker bot attestor is
# always REJECT. Owner self-attest of a human-only PR PASSes (the human
# token impersonation hole is closed by the scream/canary, not this gate).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/attest-identity-gate"
lib="$repo_root/lib/attest-identity-gate.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$gate" ]] || fail "not executable: $gate"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "attest-identity-gate.py failed py_compile"

run() {
  local file="$1"
  "$gate" --input "$file"
}

scratch="$(mktemp -d -t attest-id.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- drill: same worker identity implements and attests → REJECT ------------
cat >"$scratch/same-bot.json" <<'JSON'
{"implementers": ["nishfleet-worker[bot]"], "attestors": ["nishfleet-worker[bot]"]}
JSON
set +e
out=$(run "$scratch/same-bot.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "same-bot fixture must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "same-bot must REJECT: $out"
grep -q 'cannot attest' <<<"$out" || fail "same-bot reason must name cannot attest: $out"
ok "drill REJECT: same worker identity implements and attests"

# --- drill: strict same-human identity → REJECT -----------------------------
cat >"$scratch/same-human-strict.json" <<'JSON'
{"implementers": ["nish3451"], "attestors": ["nish3451"], "strict": true}
JSON
set +e
out=$(run "$scratch/same-human-strict.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "strict same-human must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "strict same-human must REJECT: $out"
grep -q 'same identity implemented and attested' <<<"$out" \
  || fail "strict same-human reason: $out"
ok "drill REJECT: strict same-human implement+attest"

# --- PASS: bot implements, human attests ------------------------------------
cat >"$scratch/split.json" <<'JSON'
{"implementers": ["nishfleet-worker[bot]"], "attestors": ["nish3451"]}
JSON
set +e
out=$(run "$scratch/split.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "split identities must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "split must PASS: $out"
ok "PASS: worker implements, human attests"

# --- REJECT: human implements, bot attests (vice versa) ---------------------
cat >"$scratch/vice-versa.json" <<'JSON'
{"implementers": ["nish3451"], "attestors": ["nishfleet-worker[bot]"]}
JSON
set +e
out=$(run "$scratch/vice-versa.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "vice-versa must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "vice-versa must REJECT: $out"
ok "REJECT: human implements, worker attests"

# --- PASS: owner self-attest of a human-only PR -----------------------------
cat >"$scratch/owner.json" <<'JSON'
{"implementers": ["nish3451"], "attestors": ["nish3451"]}
JSON
set +e
out=$(run "$scratch/owner.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "owner self-attest must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "owner self-attest must PASS: $out"
grep -q 'owner self-attest' <<<"$out" || fail "owner reason: $out"
ok "PASS: owner self-attest of a human-only PR"

# --- PASS: no attestors (other gates own missing-attestation) ---------------
cat >"$scratch/none.json" <<'JSON'
{"implementers": ["nishfleet-worker[bot]"], "attestors": []}
JSON
set +e
out=$(run "$scratch/none.json" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no attestors must exit 0, got $rc: $out"
ok "PASS: no attestors to check"

# --- lock: worker prompt forbids self-attestation ---------------------------
worker="$repo_root/prompts/worker.md"
grep -q 'NEVER post' "$worker" || grep -q 'must NEVER' "$worker" \
  || fail "worker.md must forbid workers from posting attestation comments"
ok "worker.md forbids self-attestation"

echo "OK: attest-identity-gate drill (fleet-ops#413)"
