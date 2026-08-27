#!/usr/bin/env bash
# tests/cf-token-canary.test.sh
#
# fleet-ops#1166: the sanctioned VPS Cloudflare token liveness canary
# screams when the CF file is missing, empty, 401, non-200, or 200-but-
# not-active; it PASSes only on 200 + active. Offline: never talks to
# Cloudflare. The token value is never printed.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/cf-token-canary.py"
bin="$repo_root/bin/fleet-cf-token-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"
host="$here/escalation-coverage-canary.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- 1. 200 + active → PASS ------------------------------------------------
set +e
out="$("$bin" --cf-status 200 --cf-active active 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "200+active must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "tokens/verify 200 + active → PASS"

# --- 2. 401 → REJECT -------------------------------------------------------
set +e
out="$("$bin" --cf-status 401 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "401 must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
grep -q '401' <<<"$out" || fail "must name 401: $out"
ok "tokens/verify 401 → REJECT (dead token)"

# --- 3. missing file → REJECT ----------------------------------------------
set +e
out="$("$bin" --no-file 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing file must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
grep -q 'missing' <<<"$out" || fail "must name missing: $out"
ok "missing CF file → REJECT"

# --- 4. 200 + expired → REJECT ---------------------------------------------
set +e
out="$("$bin" --cf-status 200 --cf-active expired 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "200+expired must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
grep -q 'expired' <<<"$out" || fail "must name expired: $out"
ok "tokens/verify 200 + expired → REJECT"

# --- 5. 200 + missing status → REJECT --------------------------------------
set +e
out="$("$bin" --cf-status 200 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "200+no-status must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "tokens/verify 200 + missing status → REJECT"

# --- 6. non-401 non-200 → REJECT (status-accurate hint) --------------------
set +e
out="$("$bin" --cf-status 500 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "500 must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
grep -q '500' <<<"$out" || fail "must name 500: $out"
# must NOT mislabel a 500 as 401/dead
! grep -q 'dead/revoked' <<<"$out" || fail "500 must not be mislabelled 401/dead: $out"
ok "tokens/verify 500 → REJECT (status-accurate, not mislabelled 401)"

# --- 7. present-but-empty token file → REJECT ------------------------------
scratch="$(mktemp -d -t cf-token-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
empty="$scratch/empty.env"
: >"$empty"
chmod 600 "$empty"
set +e
out="$("$bin" --cf-file "$empty" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "empty token file must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
grep -q 'no.*CLOUDFLARE_API_TOKEN' <<<"$out" || fail "must name no-token: $out"
ok "present-but-empty token file → REJECT"

# --- 8. token value never printed ------------------------------------------
# The secret-bearing variable `token`/`val` must never be interpolated into
# any print/format/log call. The canary name "cf-token-canary" legitimately
# contains the word "token" in a string literal — exclude that. Assert no
# line passes the secret variable into output.
if grep -En 'print.*(\btoken\b|\bval\b)' "$lib" | grep -v 'cf-token-canary' | grep -Eq 'print.*\b(token|val)\b'; then
  fail "lib must not interpolate the secret token/val variable into output"
fi
# The only legitimate use of the secret `token` variable is the Bearer header.
bearer_uses=$(grep -Ec '"Authorization": "Bearer " \+ token' "$lib")
[[ "$bearer_uses" -eq 1 ]] || fail "secret token must be used only in the Bearer header (found $bearer_uses)"
ok "lib never interpolates the secret token variable into output"

# --- 9. heartbeat-tier1 block 32 wiring ------------------------------------
grep -q 'CF_TOKEN_CANARY_BIN' "$tier1" \
  || fail "tier1 must reference CF_TOKEN_CANARY_BIN"
grep -q 'cf_token_canary_rc' "$tier1" \
  || fail "tier1 must propagate cf_token_canary_rc"
grep -q '32. cf token canary' "$tier1" \
  || fail "tier1 must name block 32 as cf token canary"
grep -q 'require_manifest_helper.*CF_TOKEN_CANARY' "$tier1" \
  || fail "tier1 block 32 must call require_manifest_helper"
grep -q 'HELPER-MISSING.*cf token' "$tier1" \
  || fail "tier1 block 32 must loud HELPER-MISSING"
# exit propagation
grep -F -- '_propagate_crash cf_token_canary_rc' "$tier1" \
  || fail "tier1 must exit-propagate cf_token_canary_rc"
# final log line includes the rc
grep -q 'cf_token_canary_rc=' "$tier1" \
  || fail "tier1 final log must include cf_token_canary_rc"
ok "tier1 block 32 wires cf-token-canary with require_manifest_helper + exit propagation"

# --- 10. MANIFEST ships the binary + lib -----------------------------------
grep -q 'bin/fleet-cf-token-canary' "$manifest" \
  || fail "MANIFEST must install bin/fleet-cf-token-canary"
grep -q 'lib/cf-token-canary.py' "$manifest" \
  || fail "MANIFEST must install lib/cf-token-canary.py"
ok "MANIFEST ships the cf-token canary binary + lib"

# --- 11. CI host lock (nested from escalation-coverage-canary) -------------
grep -Fq 'bash "$here/cf-token-canary.test.sh"' "$host" \
  || fail "escalation-coverage-canary.test.sh must invoke this file (CI host, no workflow edit)"
ok "nested from escalation-coverage-canary.test.sh"

# --- 12. ledger-line smoke -------------------------------------------------
set +e
out="$("$bin" --ledger-line 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--ledger-line must exit 0, got $rc: $out"
grep -q 'fleet-ops#1166' <<<"$out" || fail "ledger-line must name fleet-ops#1166: $out"
grep -q '200/active' <<<"$out" || fail "ledger-line must name 200/active: $out"
ok "ledger-line prints the sanctioned-VPS-CF-token standing rule"

# --- 13. callers retargeted to deploy-ci.env -------------------------------
deploy="$repo_root/bin/siterep-deploy"
rollback="$repo_root/bin/siterep-deploy-rollback"
grep -q 'deploy-ci\.env' "$deploy" \
  || fail "siterep-deploy must source deploy-ci.env (fleet-ops#1166)"
grep -q 'deploy-ci\.env' "$rollback" \
  || fail "siterep-deploy-rollback must source deploy-ci.env (fleet-ops#1166)"
# must NOT still hard-source the dead deploy.env (env-var seam ok, literal not)
! grep -Eq 'CREDS_FILE="/home/nish/.config/cloudflare/deploy\.env"' "$deploy" \
  || fail "siterep-deploy must not literal-source deploy.env"
! grep -Eq 'CREDS_FILE="/home/nish/.config/cloudflare/deploy\.env"' "$rollback" \
  || fail "siterep-deploy-rollback must not literal-source deploy.env"
ok "siterep-deploy + rollback retargeted to deploy-ci.env"

echo "OK: cf-token-canary (fleet-ops#1166)"
