#!/usr/bin/env bash
# tests/fleet-claim-release.test.sh — fleet-ops#6292
#
# The silent-PR-close class: deleting a PR's head branch makes GitHub close
# it under the deleting identity with no comment. bin/fleet-claim-release is
# the guarded OnFailure release; this drill is hermetic — a stub gh records
# every call and serves canned JSON. No live units, no network.
#
# Drills (the issue's Required, mapped onto the script):
#   1. --help exits 0 and names the ceremony.
#   2. THE #6258 SHAPE: worker failed, PR open on claim/issue-<N>, issue
#      agent-in-progress -> HOLD: zero DELETE calls, a comment lands on the
#      PR (mechanism + reason + owning issue), a trace lands on the issue,
#      and `gh issue edit` is never called.
#   3. No open PR, open agent-in-progress issue -> release: branch DELETE,
#      agent-ready flip, trace comment.
#   4. The pulls?head= check FAILS (the 2026-09-13 transient) -> fail-closed:
#      no DELETE, exit 0, OPEN-PR-CHECK-FAILED on stderr.
#   5. Closed issue, no PR -> branch DELETE but never --add-label agent-ready.
#   6. Open agent-blocked issue, no PR -> branch DELETE, in-progress removed,
#      agent-ready never re-added (fleet-ops#3763).
#   7. systemd/pi-issue-failed@.service calls bin/fleet-claim-release and the
#      silent-close check.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-claim-release"
unit="$repo_root/systemd/pi-issue-failed@.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
chmod +x "$bin"

scratch="$(mktemp -d -t fleet-claim-release.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin"
gh_log="$scratch/gh-calls.log"
: >"$gh_log"

# Stub gh: logs argv (one line per call), serves canned JSON per endpoint.
cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh' >> "$GH_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$GH_LOG"; done
printf '\n' >> "$GH_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
    token) echo "stub gh: token generate must never run in tests" >&2; exit 1 ;;
    api)
        endpoint="${1:-}"
        case "$endpoint" in
            -X)
                method="$1"; endpoint="$2"
                echo 'STUB: mutations must be intercepted' >/dev/null
                printf '{}' ;;
            "repos/"*"/pulls?state=open&head="*)
                [ "${MOCK_PULLS_RC:-0}" != "0" ] && exit "$MOCK_PULLS_RC"
                printf '%s' "${MOCK_OPEN_PRS:-[]}" ;;
            "repos/"*"/git/refs/heads/"*)
                [ "${MOCK_BRANCH_EXISTS:-yes}" = "yes" ] && printf '{"ref":"x"}' || exit 1 ;;
            *"timeline?"*) printf '%s' "${MOCK_TIMELINE:-[]}" ;;
            "repos/"*"/issues/"*)
                [ "${MOCK_ISSUE_RC:-0}" != "0" ] && exit "$MOCK_ISSUE_RC"
                if [ -n "${MOCK_ISSUE:-}" ]; then printf '%s' "$MOCK_ISSUE"; else printf '{"state":"open"}'; fi ;;
            *) printf '[]' ;;
        esac
        ;;
    issue)
        sub="${1:-}"
        case "$sub" in
            view)
                [ "${MOCK_ISSUE_RC:-0}" != "0" ] && exit "$MOCK_ISSUE_RC"
                if [ -n "${MOCK_ISSUE:-}" ]; then printf '%s' "$MOCK_ISSUE"; else printf '{"state":"open","labels":[]}'; fi ;;
            comment|edit) : ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$scratch/bin/gh"

export GH_LOG="$gh_log"
export GH_TOKEN="stub-token"
export PATH="$scratch/bin:/usr/local/bin:/usr/bin:/bin"
GH="$scratch/bin/gh"
export GH

run_release() {
    : >"$gh_log"
    local mi="${MOCK_ISSUE:-}"
    [ -z "$mi" ] && mi='{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}'
    MOCK_OPEN_PRS="${MOCK_OPEN_PRS:-[]}" MOCK_BRANCH_EXISTS="${MOCK_BRANCH_EXISTS:-yes}" \
    MOCK_PULLS_RC="${MOCK_PULLS_RC:-0}" MOCK_ISSUE_RC="${MOCK_ISSUE_RC:-0}" \
    MOCK_ISSUE="$mi" \
        "$bin" "$@"
}

# --- 1. --help -----------------------------------------------------------------
"$bin" --help >"$scratch/help.out" 2>&1 || fail "--help exited nonzero"
grep -qi "claim" "$scratch/help.out" || fail "--help missing ceremony text"
ok "--help exits 0, names the release"

# --- 2. #6258 shape: open PR on the claim branch -> HOLD ------------------------
out="$(MOCK_OPEN_PRS='[{"number":6258,"head":{"ref":"claim/issue-6252"}}]' \
    "$bin" fleet-ops-6252 2>"$scratch/err.2")" || fail "hold path exited nonzero"
if grep -q "DELETE" "$gh_log"; then fail "hold path still deleted the branch: $(cat "$gh_log")"; fi
grep -q "issues/6258/comments" "$gh_log" || fail "no comment posted on the open PR: $(cat "$gh_log")"
grep -q "issue comment 6252" "$gh_log" || fail "no trace comment on the issue: $(cat "$gh_log")"
grep -qc "issue edit" "$gh_log" && fail "label flip ran while a PR was open" || true
ok "open-PR hold: no DELETE, PR comment + issue trace, no label flip"

# --- 3. no open PR, open issue -> release --------------------------------------
out="$(run_release fleet-ops-6252 2>"$scratch/err.3")" || fail "release path exited nonzero"
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "no-PR path did not delete the branch: $(cat "$gh_log")"
grep -q "issue edit 6252 .*--add-label agent-ready" "$gh_log" \
    || fail "release did not flip to agent-ready: $(cat "$gh_log")"
grep -q "issue comment 6252" "$gh_log" || fail "release posted no trace line: $(cat "$gh_log")"
ok "no-PR release: DELETE + agent-ready flip + issue trace"

# --- 4. pulls check fails -> fail-closed hold -----------------------------------
out="$(MOCK_PULLS_RC=1 run_release fleet-ops-6252 2>"$scratch/err.4")" || fail "check-failure path exited nonzero"
if grep -q "DELETE" "$gh_log"; then fail "gh failure still deleted: $(cat "$gh_log")"; fi
grep -q "OPEN-PR-CHECK-FAILED" "$scratch/err.4" || fail "no loud flag on gh failure: $(cat "$scratch/err.4")"
ok "pulls failure -> fail-closed hold, loud flag"

# --- 5. closed issue, no PR -> delete, never agent-ready -------------------------
out="$(MOCK_ISSUE='{"state":"CLOSED","labels":[{"name":"agent-in-progress"}]}' \
    run_release fleet-ops-6252 2>"$scratch/err.5")" || fail "closed-issue path exited nonzero"
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "closed-issue path did not delete the branch: $(cat "$gh_log")"
if grep -q "issue edit.*--add-label agent-ready" "$gh_log"; then
    fail "agent-ready added on a closed issue"
fi
ok "closed issue: DELETE + no re-queue"

# --- 6. agent-blocked, no PR -> delete, no re-queue ------------------------------
out="$(MOCK_ISSUE='{"state":"OPEN","labels":[{"name":"agent-in-progress"},{"name":"agent-blocked"}]}' \
    run_release fleet-ops-6252 2>"$scratch/err.6")" || fail "blocked path exited nonzero"
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "blocked path did not delete the branch: $(cat "$gh_log")"
if grep -q "issue edit.*--add-label agent-ready" "$gh_log"; then
    fail "agent-ready re-added on an agent-blocked issue"
fi
ok "agent-blocked: DELETE + in-progress cleared, never re-queued"

# --- 7. unit wiring --------------------------------------------------------------
grep -q "bin/fleet-claim-release %i" "$unit" \
    || fail "pi-issue-failed@.service does not call bin/fleet-claim-release"
grep -q "bin/fleet-silent-pr-close-check" "$unit" \
    || fail "pi-issue-failed@.service does not run the silent-close check"
ok "unit calls the guarded release and the detector"

echo "PASS: fleet-claim-release"
