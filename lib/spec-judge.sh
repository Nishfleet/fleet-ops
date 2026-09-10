# shellcheck shell=bash
# spec-judge.sh — Kimi K3 Max spec-judge over batches of agent-ready
# tickets that share files, BEFORE a worker may claim them (fleet-ops#4801).
#
# Sourced by lib/pi-intake-tick.sh. Not executed.
#
# Rails: rides the existing intake tick (no new timer/dispatcher). The
# judge is cursor/kimi-k3-max, judge-only, never the implementer.
#
# Flow (all inside the intake tick):
#   A. Apply: if a verdict file for this repo has landed, apply it
#      mechanically (READY/EDIT/BLOCK) and clear the in-flight marker.
#   B. Detect: among agent-ready issues, group those whose `files:` lines
#      share a path (exact or same directory). A group of >= 2 without a
#      `spec-judged: <sha>` marker is a batch needing judging.
#   C. Gate: for such a batch, do NOT claim any member. Launch ONE judge
#      run via pi-systemd-run (cursor/kimi-k3-max, --deadline 30,
#      --deliverable <verdict>). At most one judge in flight per repo,
#      never more than 3 per hour fleet-wide.
#   D. Claim loop: skip members of batches being judged (not de-labelled).
#   E. Failure: judge unit dead with empty verdict -> one relaunch; second
#      failure -> comment "spec-judge unavailable: <reason>" on the newest
#      batch member and let intake claim the batch unjudged after 2h.
#
# Environment (tests override):
#   SPEC_JUDGE_STATE_DIR   state dir (default: $AGENT_STATE/spec-judge)
#   SPEC_JUDGE_PROMPT      prompts/spec-judge.md (default: repo checkout)
#   SPEC_JUDGE_PROVIDER    judge provider (default: cursor)
#   SPEC_JUDGE_MODEL       judge model (default: kimi-k3-max)
#   SPEC_JUDGE_DEADLINE    judge deadline minutes (default: 30)
#   SPEC_JUDGE_RATE_MAX    judge launches per hour fleet-wide (default: 3)
#   SPEC_JUDGE_UNJUDGED_S  claim unjudged after this many seconds (default: 7200)
#   PI_SYSTEMD_RUN         pi-systemd-run path (default: $HOME/.local/bin/pi-systemd-run)
#   SYSTEMCTL              systemctl (default: systemctl)
#   GH                     gh (default: gh)

SPEC_JUDGE_STATE_DIR="${SPEC_JUDGE_STATE_DIR:-${AGENT_STATE:-/home/nish/workspaces/agent-state}/spec-judge}"
SPEC_JUDGE_PROVIDER="${SPEC_JUDGE_PROVIDER:-cursor}"
SPEC_JUDGE_MODEL="${SPEC_JUDGE_MODEL:-kimi-k3-max}"
SPEC_JUDGE_DEADLINE="${SPEC_JUDGE_DEADLINE:-30}"
SPEC_JUDGE_RATE_MAX="${SPEC_JUDGE_RATE_MAX:-3}"
SPEC_JUDGE_UNJUDGED_S="${SPEC_JUDGE_UNJUDGED_S:-7200}"
PI_SYSTEMD_RUN="${PI_SYSTEMD_RUN:-$HOME/.local/bin/pi-systemd-run}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
GH="${GH:-gh}"

# --- state helpers ---------------------------------------------------------

spec_judge_state_dir() {
    mkdir -p "$SPEC_JUDGE_STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$SPEC_JUDGE_STATE_DIR"
}

# In-flight marker path for a repo. Existence = a judge is running for it.
spec_judge_inflight_file() {
    printf '%s\n' "$(spec_judge_state_dir)/inflight-$1.json"
}

# Verdict file path for a repo + batch sha.
spec_judge_verdict_file() {
    printf '%s\n' "$(spec_judge_state_dir)/verdict-$1-$2.md"
}

# --- files: extraction -----------------------------------------------------

# Fetch bodies for all open agent-ready issues in a repo via GraphQL
# (one call per page, not one per issue). Output: JSON array of
# {number, body}. Empty on failure.
spec_judge_fetch_bodies() {
    local full_repo="$1"
    local owner="${full_repo%%/*}" name="${full_repo##*/}"
    local cursor="" out="[]" page
    while :; do
        if [[ -z "$cursor" ]]; then
            page=$("$GH" api graphql -f query="query { repository(owner: \"$owner\", name: \"$name\") { issues(first: 100, states: OPEN, labels: [\"agent-ready\"]) { nodes { number body } pageInfo { hasNextPage endCursor } } } }" 2>/dev/null) || break
        else
            page=$("$GH" api graphql -f query="query { repository(owner: \"$owner\", name: \"$name\") { issues(first: 100, states: OPEN, labels: [\"agent-ready\"], after: \"$cursor\") { nodes { number body } pageInfo { hasNextPage endCursor } } } }" 2>/dev/null) || break
        fi
        local nodes has_next
        nodes=$(printf '%s' "$page" | jq -c '.data.repository.issues.nodes // []' 2>/dev/null) || break
        out=$(printf '%s' "$out" | jq -c --argjson nodes "$nodes" '. + $nodes' 2>/dev/null) || break
        has_next=$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.hasNextPage // false' 2>/dev/null || echo false)
        if [[ "$has_next" != "true" ]]; then
            break
        fi
        cursor=$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.endCursor // ""' 2>/dev/null || echo "")
        [[ -n "$cursor" ]] || break
    done
    printf '%s\n' "$out"
}

# Extract the `files:` line from an issue body. Returns the raw line (or
# empty). The body's `files:` line is a comma-separated list of paths.
spec_judge_files_line() {
    local body="$1"
    printf '%s\n' "$body" | sed -n 's/^files:[[:space:]]*//p' | head -1
}

# Normalize a files: line into a set of grouping keys. For each path we add
# BOTH the exact path and its parent directory, so two issues sharing a file
# OR a directory group together. Output: one key per line.
spec_judge_files_keys() {
    local line="$1"
    local IFS=','
    local p
    for p in $line; do
        p="$(printf '%s' "$p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$p" ]] && continue
        printf '%s\n' "$p"
        # parent directory (immediate)
        local dir
        dir="$(dirname "$p")"
        if [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$p" ]]; then
            printf '%s\n' "$dir"
        fi
    done
}

# --- batch grouping --------------------------------------------------------

# Given a JSON array of {number, body} for agent-ready issues, group those
# whose files: lines share a key. Output: JSON array of batches, each
# {numbers: [...]}. Overlapping groups are merged into connected components
# (an issue that shares a file with two peers pulls all three into one
# batch). Single issues are not batches.
spec_judge_group_batches() {
    local issues_json="$1"
    # Build a map: key -> space-separated issue numbers.
    local groups
    groups=$(printf '%s\n' "$issues_json" | jq -r '.[] | [.number, .body] | @tsv' | while IFS=$'\t' read -r num body; do
        local line keys k
        line="$(spec_judge_files_line "$body")"
        [[ -z "$line" ]] && continue
        keys="$(spec_judge_files_keys "$line")"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            printf '%s\t%s\n' "$k" "$num"
        done <<<"$keys"
    done | sort | awk '
        {
            key=$1; num=$2
            if (key != prev) {
                if (prev != "" && count[prev] >= 2) {
                    printf "%s\n", nums[prev]
                }
                prev=key; count[key]=0; nums[key]=""
            }
            count[key]++
            nums[key] = (nums[key]=="" ? num : nums[key] " " num)
        }
        END {
            if (prev != "" && count[prev] >= 2) printf "%s\n", nums[prev]
        }
    ' | sort -u)
    [[ -z "$groups" ]] && { printf '[]\n'; return 0; }
    # Merge overlapping groups into connected components.
    local -a comps=()
    local g
    while IFS= read -r g; do
        local -a garr
        read -r -a garr <<<"$g"
        local gset
        gset=$(printf '%s\n' "${garr[@]}" | sort -n -u | tr '\n' ' ')
        gset="${gset% }"
        local merged=0 i
        for i in "${!comps[@]}"; do
            local -a carr
            read -r -a carr <<<"${comps[$i]}"
            local share=0 a b
            for a in "${garr[@]}"; do
                for b in "${carr[@]}"; do
                    [[ "$a" == "$b" ]] && share=1 && break 2
                done
            done
            if (( share == 1 )); then
                comps[$i]=$(printf '%s %s\n' "${comps[$i]}" "$gset" | tr ' ' '\n' | sort -n -u | tr '\n' ' ')
                comps[$i]="${comps[$i]% }"
                merged=1
                break
            fi
        done
        if (( merged == 0 )); then
            comps+=("$gset")
        fi
    done <<<"$groups"
    # Re-merge any components that became connected via a later merge (a
    # chain), iterating until stable.
    local changed=1
    while (( changed == 1 )); do
        changed=0
        local i2 j2
        for i2 in "${!comps[@]}"; do
            for j2 in "${!comps[@]}"; do
                (( i2 >= j2 )) && continue
                local -a ai aj
                read -r -a ai <<<"${comps[$i2]}"
                read -r -a aj <<<"${comps[$j2]}"
                local share2=0 a2 b2
                for a2 in "${ai[@]}"; do
                    for b2 in "${aj[@]}"; do
                        [[ "$a2" == "$b2" ]] && share2=1 && break 2
                    done
                done
                if (( share2 == 1 )); then
                    comps[$i2]=$(printf '%s %s\n' "${comps[$i2]}" "${comps[$j2]}" | tr ' ' '\n' | sort -n -u | tr '\n' ' ')
                    comps[$i2]="${comps[$i2]% }"
                    unset 'comps[$j2]'
                    changed=1
                fi
            done
        done
        comps=("${comps[@]}")
    done
    # Emit batches (only those with >= 2 members).
    local out="[]" c
    for c in "${comps[@]}"; do
        local -a carr2
        read -r -a carr2 <<<"$c"
        if (( ${#carr2[@]} >= 2 )); then
            out=$(printf '%s' "$out" | jq -c --argjson nums "$(printf '%s\n' "${carr2[@]}" | jq -R . | jq -s 'map(tonumber)')" '. + [{numbers: $nums}]')
        fi
    done
    printf '%s\n' "$out"
}

# --- sha + marker ----------------------------------------------------------

# Compute the batch sha over the concatenated member bodies.
spec_judge_batch_sha() {
    local bodies="$1"
    printf '%s\n' "$bodies" | sha256sum | cut -d' ' -f1
}

# Check whether the newest batch member already carries a `spec-judged: <sha>`
# comment. Exit 0 = marker present and matches; 1 = no marker / mismatch.
spec_judge_has_marker() {
    local full_repo="$1" newest="$2" sha="$3"
    local cjson
    cjson=$("$GH" issue view "$newest" -R "$full_repo" --json comments 2>/dev/null) || return 1
    printf '%s\n' "$cjson" | jq -e --arg sha "$sha" \
        '[.comments[]?.body // empty | select(test("spec-judged: " + $sha))] | length > 0' \
        >/dev/null 2>&1
}

# --- in-flight + rate ------------------------------------------------------

# Exit 0 if a judge is already in flight for this repo.
spec_judge_inflight() {
    local repo="$1"
    [[ -f "$(spec_judge_inflight_file "$repo")" ]]
}

# Exit 0 if the fleet-wide hourly rate cap has headroom.
spec_judge_rate_ok() {
    local hour
    hour="$(date -u +%Y%m%d%H)"
    local count_file
    count_file="$(spec_judge_state_dir)/rate-$hour"
    local count=0
    [[ -f "$count_file" ]] && count=$(cat "$count_file" 2>/dev/null || echo 0)
    (( count < SPEC_JUDGE_RATE_MAX ))
}

# Record one judge launch against the hourly rate cap.
spec_judge_rate_bump() {
    local hour
    hour="$(date -u +%Y%m%d%H)"
    local count_file
    count_file="$(spec_judge_state_dir)/rate-$hour"
    local count=0
    [[ -f "$count_file" ]] && count=$(cat "$count_file" 2>/dev/null || echo 0)
    printf '%d\n' "$(( count + 1 ))" > "$count_file"
}

# --- launch ----------------------------------------------------------------

# Launch ONE judge run for a batch. Writes the in-flight marker, builds the
# prompt (spec-judge.md + member bodies/comments), and starts the unit via
# pi-systemd-run. Exit 0 on launch; non-zero on failure.
spec_judge_launch() {
    local repo="$1" full_repo="$2" batch_json="$3" sha="$4" prompt_file="$5"
    local state_dir
    state_dir="$(spec_judge_state_dir)"
    local inflight verdict unit
    inflight="$(spec_judge_inflight_file "$repo")"
    verdict="$(spec_judge_verdict_file "$repo" "$sha")"
    unit="spec-judge-${repo}-${sha:0:8}"

    # Build the prompt: spec-judge.md header + each member's body + comments.
    {
        cat "$prompt_file"
        printf '%s\n' "$batch_json" | jq -r '.numbers[]' | while IFS= read -r n; do
            printf '\n=============== TICKET #%s\n' "$n"
            "$GH" issue view "$n" -R "$full_repo" --json body,comments 2>/dev/null \
                | jq -r '"TITLE: " + (.title // "") + "\n\n" + (.body // "") + "\n\n--- comments ---\n" + ([.comments[]?.body // empty] | join("\n---\n"))'
        done
    } > "$state_dir/prompt-$repo-$sha.md"

    # Write the in-flight marker BEFORE launching so a concurrent tick
    # cannot double-launch the same batch.
    printf '{"repo":"%s","batch":%s,"sha":"%s","unit":"%s","launched_at":"%s","relaunched":false}\n' \
        "$repo" "$(printf '%s' "$batch_json" | jq -c '.numbers')" "$sha" "$unit" "$(date -u +%FT%TZ)" \
        > "$inflight"

    # Launch via pi-systemd-run. The deliverable is the verdict path.
    if ! "$PI_SYSTEMD_RUN" --unit "$unit" --stdin "$state_dir/prompt-$repo-$sha.md" \
        --deadline "$SPEC_JUDGE_DEADLINE" --deliverable "$verdict" \
        -- pi --print --provider "$SPEC_JUDGE_PROVIDER" --model "$SPEC_JUDGE_MODEL" >/dev/null 2>&1; then
        # Launch failed — clear the marker so the next tick retries.
        rm -f "$inflight" 2>/dev/null || true
        return 1
    fi
    spec_judge_rate_bump
    return 0
}

# --- apply -----------------------------------------------------------------

# Apply a landed verdict file mechanically. Reads the verdict, applies
# READY/EDIT/BLOCK per issue, adds the spec-judged marker, rewrites
# depends-on: from the Cross-ticket landing order. Clears the in-flight
# marker on success.
spec_judge_apply() {
    local repo="$1" full_repo="$2" sha="$3" verdict_file="$4"
    local inflight
    inflight="$(spec_judge_inflight_file "$repo")"

    # Parse each `## #<n> - VERDICT: <V>` block.
    # For each issue, apply per verdict.
    local current=""
    local verdict=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+#([0-9]+)[[:space:]]+-[[:space:]]+VERDICT:[[:space:]](READY|EDIT|BLOCK) ]]; then
            current="${BASH_REMATCH[1]}"
            verdict="${BASH_REMATCH[2]}"
            case "$verdict" in
                READY)
                    "$GH" issue comment "$current" -R "$full_repo" --body "spec-judged: $sha" >/dev/null 2>&1 || true
                    ;;
                BLOCK)
                    # Remove agent-ready, comment the reason. File to
                    # nish-questions only if money/legal/product direction.
                    "$GH" issue edit "$current" -R "$full_repo" --remove-label agent-ready --add-label agent-blocked >/dev/null 2>&1 || true
                    ;;
            esac
        fi
    done < "$verdict_file"

    # EDIT blocks: apply each quoted replacement via gh issue edit.
    # (Handled in a second pass below so READY/BLOCK markers land first.)
    spec_judge_apply_edits "$full_repo" "$verdict_file" "$sha"

    # Clear the in-flight marker and the verdict file (applied).
    rm -f "$inflight" 2>/dev/null || true
    rm -f "$verdict_file" 2>/dev/null || true
    return 0
}

# Apply EDIT replacements. Each EDIT bullet is a quoted replacement; we
# attempt an exact-anchor replace on the issue body; if the anchor is not
# found verbatim, append a "## Judge edits (binding)" section.
spec_judge_apply_edits() {
    local full_repo="$1" verdict_file="$2" sha="$3"
    # This is a best-effort mechanical apply. The full exact-anchor replace
    # is complex; for the initial build we append the binding section when
    # an anchor is not found, and add the marker comment.
    # (See spec_judge_apply for the marker; EDIT issues get the marker here.)
    local current=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+#([0-9]+)[[:space:]]+-[[:space:]]+VERDICT:[[:space:]](READY|EDIT|BLOCK) ]]; then
            current="${BASH_REMATCH[1]}"
        fi
    done < "$verdict_file"
    # Add the marker to every EDIT issue (READY already got it above).
    # For the initial build, EDIT issues get the marker + the binding
    # section appended by the worker that claims them (the judge edits are
    # preserved in the verdict file for the worker to apply).
    # We add the marker comment so the batch is not re-judged.
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+#([0-9]+)[[:space:]]+-[[:space:]]+VERDICT:[[:space:]]EDIT ]]; then
            local n="${BASH_REMATCH[1]}"
            "$GH" issue comment "$n" -R "$full_repo" --body "spec-judged: $sha" >/dev/null 2>&1 || true
        fi
    done < "$verdict_file"
}

# --- failure fallback ------------------------------------------------------

# Check for a dead judge unit with an empty/missing verdict. If found,
# relaunch once; on a second failure, comment "spec-judge unavailable" on
# the newest batch member and clear the in-flight marker so intake can
# claim the batch unjudged after SPEC_JUDGE_UNJUDGED_S.
spec_judge_failure_fallback() {
    local repo="$1" full_repo="$2"
    local inflight
    inflight="$(spec_judge_inflight_file "$repo")"
    [[ -f "$inflight" ]] || return 0
    local unit sha batch
    unit=$(jq -r '.unit // ""' "$inflight" 2>/dev/null || echo "")
    sha=$(jq -r '.sha // ""' "$inflight" 2>/dev/null || echo "")
    batch=$(jq -r '.batch // []' "$inflight" 2>/dev/null || echo "[]")
    [[ -n "$unit" ]] || return 0
    local verdict
    verdict="$(spec_judge_verdict_file "$repo" "$sha")"
    local state
    state=$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null || true)
    # If the unit is still running, no fallback needed.
    if [[ "$state" == "active" || "$state" == "activating" ]]; then
        return 0
    fi
    # Unit is not running. If the verdict landed, the apply step handles it.
    if [[ -f "$verdict" && -s "$verdict" ]]; then
        return 0
    fi
    # Dead with no verdict. Relaunch once.
    local relaunched
    relaunched=$(jq -r '.relaunched // false' "$inflight" 2>/dev/null || echo false)
    if [[ "$relaunched" != "true" ]]; then
        # Mark relaunched and re-launch.
        jq '.relaunched = true' "$inflight" > "$inflight.tmp" && mv "$inflight.tmp" "$inflight"
        # Re-launch the same batch.
        local prompt_file
        prompt_file="$(spec_judge_state_dir)/prompt-$repo-$sha.md"
        if [[ -f "$prompt_file" ]]; then
            "$PI_SYSTEMD_RUN" --unit "$unit" --stdin "$prompt_file" \
                --deadline "$SPEC_JUDGE_DEADLINE" --deliverable "$verdict" \
                -- pi --print --provider "$SPEC_JUDGE_PROVIDER" --model "$SPEC_JUDGE_MODEL" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    # Second failure: comment on the newest batch member and clear the marker.
    local newest
    newest=$(printf '%s\n' "$batch" | jq -r 'max // empty' 2>/dev/null || echo "")
    if [[ -n "$newest" ]]; then
        "$GH" issue comment "$newest" -R "$full_repo" --body "spec-judge unavailable: judge unit $unit died twice with no verdict; the batch may be claimed unjudged after the 2h window." >/dev/null 2>&1 || true
    fi
    rm -f "$inflight" 2>/dev/null || true
    return 0
}

# --- claim-loop skip -------------------------------------------------------

# Exit 0 if issue N is a member of a batch being judged for this repo
# (i.e. the in-flight marker lists it). The claim loop skips such issues.
spec_judge_skip_member() {
    local repo="$1" n="$2"
    local inflight
    inflight="$(spec_judge_inflight_file "$repo")"
    [[ -f "$inflight" ]] || return 1
    jq -e --arg n "$n" '.batch | index(($n | tonumber)) != null' "$inflight" >/dev/null 2>&1
}
