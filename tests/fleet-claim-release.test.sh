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
#   8. THE #8003 SHAPE: no PR, claim branch AHEAD of main -> the branch is
#      copied to wip/issue-<N> BEFORE the claim ref is deleted, and the trace
#      line names the wip ref.
#   9. wip/issue-<N> already exists on a divergent tip -> the preserve lands
#      on a sha-suffixed wip ref instead of clobbering the earlier salvage.
#  10. wip exists and its tip is already inside the claim history -> wip is
#      fast-forwarded (PATCH), no suffixed ref.
#  11. The ahead-of-main compare FAILS -> fail-closed: no DELETE, exit 0,
#      AHEAD-CHECK-FAILED on stderr.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-claim-release"
unit="$repo_root/systemd/pi-issue-failed@.service"
worker_unit="$repo_root/systemd/pi-issue@.service"

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
            "repos/"*"/pulls?state=all&head="*)
                [ "${MOCK_ALL_PRS_RC:-0}" != "0" ] && exit "$MOCK_ALL_PRS_RC"
                printf '%s' "${MOCK_ALL_PRS:-[]}" ;;
            "repos/"*"/git/refs/heads/wip/"*)
                [ "${MOCK_WIP_EXISTS:-no}" = "yes" ] && printf '{"ref":"x","object":{"sha":"%s"}}' "${MOCK_WIP_SHA:-w1pw1pw1p}" || exit 1 ;;
            "repos/"*"/git/refs/heads/"*)
                [ "${MOCK_BRANCH_EXISTS:-yes}" = "yes" ] && printf '{"ref":"x","object":{"sha":"%s"}}' "${MOCK_CLAIM_SHA:-c1a1c1a1c}" || exit 1 ;;
            "repos/"*"/compare/"*)
                case "$endpoint" in
                    *"/compare/${MOCK_WIP_SHA:-_wipnone_}..."*)
                        [ "${MOCK_WIP_COMPARE_RC:-0}" != "0" ] && exit "$MOCK_WIP_COMPARE_RC"
                        if [ -n "${MOCK_WIP_COMPARE:-}" ]; then printf '%s' "$MOCK_WIP_COMPARE"; else printf '%s' '{"status":"ahead"}'; fi ;;
                    *)  [ "${MOCK_COMPARE_RC:-0}" != "0" ] && exit "$MOCK_COMPARE_RC"
                        if [ -n "${MOCK_COMPARE:-}" ]; then printf '%s' "$MOCK_COMPARE"; else printf '%s' '{"ahead_by":0,"status":"identical"}'; fi ;;
                esac ;;
            *"timeline?"*) printf '%s' "${MOCK_TIMELINE:-[]}" ;;
            "repos/"*"/issues/"*)
                [ "${MOCK_ISSUE_RC:-0}" != "0" ] && exit "$MOCK_ISSUE_RC"
                if [ -n "${MOCK_ISSUE:-}" ]; then printf '%s' "$MOCK_ISSUE"; else printf '{"state":"open"}'; fi ;;
            "repos/Nishfleet/"*) printf '{"default_branch":"%s"}' "${MOCK_DEFAULT_BRANCH:-main}" ;;
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
    MOCK_ALL_PRS="${MOCK_ALL_PRS:-[]}" MOCK_ALL_PRS_RC="${MOCK_ALL_PRS_RC:-0}" \
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

# --- 8. #8003 shape: claim branch ahead of main -> preserve to wip, then delete ---
out="$(MOCK_CLAIM_SHA='aa11bb22cc33dd44' MOCK_COMPARE='{"ahead_by":2,"status":"ahead"}' \
    run_release fleet-ops-6252 2>"$scratch/err.8")" || fail "preserve path exited nonzero: $(cat "$scratch/err.8")"
grep -q "POST repos/Nishfleet/fleet-ops/git/refs .*refs/heads/wip/issue-6252 .*aa11bb22cc33dd44" "$gh_log" \
    || fail "ahead path did not create wip/issue-6252 at the claim sha: $(cat "$gh_log")"
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "ahead path did not delete the claim ref: $(cat "$gh_log")"
post_line="$(grep -n "POST repos/Nishfleet/fleet-ops/git/refs" "$gh_log" | head -1 | cut -d: -f1)"
del_line="$(grep -n "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim" "$gh_log" | head -1 | cut -d: -f1)"
[ -n "$post_line" ] && [ -n "$del_line" ] && [ "$post_line" -lt "$del_line" ] \
    || fail "wip ref was not created before the claim delete: $(cat "$gh_log")"
grep -q "compare/main...claim/issue-6252" "$gh_log" \
    || fail "ahead check did not compare default branch vs claim: $(cat "$gh_log")"
grep -q "preserved claim/issue-6252@aa11bb22cc33dd44 as refs/heads/wip/issue-6252" "$scratch/err.8" \
    || fail "no preserved log line: $(cat "$scratch/err.8")"
ok "ahead-of-main: wip copy created before DELETE, claim released"

# --- 9. wip exists on a divergent tip -> suffixed ref, earlier salvage kept ------
out="$(MOCK_CLAIM_SHA='aa11bb22cc33dd44' MOCK_COMPARE='{"ahead_by":2,"status":"ahead"}' \
    MOCK_WIP_EXISTS=yes MOCK_WIP_SHA='ff99ee88dd77cc66' MOCK_WIP_COMPARE='{"status":"diverged"}' \
    run_release fleet-ops-6252 2>"$scratch/err.9")" || fail "divergent-wip path exited nonzero: $(cat "$scratch/err.9")"
grep -q "POST repos/Nishfleet/fleet-ops/git/refs .*refs/heads/wip/issue-6252-aa11bb22 .*aa11bb22cc33dd44" "$gh_log" \
    || fail "divergent wip was clobbered or no suffixed ref created: $(cat "$gh_log")"
if grep -q "PATCH repos/Nishfleet/fleet-ops/git/refs/heads/wip/issue-6252 " "$gh_log"; then
    fail "divergent wip was force-updated: $(cat "$gh_log")"
fi
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "divergent-wip path did not delete the claim ref: $(cat "$gh_log")"
ok "divergent wip: suffixed preserve ref, earlier salvage untouched"

# --- 10. wip exists, tip already inside claim history -> fast-forward PATCH ------
out="$(MOCK_CLAIM_SHA='aa11bb22cc33dd44' MOCK_COMPARE='{"ahead_by":3,"status":"ahead"}' \
    MOCK_WIP_EXISTS=yes MOCK_WIP_SHA='ff99ee88dd77cc66' MOCK_WIP_COMPARE='{"status":"ahead"}' \
    run_release fleet-ops-6252 2>"$scratch/err.10")" || fail "ff-wip path exited nonzero: $(cat "$scratch/err.10")"
grep -q "PATCH repos/Nishfleet/fleet-ops/git/refs/heads/wip/issue-6252 .*aa11bb22cc33dd44" "$gh_log" \
    || fail "wip was not fast-forwarded to the claim sha: $(cat "$gh_log")"
if grep -q "refs/heads/wip/issue-6252-" "$gh_log"; then
    fail "suffixed ref created although fast-forward was safe: $(cat "$gh_log")"
fi
grep -q "DELETE repos/Nishfleet/fleet-ops/git/refs/heads/claim/issue-6252" "$gh_log" \
    || fail "ff-wip path did not delete the claim ref: $(cat "$gh_log")"
ok "ancestor wip: fast-forwarded, no suffixed ref"

# --- 11. compare fails -> fail-closed hold ----------------------------------------
out="$(MOCK_COMPARE_RC=1 run_release fleet-ops-6252 2>"$scratch/err.11")" || fail "compare-failure path exited nonzero"
if grep -q "DELETE" "$gh_log"; then fail "compare failure still deleted: $(cat "$gh_log")"; fi
if grep -q "POST repos/Nishfleet/fleet-ops/git/refs" "$gh_log"; then
    fail "compare failure still wrote refs: $(cat "$gh_log")"
fi
if grep -q "issue edit" "$gh_log"; then fail "label flip ran on a held claim: $(cat "$gh_log")"; fi
grep -q "AHEAD-CHECK-FAILED" "$scratch/err.11" || fail "no loud flag on compare failure: $(cat "$scratch/err.11")"
ok "compare failure -> fail-closed hold, loud flag"

# --- 13. --require-artifact: open PR -> OK, read-only (fleet-ops#7745) -----------
MOCK_ALL_PRS='[{"number":700,"state":"open","merged_at":null}]' \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.13" \
    || fail "--require-artifact rejected an open PR: $(cat "$scratch/err.13")"
grep -q "ARTIFACT-OK" "$scratch/err.13" || fail "no ARTIFACT-OK for an open PR"
if grep -Eq "DELETE|issue edit|issue comment|git/refs" "$gh_log"; then
    fail "--require-artifact wrote on the OK path: $(cat "$gh_log")"
fi
ok "--require-artifact: open PR -> OK, no writes"

# --- 14. --require-artifact: merged PR (branch deleted mid-run) -> OK -----------
MOCK_ALL_PRS='[{"number":700,"state":"closed","merged_at":"2026-09-20T00:00:00Z"}]' \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.14" \
    || fail "--require-artifact rejected a merged PR: $(cat "$scratch/err.14")"
grep -q "ARTIFACT-OK" "$scratch/err.14" || fail "no ARTIFACT-OK for a merged PR"
ok "--require-artifact: merged PR -> OK"

# --- 15. --require-artifact: closed-unmerged PR is NOT evidence -> exit 1 --------
if MOCK_ALL_PRS='[{"number":700,"state":"closed","merged_at":null}]' \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.15"; then
    fail "a closed-unmerged PR counted as an artifact"
fi
grep -q "NO-ARTIFACT" "$scratch/err.15" || fail "no NO-ARTIFACT flag: $(cat "$scratch/err.15")"
ok "--require-artifact: closed-unmerged PR -> exit 1"

# --- 16. --require-artifact: no PR, no label, issue open -> exit 1 --------------
if MOCK_ALL_PRS='[]' MOCK_ISSUE='{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.16"; then
    fail "the zero-artifact run exited 0 (the #7745 wedge)"
fi
grep -q "NO-ARTIFACT" "$scratch/err.16" || fail "no NO-ARTIFACT flag: $(cat "$scratch/err.16")"
if grep -Eq "DELETE|issue edit|issue comment|git/refs" "$gh_log"; then
    fail "the no-artifact path wrote: $(cat "$gh_log")"
fi
ok "--require-artifact: zero-artifact exit 0 -> exit 1, no writes"

# --- 17. --require-artifact: worker-terminal label -> OK ------------------------
for lbl in agent-blocked needs-orchestrator needs-nish-decision; do
    MOCK_ALL_PRS='[]' MOCK_ISSUE="{\"state\":\"OPEN\",\"labels\":[{\"name\":\"$lbl\"}]}" \
        run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.17" \
        || fail "--require-artifact rejected terminal label $lbl: $(cat "$scratch/err.17")"
done
grep -q "ARTIFACT-OK" "$scratch/err.17" || fail "no ARTIFACT-OK for a terminal label"
ok "--require-artifact: agent-blocked/needs-orchestrator/needs-nish-decision -> OK"

# --- 18. --require-artifact: CLOSED issue with no PR -> OK ----------------------
MOCK_ALL_PRS='[]' MOCK_ISSUE='{"state":"CLOSED","labels":[]}' \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.18" \
    || fail "--require-artifact rejected a closed issue: $(cat "$scratch/err.18")"
grep -q "ARTIFACT-OK" "$scratch/err.18" || fail "no ARTIFACT-OK for a closed issue"
ok "--require-artifact: closed issue -> OK"

# --- 19. --require-artifact: a failed run is the release path's business ---------
if ! MOCK_ALL_PRS='[]' SERVICE_RESULT=exit-code \
    run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.19"; then
    fail "--require-artifact judged a run that already failed: $(cat "$scratch/err.19")"
fi
grep -q "ARTIFACT-SKIP" "$scratch/err.19" || fail "no ARTIFACT-SKIP on a non-success result"
if grep -q "pulls?state=all" "$gh_log"; then
    fail "--require-artifact queried GitHub on a non-success run: $(cat "$gh_log")"
fi
ok "--require-artifact: SERVICE_RESULT!=success -> skip, no queries"

# --- 20. --require-artifact: unreadable checks fail the run (fail-closed) --------
if MOCK_ALL_PRS_RC=1 run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.20"; then
    fail "an unreadable pulls?state=all did not fail the run"
fi
grep -q "ARTIFACT-CHECK-FAILED" "$scratch/err.20" || fail "no ARTIFACT-CHECK-FAILED flag: $(cat "$scratch/err.20")"
if MOCK_ALL_PRS='[]' MOCK_ISSUE_RC=1 run_release fleet-ops-6252 --require-artifact >/dev/null 2>"$scratch/err.20b"; then
    fail "an unreadable issue did not fail the run"
fi
grep -q "ARTIFACT-CHECK-FAILED" "$scratch/err.20b" || fail "no ARTIFACT-CHECK-FAILED on issue read"
ok "--require-artifact: unreadable gh -> exit 1 (fail-closed)"

# --- 21. unit wiring ------------------------------------------------------------
grep -q "bin/fleet-claim-release %i" "$unit" \
    || fail "pi-issue-failed@.service does not call bin/fleet-claim-release"
grep -q "bin/fleet-silent-pr-close-check" "$unit" \
    || fail "pi-issue-failed@.service does not run the silent-close check"
art_line="$(grep '^ExecStopPost=.*--require-artifact' "$worker_unit")"
[ -n "$art_line" ] || fail "pi-issue@.service has no --require-artifact ExecStopPost"
[ "${#art_line}" -lt 400 ] \
    || fail "artifact ExecStopPost is ${#art_line} chars — the no-glue bound is 400"
grep -q "fleet-claim-release %i --require-artifact" "$worker_unit" \
    || fail "pi-issue@.service does not pass --require-artifact to the release script"
ok "unit calls the guarded release, the detector, and the artifact check"

echo "PASS: fleet-claim-release"
