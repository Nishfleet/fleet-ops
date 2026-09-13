#!/usr/bin/env bash
# deploy-fault-gate.sh — shared deploy-fault issue class + green-run proof.
# fleet-ops#5785. Sourced by bin/fleet-merged-pr-close (close-time gate) and
# bin/lifecycle-label-sweep (deploy-fault labelling + closed-issue reopen
# pass). Not a service, not a timer — a library.
#
# CLASS: an issue is deploy-fault when it is labelled `deploy-fault` OR its
# body cites a failed production-deploy run — the `Deploy production`
# workflow (0509's deploy-production.yml; other product repos default to the
# same workflow name until DEPLOY_FAULT_WORKFLOWS declares otherwise).
#
# PROOF: a green (conclusion=success) run of the repo's production-deploy
# workflow whose head SHA CONTAINS the fix — i.e. the merge commit of the
# issue's delivery PR (claim/issue-<N> head branch or an explicit
# Closes/Fixes/Resolves trailer) is an ancestor of, or equal to, the run's
# headSha. When no delivery SHA is resolvable (human close, no merged PR),
# a green run created at-or-after the issue's closedAt is the fallback
# evidence. Proof may come from a run URL cited in the issue's comments or
# from the workflow run list itself: what makes a close legal is the green
# run existing, not the comment's formatting.
#
# Failure discipline: the gh calls below are evidence fetches. A fetch
# failure while proof is still absent is NOT "no proof" — it is "cannot
# check" (rc 2 from deploy_fault_has_proof), and the callers skip the
# reopen/close for that tick rather than act on a blip.
#
# Results pass through globals, not stdout, because $() substitution drops
# DF_CHECK_FAILED:
#   DF_FIX_SHAS       newline-separated delivery merge SHAs
#   DF_PROOF_URL      the qualifying green run URL when proof exists
#   DF_CHECK_FAILED   1 when a needed gh call failed this check
#
# Environment seams (tests override):
#   GH                      gh binary (inherited from the caller)
#   DEPLOY_FAULT_WORKFLOWS  path to a JSON {"<repo-short>": "<workflow name>"}
#                           overlay; absent entries fall back to
#                           "Deploy production"
#   DEPLOY_FAULT_RUN_LIMIT  how many recent green runs to inspect (default 10)

DF_ISSUE_NR_RE='(^|[^0-9A-Za-z])([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?)?#%s([^0-9A-Za-z]|$)'
# GitHub's closing-keyword family — same grammar as trailer_delivery() in
# bin/fleet-merged-pr-close (fleet-ops#3231): Closes|Fixes|Resolves (+ed/s
# forms) followed by whitespace and an exact-number, optionally
# repo-prefixed issue reference.
DF_TRAILER_RE='(^|[^0-9A-Za-z])(Clos(es?|ed)|Fix(es|ed)?|Resolv(es?|ed))[[:space:]]+([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?)?#%s([^0-9A-Za-z]|$)'

# Marker every gate/reopen comment carries. Dedup + audit anchor.
DEPLOY_FAULT_MARKER="deploy-fault-gate (fleet-ops#5785)"

DF_FIX_SHAS=""
DF_PROOF_URL=""
DF_CHECK_FAILED=0

_df_gh() {
    "${GH:-gh}" "$@"
}

# deploy_fault_workflow REPO — production-deploy workflow name for REPO
# (owner/name or bare name). DEPLOY_FAULT_WORKFLOWS JSON overlay wins; the
# fleet convention "Deploy production" is the default.
deploy_fault_workflow() {
    local repo="$1" short="${1##*/}" wf=""
    if [ -n "${DEPLOY_FAULT_WORKFLOWS:-}" ] && [ -f "${DEPLOY_FAULT_WORKFLOWS:-}" ]; then
        wf=$(jq -r --arg r "$short" '.[$r] // ""' "$DEPLOY_FAULT_WORKFLOWS" 2>/dev/null)
    fi
    printf '%s' "${wf:-Deploy production}"
}

# deploy_fault_body_cites_failed_run BODY — does BODY cite a failed
# production-deploy run? A `deploy-production`/`Deploy production` reference
# paired with failure wording. Deliberately not a lone run URL — a green
# deploy run cited in a success report is not a fault.
deploy_fault_body_cites_failed_run() {
    local body="$1"
    printf '%s' "$body" | grep -Eiq 'deploy[-_ .]?production|production deploy' \
        && printf '%s' "$body" | grep -Eiq 'fail|non-green|red run|rolled back|rollback|auto-revert'
}

# deploy_fault_is_issue LABELS_JSON BODY — is this issue in the deploy-fault
# class (labelled deploy-fault, or body cites a failed production run)?
deploy_fault_is_issue() {
    local labels_json="$1" body="$2"
    if printf '%s' "$labels_json" \
        | jq -e '.[] | select(.name=="deploy-fault")' >/dev/null 2>&1; then
        return 0
    fi
    deploy_fault_body_cites_failed_run "$body"
}

# deploy_fault_fix_shas REPO NUM — resolve the issue's delivery merge SHAs
# into DF_FIX_SHAS (newline-separated). Sources: merged PRs on the
# claim/issue-<NUM> head branch (the worker delivery), then merged PRs whose
# body carries an explicit Closes/Fixes/Resolves trailer for NUM. Empty
# DF_FIX_SHAS = no resolvable delivery (or a gh blip — DF_CHECK_FAILED).
deploy_fault_fix_shas() {
    local repo="$1" num="$2" re prs out pbody psha
    DF_FIX_SHAS=""
    out=$(_df_gh pr list -R "$repo" --head "claim/issue-${num}" --state merged \
        --json mergeCommit 2>/dev/null) || DF_CHECK_FAILED=1
    DF_FIX_SHAS=$(printf '%s' "${out:-[]}" \
        | jq -r '.[].mergeCommit.oid // empty' 2>/dev/null)
    prs=$(_df_gh pr list -R "$repo" --state merged --limit 300 \
        --json body,mergeCommit 2>/dev/null) || DF_CHECK_FAILED=1
    re=$(printf "$DF_TRAILER_RE" "$num")
    while IFS=$'\t' read -r pbody psha; do
        [ -n "$psha" ] || continue
        if printf '%s' "$pbody" | grep -Eiq "$re"; then
            DF_FIX_SHAS="${DF_FIX_SHAS}${DF_FIX_SHAS:+$'\n'}${psha}"
        fi
    done < <(printf '%s' "${prs:-[]}" \
        | jq -r '.[] | [(.body // ""), (.mergeCommit.oid // "")] | @tsv' 2>/dev/null)
    return 0
}

# deploy_fault_sha_contained REPO FIX_SHA RUN_SHA — is FIX_SHA an ancestor
# of (or equal to) RUN_SHA? `gh api compare` reports the head's relation to
# the base: ahead/identical = the run contains the fix.
deploy_fault_sha_contained() {
    local repo="$1" fix="$2" run="$3" st
    [ -n "$fix" ] && [ -n "$run" ] || return 1
    [ "$fix" = "$run" ] && return 0
    local resp
    resp=$(_df_gh api "repos/${repo}/compare/${fix}...${run}" 2>/dev/null) \
        || { DF_CHECK_FAILED=1; return 1; }
    st=$(printf '%s' "$resp" | jq -r '.status // ""' 2>/dev/null)
    case "$st" in
        ahead|identical) return 0 ;;
        *) return 1 ;;
    esac
}

# _deploy_fault_run_qualifies REPO RUN_SHA RUN_CREATED FIX_SHAS SINCE —
# one candidate green run: contained-fix check when fix SHAs are known,
# createdAt >= SINCE otherwise.
_deploy_fault_run_qualifies() {
    local repo="$1" run_sha="$2" run_created="$3" fix_shas="$4" since="$5" f
    if [ -n "$fix_shas" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if deploy_fault_sha_contained "$repo" "$f" "$run_sha"; then
                return 0
            fi
        done <<< "$fix_shas"
        return 1
    fi
    [ -n "$since" ] && [ -n "$run_created" ] \
        && [[ ! "$run_created" < "$since" ]]
}

# deploy_fault_comment_proof REPO NUM FIX_SHAS SINCE — first comment-cited
# actions/runs URL that is a green production-deploy run qualifying under
# _deploy_fault_run_qualifies. rc 0 + DF_PROOF_URL set; rc 1 none found.
deploy_fault_comment_proof() {
    local repo="$1" num="$2" fix_shas="$3" since="$4" wf comments ids id row
    local conc wname sha created url
    wf=$(deploy_fault_workflow "$repo")
    comments=$(_df_gh issue view "$num" -R "$repo" --json comments 2>/dev/null) \
        || { DF_CHECK_FAILED=1; return 1; }
    ids=$(printf '%s' "$comments" \
        | jq -r '.comments[]?.body // empty' 2>/dev/null \
        | grep -Eo 'actions/runs/[0-9]+' | grep -Eo '[0-9]+$' | sort -u)
    [ -n "$ids" ] || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        row=$(_df_gh run view "$id" -R "$repo" \
            --json conclusion,workflowName,headSha,createdAt,url 2>/dev/null) \
            || { DF_CHECK_FAILED=1; continue; }
        conc=$(printf '%s' "$row" | jq -r '.conclusion // ""')
        wname=$(printf '%s' "$row" | jq -r '.workflowName // ""')
        [ "$conc" = "success" ] || continue
        [ "$wname" = "$wf" ] || continue
        sha=$(printf '%s' "$row" | jq -r '.headSha // ""')
        created=$(printf '%s' "$row" | jq -r '.createdAt // ""')
        url=$(printf '%s' "$row" | jq -r '.url // ""')
        [ -n "$url" ] || continue
        if _deploy_fault_run_qualifies "$repo" "$sha" "$created" "$fix_shas" "$since"; then
            DF_PROOF_URL="$url"
            return 0
        fi
    done <<< "$ids"
    return 1
}

# deploy_fault_find_proof REPO FIX_SHAS SINCE — run-list self-check: first
# recent green production-deploy run qualifying under
# _deploy_fault_run_qualifies. rc 0 + DF_PROOF_URL set; rc 1 none found.
deploy_fault_find_proof() {
    local repo="$1" fix_shas="$2" since="$3" wf rows lines sha created url
    wf=$(deploy_fault_workflow "$repo")
    rows=$(_df_gh run list -R "$repo" --workflow "$wf" --status success \
        --limit "${DEPLOY_FAULT_RUN_LIMIT:-10}" \
        --json databaseId,headSha,createdAt,url 2>/dev/null) \
        || { DF_CHECK_FAILED=1; return 1; }
    lines=$(printf '%s' "$rows" \
        | jq -r '.[] | [(.headSha // ""), (.createdAt // ""), (.url // "")] | @tsv' 2>/dev/null)
    while IFS=$'\t' read -r sha created url; do
        [ -n "$url" ] || continue
        if _deploy_fault_run_qualifies "$repo" "$sha" "$created" "$fix_shas" "$since"; then
            DF_PROOF_URL="$url"
            return 0
        fi
    done <<< "$lines"
    return 1
}

# deploy_fault_has_proof REPO NUM [SINCE] — is this issue's close proven by
# a green production-deploy run? rc 0 proven (DF_PROOF_URL set), rc 1
# unproven, rc 2 could-not-check (a needed gh call failed — callers must NOT
# act on rc 2).
deploy_fault_has_proof() {
    local repo="$1" num="$2" since="${3:-}"
    DF_CHECK_FAILED=0
    DF_PROOF_URL=""
    deploy_fault_fix_shas "$repo" "$num"
    deploy_fault_comment_proof "$repo" "$num" "$DF_FIX_SHAS" "$since" && return 0
    deploy_fault_find_proof "$repo" "$DF_FIX_SHAS" "$since" && return 0
    [ "$DF_CHECK_FAILED" = "1" ] && return 2
    return 1
}
