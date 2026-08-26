#!/usr/bin/env bash
# tests/reopen-reverted-issues.test.sh
#
# Proves .github/scripts/reopen-reverted-issues.sh finds the PR that a
# failing merge commit belongs to, enumerates its closing issues, and reopens
# them with a comment linking the revert PR.
#
# Uses a stub gh to avoid touching real GitHub issues.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/reopen-reverted-issues.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$script" ]] || fail "script not found or not executable: $script"

scratch="$(mktemp -d -t reopen-reverted-issues.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stub_bin="$scratch/bin"
mkdir -p "$stub_bin"
STUB_LOG="$scratch/gh-calls.log"
export STUB_LOG

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
cmd="$*"
printf '%s\n' "$cmd" >> "$STUB_LOG"
case "$cmd" in
  *"api"*"commits"*"/pulls"*)
    printf '238\n'
    ;;
  *"pr view 238"*"--json state"*)
    printf 'MERGED\n'
    ;;
  *"pr view 238"*"--json closingIssuesReferences"*)
    printf '[{"number":221}]\n'
    ;;
  *"issue view 221"*)
    printf 'CLOSED\n'
    ;;
  *"issue reopen 221"*)
    exit 0
    ;;
  *)
    echo "unstubbed: $cmd" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$stub_bin/gh"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

out="$("$script" "Nishfleet/fleet-ops" \
  "1ecd9a2c9a57478d44b4be860a547410f8043cfd" \
  "241" 2>&1)" \
  || fail "script failed: $out"

# It should report reopening issue 221.
grep -q "reopened issue #221" <<< "$out" \
  || fail "expected script to report reopening issue #221: $out"

# It should have called gh issue reopen with a comment linking the revert PR.
grep -E "issue reopen 221 .*--comment .*revert PR #241" "$STUB_LOG" >/dev/null \
  || fail "expected gh issue reopen 221 to include comment linking revert PR #241"

# The comment should reference the original PR and the revert URL.
grep -E "issue reopen 221 .*https://github.com/Nishfleet/fleet-ops/pull/241" "$STUB_LOG" >/dev/null \
  || fail "expected reopen comment to link to the revert PR URL"

ok "reopened issue closed by the reverted PR with comment linking revert PR"
