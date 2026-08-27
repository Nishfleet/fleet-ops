#!/usr/bin/env bash
# tests/credential-expiry-canary.test.sh
#
# fleet-ops#938 (led-2026-08-27-vacation-window-corrected).
#
# Proves the credential-expiry canary enforces the 2026-09-08 window against
# official GitHub surfaces (GET /app + GitHub-Authentication-Token-Expiration),
# not a fictional GET /app/keys:
#   1. GET /app 200 → PASS (App keys do not expire).
#   2. GET /app 401 → REJECT.
#   3. PAT expiring after the window → PASS.
#   4. PAT expiring on the window end → REJECT (inclusive).
#   5. PAT expiring before the window → REJECT.
#   6. PAT with no expiry header → PASS (classic PAT, no expiry).
#   7. Unparseable PAT expiry header → REJECT.
#   8. No App and no PAT → SKIP.
#   9. now past window end → SKIP.
#  10. Source never calls GET /app/keys.
#  11. Heartbeat-tier1 block 31 wiring + require_manifest_helper.
#  12. Matrix row is enforced with mechanism + proof.
#  13. MANIFEST ships the binary + lib.
#  14. Nested from escalation-coverage-canary.test.sh (CI host).
#
# Offline. No GitHub API calls.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/credential-expiry-canary.py"
bin="$repo_root/bin/fleet-credential-expiry-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"
host="$here/escalation-coverage-canary.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

app_ok='{"id":4728578,"name":"nishfleet-worker","created_at":"2026-08-26T16:30:31Z"}'

# --- 1. GET /app 200 → PASS ------------------------------------------------
set +e
out="$("$bin" --app-returns "$app_ok" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "GET /app 200 must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "GET /app 200 → PASS (keys do not expire)"

# --- 2. GET /app 401 → REJECT ----------------------------------------------
set +e
out="$("$bin" --app-returns '{}' --app-status 401 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "GET /app 401 must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "GET /app 401 → REJECT (dead App)"

# --- 3. PAT expiring after window → PASS -----------------------------------
pat_after=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-09-09 00:00:00 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_after" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "PAT after window must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "PAT expiring 2026-09-09 → PASS"

# --- 4. PAT expiring at window end → REJECT (inclusive) --------------------
pat_boundary=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-09-08 23:59:59 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_boundary" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "boundary PAT must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "PAT expiring at window end → REJECT"

# --- 5. PAT expiring before window → REJECT --------------------------------
pat_pre=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-08-30 12:00:00 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_pre" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "pre-window PAT must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "PAT expiring before window → REJECT"

# --- 6. PAT with no expiry header → PASS -----------------------------------
pat_none=$'HTTP/2 200\ncontent-type: application/json\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_none" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no-expiry PAT must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "PAT with no expiry header → PASS"

# --- 7. unparseable PAT expiry → REJECT ------------------------------------
pat_bad=$'HTTP/2 200\ngithub-authentication-token-expiration: not-a-date\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_bad" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "unparseable PAT expiry must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "unparseable PAT expiry header → REJECT"

# --- 8. no App and no PAT → SKIP -------------------------------------------
set +e
out="$("$bin" --from-fixtures /tmp/credential-expiry-empty-fixtures-does-not-exist 2>&1)"
rc=$?
set -e
# missing dir still runs evaluate with app_status=0, pat_raw=None → SKIP
[[ "$rc" -eq 0 ]] || fail "no credentials must exit 0 (SKIP), got $rc: $out"
grep -qi 'SKIP' <<<"$out" || fail "must print SKIP: $out"
ok "no App and no PAT → SKIP"

# --- 9. now past window end → SKIP -----------------------------------------
set +e
out="$("$bin" --app-returns "$app_ok" --now 2026-09-10T00:00:00Z 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "past-window must exit 0 (SKIP), got $rc: $out"
grep -qi 'SKIP' <<<"$out" || fail "must print SKIP: $out"
ok "now past window end → SKIP"

# --- 10. source never calls a private-key list endpoint --------------------
grep -F '"/app/keys"' "$lib" >/dev/null \
    && fail "lib must not call a fictional App private-key list endpoint"
ok "source does not call a fictional App private-key list endpoint"

# --- 11. tier1 block 31 wiring ---------------------------------------------
grep -q 'CRED_EXPIRY_CANARY_BIN' "$tier1" \
    || fail "tier1 must reference CRED_EXPIRY_CANARY_BIN"
grep -q 'cred_expiry_canary_rc' "$tier1" \
    || fail "tier1 must propagate cred_expiry_canary_rc"
grep -q '31. credential expiry canary' "$tier1" \
    || fail "tier1 must name block 31 as credential expiry canary"
grep -q 'require_manifest_helper.*CRED_EXPIRY_CANARY' "$tier1" \
    || fail "tier1 block 31 must call require_manifest_helper"
grep -q 'HELPER-MISSING.*credential expiry' "$tier1" \
    || fail "tier1 block 31 must loud HELPER-MISSING"
ok "tier1 block 31 wires credential-expiry-canary with require_manifest_helper"

# --- 12. matrix row is enforced with mechanism + proof ---------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected" and .status == "enforced")' \
    "$matrix" >/dev/null \
    || fail "matrix must mark led-2026-08-27-vacation-window-corrected as enforced"
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected") | .mechanism | test("fleet-credential-expiry-canary")' \
    "$matrix" >/dev/null \
    || fail "matrix mechanism must reference fleet-credential-expiry-canary"
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected") | .proof | test("credential-expiry-canary\\.test\\.sh")' \
    "$matrix" >/dev/null \
    || fail "matrix proof must reference credential-expiry-canary.test.sh"
ok "matrix row led-2026-08-27-vacation-window-corrected is enforced with mechanism + proof"

# --- 13. MANIFEST installs the canary + lib --------------------------------
grep -q 'bin/fleet-credential-expiry-canary' "$manifest" \
    || fail "MANIFEST must install bin/fleet-credential-expiry-canary"
grep -q 'lib/credential-expiry-canary.py' "$manifest" \
    || fail "MANIFEST must install lib/credential-expiry-canary.py"
ok "MANIFEST ships the canary binary + lib"

# --- 14. CI host lock ------------------------------------------------------
grep -Fq 'bash "$here/credential-expiry-canary.test.sh"' "$host" \
    || fail "escalation-coverage-canary.test.sh must invoke this file (CI host, no workflow edit)"
ok "nested from escalation-coverage-canary.test.sh"

# --- 15. ledger-line smoke -------------------------------------------------
set +e
out="$("$bin" --ledger-line 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--ledger-line must exit 0, got $rc: $out"
grep -q 'Vacation window corrected' <<<"$out" || fail "ledger-line must name the decision: $out"
grep -q '2026-09-08' <<<"$out" || fail "ledger-line must name the 2026-09-08 deadline: $out"
ok "ledger-line prints the vacation-window-corrected standing rule with 2026-09-08"

# --- 16. fixture dir mode --------------------------------------------------
scratch="$(mktemp -d -t cred-expiry-fixture.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
printf 'HTTP/2 200\n' >"$scratch/app.headers"
printf '%s\n' "$app_ok" >"$scratch/app.body"
set +e
out="$("$bin" --from-fixtures "$scratch" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "fixture mode must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "fixture PASS: $out"
ok "fixture dir mode → PASS"

echo "OK: credential-expiry-canary (fleet-ops#938)"
