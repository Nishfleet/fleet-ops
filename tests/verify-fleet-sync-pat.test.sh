#!/usr/bin/env bash
# tests/verify-fleet-sync-pat.test.sh
#
# fleet-ops#482 drill: the FLEET_SYNC_PAT probe must REJECT a token that is
# set but missing the `workflow` scope or org push access, and PASS a token
# that has repo+workflow scopes and push access. The old non-empty check
# let a dead/under-scoped PAT sail past and fail later inside BetaHuhn with
# a vague "Resource not accessible by personal access token" or "Permission
# to Nishfleet/<repo>.git denied".
#
# Fixture mode (--from-fixtures) replays recorded HTTP responses so the
# inner loop runs anywhere with no network.
#
# Drills:
#   1. classic PAT missing `workflow` scope -> REJECT (the #482 root cause).
#   2. classic PAT missing `repo` scope -> REJECT.
#   3. classic PAT with repo+workflow scopes but push=false (no org push)
#      -> REJECT (the #482 org-push root cause).
#   4. classic PAT with repo+workflow scopes and push=true -> PASS.
#   5. empty token -> REJECT (the old non-empty check, kept).
#   6. dead token (401 on /user) -> REJECT.
#   7. App/fine-grained token with push=false -> REJECT (no push).
#   8. fine-grained PAT with push=true -> PASS (push is the certifiable signal).
#   9. ledger line names #482 and BetaHuhn.
#  10. lock: the probe is the canonical verifier bin + lib pair.
#  11. lock: --repo validation rejects path-escape attempts (SSRF bound).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/bin/verify-fleet-sync-pat"
lib="$repo_root/lib/verify-fleet-sync-pat.py"
fixtures="$here/fixtures/verify-fleet-sync-pat"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$probe" ]] || fail "not executable: $probe"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "verify-fleet-sync-pat.py failed py_compile"

run_fix() {
  local dir="$1"
  "$probe" --from-fixtures "$dir"
}

# --- 1. classic PAT missing `workflow` scope -> REJECT ----------------------
set +e
out=$(run_fix "$fixtures/classic-missing-workflow" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing-workflow must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "missing-workflow must REJECT: $out"
grep -q 'missing the `workflow` scope' <<<"$out" \
  || fail "missing-workflow reason must name the workflow scope: $out"
grep -q 'Resource not accessible by personal access token' <<<"$out" \
  || fail "missing-workflow reason must name the BetaHuhn failure mode: $out"
ok "drill REJECT: classic PAT missing workflow scope (the #482 root cause)"

# --- 2. classic PAT missing `repo` scope -> REJECT --------------------------
set +e
out=$(run_fix "$fixtures/classic-missing-repo" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing-repo must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "missing-repo must REJECT: $out"
grep -q 'missing the `repo` scope' <<<"$out" \
  || fail "missing-repo reason must name the repo scope: $out"
ok "drill REJECT: classic PAT missing repo scope"

# --- 3. classic PAT with scopes but no org push -> REJECT -------------------
set +e
out=$(run_fix "$fixtures/classic-no-org-push" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "no-org-push must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "no-org-push must REJECT: $out"
grep -q 'permissions.push=false' <<<"$out" \
  || fail "no-org-push reason must name permissions.push=false: $out"
grep -q 'Permission to Nishfleet/<repo>.git denied' <<<"$out" \
  || fail "no-org-push reason must name the org-push denial: $out"
ok "drill REJECT: classic PAT with scopes but no org push (the #482 org-push root cause)"

# --- 4. classic PAT with repo+workflow scopes and push=true -> PASS ---------
set +e
out=$(run_fix "$fixtures/classic-full" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "classic-full must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "classic-full must PASS: $out"
grep -q 'repo+workflow scopes' <<<"$out" \
  || fail "classic-full reason must name repo+workflow scopes: $out"
ok "drill PASS: classic PAT with repo+workflow scopes and push access"

# --- 5. empty token -> REJECT (the old non-empty check, kept) ---------------
set +e
out=$("$probe" --token "" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "empty token must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "empty token must REJECT: $out"
grep -q 'is not set' <<<"$out" \
  || fail "empty token reason must say 'is not set': $out"
ok "drill REJECT: empty token (old non-empty check preserved)"

# --- 6. dead token (401 on /user) -> REJECT ---------------------------------
set +e
out=$(run_fix "$fixtures/dead-token" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "dead-token must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "dead-token must REJECT: $out"
grep -q 'dead or revoked' <<<"$out" \
  || fail "dead-token reason must name dead/revoked: $out"
ok "drill REJECT: dead token (401 on /user)"

# --- 7. App/fine-grained token with push=false -> REJECT --------------------
set +e
out=$(run_fix "$fixtures/app-no-push-dir" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "app-no-push must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null || fail "app-no-push must REJECT: $out"
grep -q 'permissions.push=false' <<<"$out" \
  || fail "app-no-push reason must name permissions.push=false: $out"
ok "drill REJECT: App/fine-grained token with no push"

# --- 8. fine-grained PAT with push=true -> PASS -----------------------------
set +e
out=$(run_fix "$fixtures/fine-grained-with-push" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "fine-grained-with-push must exit 0, got $rc: $out"
jq -e '.verdict=="PASS"' <<<"$out" >/dev/null || fail "fine-grained-with-push must PASS: $out"
grep -q 'push access' <<<"$out" \
  || fail "fine-grained-with-push reason must name push access: $out"
ok "drill PASS: fine-grained PAT with push access"

# --- 9. ledger line names #482 ----------------------------------------------
ledger=$("$probe" --ledger-line)
[[ -n "$ledger" ]] || fail "empty ledger line"
grep -q 'fleet-ops #482' <<<"$ledger" || fail "ledger line must cite fleet-ops #482"
grep -q 'BetaHuhn' <<<"$ledger" || fail "ledger line must name BetaHuhn"
ok "ledger line cites #482 and names BetaHuhn"

# --- 10. lock: the probe is the canonical verifier bin + lib pair -----------
[[ -x "$probe" ]] || fail "bin/verify-fleet-sync-pat must be executable"
[[ -f "$lib" ]] || fail "lib/verify-fleet-sync-pat.py must exist"
# The probe is the intended wiring for repo-standards-sync.yml's Verify step.
# The workflow file edit itself is gated on Nish's own scope (the worker App
# cannot push .github/workflows/** — see the 0509 follow-up); this lock
# certifies the probe that wiring will call, not that the wiring has landed.
ok "canonical probe bin + lib pair present"

# --- 11. lock: --repo validation rejects path-escape attempts ---------------
set +e
out=$("$probe" --token "dummy" --repo "../../etc/passwd" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "path-escape --repo must exit 1, got $rc: $out"
jq -e '.verdict=="REJECT"' <<<"$out" >/dev/null \
  || fail "path-escape --repo must REJECT: $out"
grep -q 'invalid --repo' <<<"$out" \
  || fail "path-escape --repo reason must name invalid --repo: $out"
ok "--repo validation rejects path-escape (SSRF bound)"

echo "OK: verify-fleet-sync-pat drill (fleet-ops#482)"
