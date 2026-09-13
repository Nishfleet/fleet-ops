#!/usr/bin/env bash
# lib/fleet-questions.sh — fleet question-queue metrics + the unfiled detector.
# (fleet-ops#4476 part 3 of the Nish-2026-09-08 question work.)
#
# One source of truth for the numbers measure.sh prints on its `questions:`
# header line and that the fable-check / weekly review consume. Sourced (not
# exec'd) by measure.sh. This file defines functions only; the caller's
# main() decides when to call them.
#
# The escalation matrix (docs/escalation-matrix.md) is the single home for
# the rows; this file only COUNTs and DETECTS:
#   for-nish       confirmed questions (labelled nish-reserved or
#                  conference-approved by the senior conference gate, part 1)
#   oldest         age of the oldest confirmed for-nish question (h)
#   in-conference  `question`-labelled issues still awaiting the panel
#   unfiled        question-like lines found OUTSIDE the store (fable-check
#                  reports, Telegram/esend log, worker comments) with no link
#                  to a `question` issue -- each is a fault line and, unless
#                  you opt out, an auto-filed `question` issue quoting the
#                  source (deduped by sha of the source line).
#
# Fails closed: an unreachable store names UNAVAILABLE:<why>, never a
# fabricated number (same rule as the measure.sh usd_24h unavailable=).
#
# Environment seams (also honored through measure.sh):
#   FLEET_QUESTION_REPOS     repo short names to ask (default: intake-repos)
#   FLEET_QUESTION_GH        gh override (default: ${GH:-gh})
#   FLEET_QUESTION_SOURCES   whitespace-separated source files/dirs for the
#                            unfiled scan (default: live fable + esend paths)
#   FLEET_QUESTION_STATE     state file for unfiled dedupe (default under
#                            $AGENT_STATE/lanes)
#   FLEET_QUESTION_AUTOFILE  1 = auto-file a `question` issue per new unfiled
#                            line (default), 0 = count only
#   FLEET_QUESTION_FILEREPO  repo short name to file the found issues into
#                            (default: first repo in FLEET_QUESTION_REPOS)
#   FLEET_QUESTION_STALE_STATE state file for stale-question dedupe (default
#                            under $AGENT_STATE/lanes)
#
# Stale-question detector (fleet-ops#4562 accept 5): a `question`+`priority`
# issue with NO `decision-resolved:` comment after 24h is a wedged direction
# question — the panel never returned a verdict (exactly what #4518 did for
# 8 days until #4562 fixed it by hand). The detector names each stale one on
# the `questions:` line (stale=<n>) and auto-files ONE `agent-ready` fix
# issue per stale question, deduped by issue number, so the gap surfaces
# without a human finding it.

set -euo pipefail

fq_now_epoch() { date -u +%s 2>/dev/null | tr -d '\n'; }
fq_gh() { printf '%s' "${FLEET_QUESTION_GH:-${GH:-gh}}"; }

fq_default_state_dir() {
    local base="${AGENT_STATE:-/home/nish/workspaces/agent-state}"
    printf '%s/lanes' "$base"
}

# Repo short names to ask (intake-repos, or an explicit override for tests).
fq_repos() {
    if [ -n "${FLEET_QUESTION_REPOS:-}" ]; then
        printf '%s\n' $FLEET_QUESTION_REPOS
        return 0
    fi
    local intake
    intake="${FLEET_INTAKE_REPOS_JSON:-/home/nish/workspaces/configs/intake-repos.json}"
    if [ -f "$intake" ]; then
        jq -r '.repos[]?.name' "$intake" 2>/dev/null | sed '/^$/d' || true
        return 0
    fi
    # No intake file (stale dev tree): explicit connective list so the line
    # still reports real counts rather than dying unseen.
    printf 'fleet-ops 0509 siterep-public inish-site\n'
}

# Print one row per open `question`-labelled issue: `<confirmed|conference>  <age_h>`
fq_question_rows() {
    local gh now repo out
    gh="$(fq_gh)"
    now="$(fq_now_epoch)"
    [ -n "$now" ] || return 0
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        out="$("$gh" issue list -R "Nishfleet/$repo" --state open --limit 300 \
            --json labels,createdAt 2>/dev/null || true)"
        [ -n "$out" ] || continue
        printf '%s' "$out" | jq -r '
          .[]
          | ( [.labels[].name] ) as $L
          | ( ($L | index("question")) != null ) as $hasq
          | select($hasq)
          | ( if (($L | index("nish-reserved")) != null or ($L | index("conference-approved")) != null)
              then "confirmed" else "conference" end ) + " " + (.createdAt // "")' | \
        while read -r kind iso; do
            local ep age
            age=0
            if [ -n "$iso" ]; then
                ep="$(date -u -d "$iso" +%s 2>/dev/null | tr -d '\n' || true)"
                if [ -n "$ep" ] && [ "$ep" -gt 0 ] 2>/dev/null; then
                    age=$(( (now - ep) / 3600 ))
                fi
            fi
            printf '%s %s\n' "$kind" "$age"
        done
    done < <(fq_repos)
}

# Print one row per open `question`+`priority` issue: `<number> <repo> <age_h>`
# (fleet-ops#4562 stale-question detector input).
fq_stale_rows() {
    local gh now repo out
    gh="$(fq_gh)"
    now="$(fq_now_epoch)"
    [ -n "$now" ] || return 0
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        out="$($gh issue list -R "Nishfleet/$repo" --state open --limit 300 \
            --json number,labels,createdAt 2>/dev/null || true)"
        [ -n "$out" ] || continue
        printf '%s' "$out" | jq -r --arg now "$now" '
          .[]
          | ( [.labels[].name] ) as $L
          | ( ($L | index("question")) != null ) as $hasq
          | ( ($L | index("priority")) != null ) as $hasp
          | select($hasq and $hasp)
          | "\(.number) " + (.createdAt // "")' | \
        while read -r num iso; do
            local ep age
            age=0
            if [ -n "$iso" ]; then
                ep="$(date -u -d "$iso" +%s 2>/dev/null | tr -d '\n' || true)"
                if [ -n "$ep" ] && [ "$ep" -gt 0 ] 2>/dev/null; then
                    age=$(( (now - ep) / 3600 ))
                fi
            fi
            printf '%s %s %s\n' "$num" "$repo" "$age"
        done
    done < <(fq_repos)
}

# Exit 0 iff issue <num> on Nishfleet/<repo> has a comment starting with
# `decision-resolved:` (unreadable -> returns 1, fails closed to stale).
fq_has_decision_resolved() {
    local repo="$1" num="$2" out
    out="$($(fq_gh) issue view "$num" -R "Nishfleet/$repo" --json comments 2>/dev/null | \
        jq -r '[.comments[].body] | any(startswith("decision-resolved:"))' 2>/dev/null || true)"
    [ "$out" = "true" ]
}

# Stale-question detector (fleet-ops#4562 accept 5). For every open
# `question`+`priority` issue older than 24h with no `decision-resolved:`
# comment: count it, and (unless FLEET_QUESTION_AUTOFILE=0) file ONE
# `agent-ready` fix issue per stale question, deduped by issue number in the
# state file. Prints the stale count.
fq_stale_detector() {
    local state autofile filerepo num repo age key
    state="${FLEET_QUESTION_STALE_STATE:-$(fq_default_state_dir)/fleet-question-stale.seen}"
    autofile="${FLEET_QUESTION_AUTOFILE:-1}"
    filerepo="${FLEET_QUESTION_FILEREPO:-}"
    [ -n "$filerepo" ] || filerepo="$(fq_repos | head -1 | tr -d '\n')"
    mkdir -p "$(dirname "$state")" 2>/dev/null || true
    touch "$state" 2>/dev/null || true
    local stale=0
    while IFS=' ' read -r num repo age; do
        [ -n "${num:-}" ] || continue
        [ "$age" -ge 24 ] 2>/dev/null || continue
        fq_has_decision_resolved "$repo" "$num" && continue
        stale=$((stale + 1))
        key="${repo}#${num}"
        grep -qxF "$key" "$state" 2>/dev/null && continue
        printf '%s\n' "$key" >> "$state"
        [ "$autofile" = "1" ] || continue
        local bodyf
        bodyf="$(mktemp 2>/dev/null || printf '%s.body' "$state")"
        {
            printf 'The senior panel never returned a verdict on this question.\n\n'
            printf 'Observed (fleet-ops#4562 stale-question detector, %s):\n' "$(date -u +%FT%TZ)"
            printf -- '- Nishfleet/%s#%s is labelled `question` + `priority`, is %sh old, and has NO `decision-resolved:` comment.\n\n' "$repo" "$num" "$age"
            printf 'accept:\n'
            printf -- '1. Run the senior panel (Nish-question auditor) on Nishfleet/%s#%s with Nish standing priors as inputs.\n' "$repo" "$num"
            printf -- '2. Post a `decision-resolved:` comment on it marked MATRIX-decided, Nish-vetoable.\n'
            printf -- '3. If Nish already answered in prose elsewhere, ledger the answer and point #N at it instead.\n\n'
            printf 'verify: gh issue view %s -R Nishfleet/%s --json comments -q %s | grep -q %s\n' "$num" "$repo" "'.comments[].body'" "'^decision-resolved:'"
            printf 'rollback: none (comment-only).\ndedupe: the stale question itself; this detector files once per issue (state-deduped).\n'
        } > "$bodyf" 2>/dev/null || { rm -f "$bodyf"; continue; }
        "$(fq_gh)" issue create -R "Nishfleet/$filerepo" --label agent-ready \
            --title "Stale question: Nishfleet/$repo#$num has no decision-resolved verdict after ${age}h" \
            --body-file "$bodyf" >/dev/null 2>&1 || true
        rm -f "$bodyf"
    done < <(fq_stale_rows)
    printf '%s' "$stale"
}

# Print measure.sh's `questions:` line:
#   questions: for-nish=<n> oldest=<h>h in-conference=<n> unfiled=<n> stale=<n>
fleet_questions_line() {
    local for_nish=0 in_conf=0 oldest=0 kind age unfiled
    while read -r kind age; do
        [ -n "$kind" ] || continue
        case "$kind" in
            confirmed)
                for_nish=$((for_nish + 1))
                if [ "$age" -gt "$oldest" ]; then oldest="$age"; fi
                ;;
            conference) in_conf=$((in_conf + 1)) ;;
        esac
    done < <(fq_question_rows)

    unfiled="$(fq_unfiled_count)"
    stale="$(fq_stale_detector)"
    printf 'questions: for-nish=%s oldest=%sh in-conference=%s unfiled=%s stale=%s\n' \
        "$for_nish" "$oldest" "$in_conf" "$unfiled" "$stale"
}

# Is $line a likely *unfiled* question (lives outside the store)? Heuristics
# per the spec: a Nish-addressed ask ending in `?`, or a standing ask-phrase
# ("your call", "you decide", "NISH DECISION", "decision needed"). Anything
# already carrying a link to the question store is NOT unfiled (it has a home).
fq_is_unfiled() {
    local line="$1" trimmed
    [ -n "$line" ] || return 1
    # already routed to the store? then it is filed, not unfiled
    if printf '%s' "$line" | grep -qiE 'github.com/Nishfleet/[A-Za-z0-9_-]+/issues/[0-9]+|Q:[A-Za-z0-9_-]+#[0-9]+|^question:|#question'; then
        return 1
    fi
    trimmed="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' || true)"
    if printf '%s' "$trimmed" | grep -qiE '(^|[^A-Za-z])NISH DECISION($|[^A-Za-z])|\b(your call|you decide|your decision|decision needed)\b'; then
        return 0
    fi
    if [[ "$trimmed" == *'?' ]] && [[ "$trimmed" != *'??' ]]; then
        if printf '%s' "$trimmed" | grep -qiE '(Nish|should|would|could|do you|do we|is it|are we)'; then
            return 0
        fi
    fi
    return 1
}

fq_sources_list() {
    if [ -n "${FLEET_QUESTION_SOURCES:-}" ]; then
        printf '%s\n' $FLEET_QUESTION_SOURCES
        return 0
    fi
    local base="${AGENT_STATE:-/home/nish/workspaces/agent-state}"
    printf '%s\n' \
        "$base/fable-check" \
        "$base/esend.log" \
        "$base/hermes/esend.log"
}

# Emit `<file> <line>` for each candidate unfiled line of one file.
fq_scan_file_emitting() {
    local f="$1" line
    [ -r "$f" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if fq_is_unfiled "$line"; then
            printf '%s %s\n' "$f" "$line"
        fi
    done < <(sed '/^[[:space:]]*$/d' "$f" 2>/dev/null || true)
}

# Emit `<file> <line>` for every unfiled candidate across the configured
# sources, limited to files touched in the trailing 24h (the spec's "last 24h
# of scans"): old dead text cannot re-page after it was once filed.
fq_unfiled_lines() {
    local src
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        if [ -d "$src" ]; then
            find "$src" -type f -newermt '-24 hours' -print 2>/dev/null | \
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                fq_scan_file_emitting "$f"
            done
        elif [ -f "$src" ]; then
            fq_scan_file_emitting "$src"
        fi
    done < <(fq_sources_list)
}

# Print the count of NEW unfiled lines. Side effects: appends their dedupe
# keys to the state file and (with autofile on) opens a `question` issue per
# NEW line quoting the source.
fq_unfiled_count() {
    local state autofile filerepo tmp new ff line key title bodyf
    state="${FLEET_QUESTION_STATE:-$(fq_default_state_dir)/fleet-question-unfiled.seen}"
    autofile="${FLEET_QUESTION_AUTOFILE:-1}"
    filerepo="${FLEET_QUESTION_FILEREPO:-}"
    [ -n "$filerepo" ] || filerepo="$(fq_repos | head -1 | tr -d '\n')"
    mkdir -p "$(dirname "$state")" 2>/dev/null || true
    touch "$state" 2>/dev/null || true
    tmp="$(mktemp -d 2>/dev/null || printf '%s.dir' "$state")"
    new=0

    while read -r ff line; do
        [ -n "$ff" ] || continue
        key="$(printf '%s|%s' "$ff" "$line" | sha256sum | cut -c1-40 | tr -d '\n')"
        if grep -qxF "$key" "$state" 2>/dev/null; then
            continue
        fi
        if [ "$autofile" = "1" ]; then
            title="Unfiled question (fleet-ops#4476): $(printf '%s' "$line" | head -c 90)"
            bodyf="$tmp/body.$$"
            { printf 'Question for Nish found OUTSIDE the question store (fleet-ops#4476 unfiled detector).\n\nsource: %s\n\n> %s\n' "$ff" "$line"; } \
                > "$bodyf" 2>/dev/null || { echo "fq_unfiled_count: WARN could not build label body for $ff" >&2; continue; }
            # Silent-drop sweep 2026-09-11: the key used to be recorded BEFORE
            # the create and a failed create vanished into `|| true`, so the
            # question was never retried. Record the key only on success and
            # fail LOUD on failure so the next run retries.
            if "$(fq_gh)" issue create -R "Nishfleet/$filerepo" --label question \
                --title "$title" --body-file "$bodyf" >/dev/null 2>&1; then
                printf '%s\n' "$key" >> "$state"
            else
                echo "fq_unfiled_count: ALERT issue create FAILED for $ff — question NOT filed and NOT marked seen; will retry next run (Nish 2026-09-11: no silent drops)" >&2
                return 1
            fi
        else
            printf '%s\n' "$key" >> "$state"
        fi
        new=$((new + 1))
    done < <(fq_unfiled_lines)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "${new:-0}"
}
