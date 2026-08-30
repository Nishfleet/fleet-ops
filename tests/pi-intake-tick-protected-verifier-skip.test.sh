#!/usr/bin/env bash
# tests/pi-intake-tick-protected-verifier-skip.test.sh
#
# fleet-ops#1165: 0509 issues whose files touch protected verifier/deploy
# paths must be SKIPPED by the intake tick instead of claimed+spawned.
#
# Proves:
#   1. The protected_files_filter function exists in lib/pi-intake-tick.sh.
#   2. The skip call site is present in the issue loop (skipped-protected-verifier).
#   3. The protected-verifier-files.json config ships with the right paths.
#   4. The filter correctly classifies a 0509 issue that references a protected
#      file path as skip (return 0).
#   5. The filter correctly classifies an issue that does NOT reference any
#      protected file as do-not-skip (return 1).
#   6. The filter is fail-open: a missing config file means no skip.
#   7. Only repos listed in protected_repos are subject to the skip.
#   8. MANIFEST ships the config file.
#   9. prompts/intake.md and prompts/scout.md document the park.
#  10. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
manifest="$repo_root/MANIFEST"
config="$repo_root/config/protected-verifier-files.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# === Test 1: function exists ===
grep -qF 'protected_files_filter()' "$tick" \
    || fail "protected_files_filter() not found in tick"
ok "Test 1: protected_files_filter() present"

# === Test 2: skip call site present ===
grep -qF 'skipped-protected-verifier' "$tick" \
    || fail "skipped-protected-verifier skip message not found in tick"
ok "Test 2: skipped-protected-verifier call site present"

# === Test 3: config file ships protected_files list ===
[[ -f "$config" ]] || fail "config/protected-verifier-files.json missing"
jq -e '.protected_files | type == "array" and length > 0' "$config" >/dev/null \
    || fail "protected_files not a non-empty array in config"
# The critical 0509 protected files must be present.
for pf in '.github/workflows/ci.yml' \
          '.github/workflows/deploy-production.yml' \
          '.github/workflows/finalize-production-soak.yml' \
          '.github/scripts/required-verifier-integrity.sh' \
          'scripts/ci-verify-production-candidate.sh' \
          'scripts/ci-verify-provider-main-cas.sh'; do
    jq -e --arg pf "$pf" '.protected_files | index($pf) != null' "$config" >/dev/null 2>&1 \
        || fail "protected_files missing: $pf"
done
ok "Test 3: config ships correct protected_files list"

# === Tests 4-7: filter logic ===
# Extract the protected_files_filter function body and run it in a subshell
# with a stub `gh` function and a controlled config file.
extract_filter() {
    sed -n '/^protected_files_filter() {$/,/^}$/p' "$tick"
}
filter_fn=$(extract_filter)
[[ -n "$filter_fn" ]] || fail "could not extract protected_files_filter body"

# Stub config with a minimal protected_files list + 0509 as protected repo.
stub_config=$(mktemp)
cat > "$stub_config" <<'JSON'
{
  "protected_repos": ["0509"],
  "protected_files": [
    ".github/workflows/ci.yml",
    ".github/scripts/required-verifier-integrity.sh"
  ]
}
JSON

# run_filter <repo> <issue_text> — sets up FULL, PROTECTED_FILES_CONFIG, stubs
# gh to return <issue_text> as the concatenated title+body+comments, then
# calls protected_files_filter and echoes the return code.
run_filter() {
    local repo="$1" issue_text="$2"
    local rc
    (
        REPO="$repo"
        FULL="Nishfleet/${repo}"
        PROTECTED_FILES_CONFIG="$stub_config"
        # Stub gh: return pre-formed JSON matching the jq filter's output shape.
        # The filter does: .title + "\n" + (.body // "") + "\n" + comments join
        # We put the entire issue_text into the body field so grep can find paths.
        gh() {
            if [[ "$1" == "issue" && "$2" == "view" ]]; then
                local num="${@: -2:1}"  # the issue number positional
                # Return JSON that jq will flatten to just our text.
                printf '{"title":"%s","body":"%s","comments":[]}' \
                    "test-issue" "$issue_text"
                return 0
            fi
            echo "stub gh: unexpected: $*" >&2
            return 1
        }
        eval "$filter_fn"
        protected_files_filter 999
    ) 2>/dev/null
    rc=$?
    echo "$rc"
}

# Test 4: 0509 issue referencing .github/workflows/ci.yml → skip (rc=0)
rc=$(run_filter "0509" "references .github/workflows/ci.yml in the body")
[[ "$rc" == "0" ]] || fail "Test 4: 0509 issue with protected file should skip (rc=$rc)"
ok "Test 4: 0509 issue referencing protected file is skipped"

# Test 5: 0509 issue with NO protected file → do not skip (rc=1)
rc=$(run_filter "0509" "This issue is about improving search relevance on 0509.io")
[[ "$rc" == "1" ]] || fail "Test 5: 0509 issue without protected file should NOT skip (rc=$rc)"
ok "Test 5: 0509 issue without protected file is NOT skipped"

# Test 6: missing config → fail-open (rc=1, no skip)
rc=$(run_filter "0509" "references .github/workflows/ci.yml")
# Override PROTECTED_FILES_CONFIG to a nonexistent path.
rc=$(PROTECTED_FILES_CONFIG="/nonexistent/path.json" bash -c '
    REPO="0509"; FULL="Nishfleet/0509"; PROTECTED_FILES_CONFIG="/nonexistent/path.json"
    gh() { printf "{\"title\":\"x\",\"body\":\"references .github/workflows/ci.yml\",\"comments\":[]}"; return 0; }
    '"$filter_fn"'
    protected_files_filter 999; echo $?
' 2>/dev/null)
[[ "$rc" == "1" ]] || fail "Test 6: missing config should be fail-open (rc=$rc)"
ok "Test 6: missing config -> fail-open (no skip)"

# Test 7: non-protected repo (not in protected_repos) → no skip even if body
# references a protected file path.
rc=$(PROTECTED_FILES_CONFIG="$stub_config" bash -c '
    REPO="some-repo"; FULL="Nishfleet/some-repo"; PROTECTED_FILES_CONFIG="'"$stub_config"'"
    gh() { printf "{\"title\":\"x\",\"body\":\"references .github/workflows/ci.yml\",\"comments\":[]}"; return 0; }
    '"$filter_fn"'
    protected_files_filter 999; echo $?
' 2>/dev/null)
[[ "$rc" == "1" ]] || fail "Test 7: non-protected repo should NOT skip (rc=$rc)"
ok "Test 7: non-protected repo is NOT skipped even with protected file reference"

# === Test 8: MANIFEST ships config ===
grep -qF 'config/protected-verifier-files.json' "$manifest" \
    || fail "MANIFEST missing protected-verifier-files.json entry"
grep -qF 'protected-verifier-files.json /home/nish/.local/state/pi-packet/protected-verifier-files.json' "$manifest" \
    || fail "MANIFEST entry for protected-verifier-files.json has wrong install path"
ok "Test 8: MANIFEST ships protected-verifier-files.json"

# === Test 9: prompts document the park ===
grep -qF 'verifier-attest' "$repo_root/prompts/intake.md" \
    || fail "prompts/intake.md does not mention verifier-attest"
grep -qi 'park\|skipped-protected' "$repo_root/prompts/intake.md" \
    || fail "prompts/intake.md does not mention park/skip"
grep -qF 'verifier-attest' "$repo_root/prompts/scout.md" \
    || fail "prompts/scout.md does not mention verifier-attest"
ok "Test 9: prompts document the protected-verifier park"

# === Test 10: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 10: shellcheck clean"
else
    echo "SKIP: Test 10: shellcheck not installed"
fi

rm -f "$stub_config"

echo ""
echo "ALL OK: protected-verifier skip guards intake against attest-stuck PRs"