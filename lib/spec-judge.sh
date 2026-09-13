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
    mkdir -p "$SPEC_JUDGE_STATE_DIR" 2>/dev/null \
        || echo "ALERT spec-judge: mkdir state dir failed path=$SPEC_JUDGE_STATE_DIR — no spec-judge durable record can persist this tick (fleet-ops silent-drop)" >&2
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
    local -a parts
    IFS=',' read -ra parts <<< "$line"
    local p
    for p in "${parts[@]}"; do
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
            "$GH" issue view "$n" -R "$full_repo" --json title,body,comments 2>/dev/null \
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

# --- verdict parsing helpers ----------------------------------------------

# Match a `Replace "OLD" with "NEW"` clause in a bullet. Prints
# `OLD<TAB>NEW` (tab-separated) on stdout when matched, else nothing. OLD
# and NEW are the first two double-quoted spans after `Replace ` and
# ` with ` respectively. The judge's quoted spans use straight double
# quotes and contain no embedded double quotes (verified against the
# 2026-09-09 verdict), so a first-quote / next-quote split is safe.
spec_judge_parse_replace() {
    local bullet="$1"
    local rest="${bullet#*Replace }"
    [[ "$rest" == "$bullet" ]] && return 1   # no "Replace " in bullet
    [[ "$rest" == \"* ]] || return 1        # must start with a quote
    local old="${rest#\"}"
    old="${old%%\"*}"
    rest="${rest#*\"}"                       # past closing quote of OLD
    rest="${rest#* with }"                    # drop " with " prefix
    [[ "$rest" == \"* ]] || return 1
    local new="${rest#\"}"
    new="${new%%\"*}"
    [[ -n "$old" && -n "$new" ]] || return 1
    printf '%s\t%s\n' "$old" "$new"
}

# Extract the `## Cross-ticket` landing order from a verdict file as a
# space-separated list of issue numbers in order (e.g. "2181 2189 2193").
# Empty if no landing-order line is found.
spec_judge_landing_order() {
    local verdict_file="$1"
    local in_cross=0 line
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Cross-ticket ]]; then
            in_cross=1; continue
        fi
        (( in_cross == 1 )) || continue
        # Landing order line carries "->"-separated "#<n>" tokens.
        if [[ "$line" =~ Landing[[:space:]]+order ]] \
            || [[ "$line" =~ landing[[:space:]]+order ]]; then
            printf '%s\n' "$line" \
                | grep -oE '#[0-9]+' \
                | tr -d '#' \
                | tr '\n' ' '
            return 0
        fi
    done < "$verdict_file"
}

# --- apply -----------------------------------------------------------------

# Apply a landed verdict file mechanically. Reads the verdict, applies
# READY/EDIT/BLOCK per issue, adds the spec-judged marker, rewrites
# depends-on: from the Cross-ticket landing order. Clears the in-flight
# marker on success. Best-effort: every gh call is `|| true` so one bad
# issue does not abort the batch; the marker is added last so a partially
# applied EDIT is still marked judged (the binding section preserves the
# unapplied edits for the worker).
spec_judge_apply() {
    local repo="$1" full_repo="$2" sha="$3" verdict_file="$4"
    local inflight
    inflight="$(spec_judge_inflight_file "$repo")"

    # Landing order (space-separated issue numbers, in order).
    local order
    order="$(spec_judge_landing_order "$verdict_file")"

    # Walk the verdict once, collecting (number, verdict, bullets) blocks
    # into parallel arrays, then dispatch each after the loop (a nested
    # function is not valid bash, so we collect-then-process).
    local -a b_num=() b_verdict=() b_bullets=()
    local current="" verdict="" bullets=""
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Cross-ticket ]]; then
            break
        fi
        if [[ "$line" =~ ^##[[:space:]]+#([0-9]+)[[:space:]]+-[[:space:]]+VERDICT:[[:space:]]+(READY|EDIT|BLOCK) ]]; then
            if [[ -n "$current" ]]; then
                b_num+=("$current"); b_verdict+=("$verdict"); b_bullets+=("$bullets")
            fi
            current="${BASH_REMATCH[1]}"
            verdict="${BASH_REMATCH[2]}"
            bullets=""
            continue
        fi
        [[ -n "$current" ]] && bullets+="$line"$'\n'
    done < "$verdict_file"
    if [[ -n "$current" ]]; then
        b_num+=("$current"); b_verdict+=("$verdict"); b_bullets+=("$bullets")
    fi

    local i
    for (( i=0; i<${#b_num[@]}; i++ )); do
        case "${b_verdict[$i]}" in
            READY)
                "$GH" issue comment "${b_num[$i]}" -R "$full_repo" \
                    --body "spec-judged: $sha" >/dev/null 2>&1 \
                    || echo "ALERT spec-judge: gh issue comment rc=$? work=ready-marker issue=${b_num[$i]} repo=$full_repo — marker dropped; ticket re-judged next tick (fleet-ops silent-drop)" >&2
                ;;
            EDIT)
                spec_judge_apply_edit_issue \
                    "$full_repo" "${b_num[$i]}" "$sha" "${b_bullets[$i]}" "$order"
                ;;
            BLOCK)
                spec_judge_apply_block_issue \
                    "$full_repo" "${b_num[$i]}" "$sha" "${b_bullets[$i]}"
                ;;
        esac
    done

    # Clear the in-flight marker and the verdict file (applied).
    rm -f "$inflight" 2>/dev/null || true
    rm -f "$verdict_file" 2>/dev/null || true
    return 0
}

# Apply one EDIT issue: exact-anchor replace each `Replace "OLD" with
# "NEW"` bullet; bullets whose anchor is not found (and any non-Replace
# bullets) go into an appended `## Judge edits (binding)` section. Then
# rewrite a `depends-on: none` line to the landing-order predecessor.
# The marker comment is added last.
spec_judge_apply_edit_issue() {
    local full_repo="$1" n="$2" sha="$3" bullets="$4" order="$5"
    local -a dep_nums=()
    local needs_orch=0 none_re='^[[:space:][:punct:]]*none([^[:alnum:]_]|$)'

    # Fetch the current body.
    local body
    body=$("$GH" issue view "$n" -R "$full_repo" --json body 2>/dev/null \
        | jq -r '.body // ""' 2>/dev/null) || body=""
    [[ -n "$body" ]] || { "$GH" issue comment "$n" -R "$full_repo" --body "spec-judged: $sha" >/dev/null 2>&1 || echo "ALERT spec-judge: gh issue comment rc=$? work=judged-marker issue=$n repo=$full_repo — marker dropped; ticket re-judged next tick (fleet-ops silent-drop)" >&2; return 0; }

    local binding="" applied=0
    local bullet
    while IFS= read -r bullet; do
        [[ -z "$bullet" ]] && continue
        local pair
        pair="$(spec_judge_parse_replace "$bullet")" || { binding+="$bullet"$'\n'; continue; }
        local old="${pair%%$'\t'*}" new="${pair#*$'\t'}"
        if [[ "$body" == *"$old"* ]]; then
            body="${body/"$old"/"$new"}"
            applied=1
        else
            binding+="$bullet"$'\n'
        fi
    done <<<"$bullets"

    # fleet-ops#5107: a judge-added dependency left in a binding bullet must
    # reach the structured depends-on: line — intake keys on the depends-on:
    # token, and a bullet like "add `depends-on: #2359`" left the structured
    # line at `none` so the ticket was claimed anyway. Per bullet, extract
    # every #<n> that appears after a depends-on: token (unanchored — the
    # token usually sits mid-bullet in backticks):
    #   - refs found -> rewrite `depends-on: none` to carry them (same
    #     conservative rule as the landing-order rewrite below: replace
    #     `none` only, never overwrite a real value). Runs BEFORE the
    #     landing-order rewrite so an explicit judge dep wins over the
    #     inferred predecessor.
    #   - a depends-on: fragment naming no #<n> (a lens ref like "the R1
    #     ticket", judged on the last token's value so a quoted
    #     `depends-on: none` mention earlier in the bullet does not mask
    #     it) -> no number exists to write; the issue parks on
    #     `blocked-on: orchestrator` below instead of being claimed.
    if [[ -n "$binding" ]]; then
        local bline tail_frag last_frag had_ref dref
        while IFS= read -r bline; do
            [[ "$bline" == *depends-on:* ]] || continue
            tail_frag="${bline#*depends-on:}"
            last_frag="${bline##*depends-on:}"
            had_ref=0
            while IFS= read -r dref; do
                [[ -n "$dref" ]] || continue
                dep_nums+=("${dref#\#}")
                had_ref=1
            done < <(printf '%s\n' "$tail_frag" | grep -oE '#[0-9]+' || true)
            if (( had_ref == 0 )) && [[ ! "$last_frag" =~ $none_re ]]; then
                needs_orch=1
            fi
        done <<<"$binding"
    fi
    if (( ${#dep_nums[@]} > 0 )) \
        && [[ "$body" =~ (^|$'\n')depends-on:[[:space:]]*none[[:space:]]*($|$'\n') ]]; then
        local dep_list="" dn
        for dn in $(printf '%s\n' "${dep_nums[@]}" | sort -un); do
            dep_list+="${dep_list:+, }#${dn}"
        done
        body="$(printf '%s\n' "$body" | sed -E "s/^depends-on:[[:space:]]*none[[:space:]]*\$/depends-on: ${dep_list}/")"
        applied=1
    fi

    # Rewrite depends-on: none -> depends-on: #<predecessor> from the
    # landing order (conservative: never overwrite a real depends-on, which
    # may carry a proof-gate the landing order does not capture).
    if [[ -n "$order" ]]; then
        local -a oarr
        read -r -a oarr <<<"$order"
        local idx pred=""
        for (( idx=0; idx<${#oarr[@]}; idx++ )); do
            if [[ "${oarr[$idx]}" == "$n" ]] && (( idx > 0 )); then
                pred="${oarr[$((idx-1))]}"; break
            fi
        done
        if [[ -n "$pred" ]] \
            && [[ "$body" =~ (^|$'\n')depends-on:[[:space:]]*none[[:space:]]*($|$'\n') ]]; then
            body="$(printf '%s\n' "$body" | sed -E "s/^depends-on:[[:space:]]*none[[:space:]]*\$/depends-on: #${pred}/")"
            applied=1
        fi
    fi

    # Append the binding section if any edits could not be anchored.
    if [[ -n "$binding" ]]; then
        body+="$(printf '\n\n## Judge edits (binding)\n\n%s' "$binding")"
        applied=1

        # fleet-ops#5131: a binding `Absorbs #N` bullet declares a same-repo
        # ticket subsumed by THIS one. Park it in the same run so no second
        # worker is spawned for work that already landed.
        local _abs
        while IFS= read -r _abs; do
            [[ "$_abs" =~ ^[0-9]+$ ]] || continue
            [[ "$_abs" == "$n" ]] && continue
            if spec_judge_park_absorbed "$full_repo" "${full_repo#*/}" "$_abs" "$n"; then
                echo "spec-judge: parked absorbed issue #${_abs} (absorbed by #${n})" >&2
            fi
        done < <(spec_judge_absorbed_refs "$binding" "$full_repo" || true)
    fi

    # fleet-ops#5107: a binding dependency naming no #<n> cannot be written
    # into the structured line, so park the issue on the orchestrator sweep
    # instead of leaving it claimable: `blocked-on: orchestrator` is a
    # permanent live blocker for the intake blocked_filter, and the
    # needs-orchestrator label routes the issue into the decision drain
    # (fleet-ops#4260) which resolves the ref. Cheaper than resolving lens
    # refs to issue numbers at apply time — the verdict carries no
    # ref -> issue-number map.
    if (( needs_orch == 1 )); then
        body+=$'\n\nblocked-on: orchestrator'
        applied=1
        "$GH" issue edit "$n" -R "$full_repo" \
            --remove-label agent-ready \
            --add-label agent-blocked --add-label needs-orchestrator \
            >/dev/null 2>&1 \
            || echo "ALERT spec-judge: gh issue edit rc=$? work=needs-orchestrator-labels issue=$n repo=$full_repo — ticket stays agent-ready and may be claimed despite the judge's depends-on verdict (fleet-ops silent-drop)" >&2
    fi

    # Push the body back if anything changed.
    if (( applied == 1 )); then
        local tmp
        tmp=$(mktemp)
        printf '%s' "$body" > "$tmp"
        "$GH" issue edit "$n" -R "$full_repo" --body-file "$tmp" >/dev/null 2>&1 \
            || echo "ALERT spec-judge: gh issue edit rc=$? work=apply-edit-body issue=$n repo=$full_repo — judged body edit dropped; ticket keeps pre-edit text (fleet-ops silent-drop)" >&2
        rm -f "$tmp" 2>/dev/null || true
    fi

    "$GH" issue comment "$n" -R "$full_repo" --body "spec-judged: $sha" >/dev/null 2>&1 \
        || echo "ALERT spec-judge: gh issue comment rc=$? work=judged-marker issue=$n repo=$full_repo — marker dropped; ticket re-judged next tick (fleet-ops silent-drop)" >&2
}

# Apply one BLOCK issue: remove agent-ready, comment the reason (the
# bullets). If the reason names money/legal/product-direction (the
# blocked-reconcile NISH_REASON set), add `blocked-on: nish-decision` so
# the existing blocked-reconcile sweep routes it to Nish; otherwise leave
# it for the next judge pass. The marker comment is added so the batch is
# not re-judged while blocked.
spec_judge_apply_block_issue() {
    local full_repo="$1" n="$2" sha="$3" bullets="$4"
    "$GH" issue edit "$n" -R "$full_repo" \
        --remove-label agent-ready --add-label agent-blocked >/dev/null 2>&1 \
        || echo "ALERT spec-judge: gh issue edit rc=$? work=block-labels issue=$n repo=$full_repo — ticket stays agent-ready and may be claimed despite judge BLOCK (fleet-ops silent-drop)" >&2
    local body="spec-judged: $sha"$'\n\n'"spec-judge BLOCK reason:"$'\n\n'"$bullets"
    if printf '%s' "$bullets" | grep -qiE '\b(money|pay|price|pricing|billing|legal|brand|deletion|credentials?|secret|token|account[\s/-]*login|product[\s/-]*direction|customer[\s/-]*data|reserved)\b'; then
        body+=$'\n\nblocked-on: nish-decision'
    fi
    "$GH" issue comment "$n" -R "$full_repo" --body "$body" >/dev/null 2>&1 \
        || echo "ALERT spec-judge: gh issue comment rc=$? work=block-reason issue=$n repo=$full_repo — BLOCK reason notice dropped (fleet-ops silent-drop)" >&2
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
                -- pi --print --provider "$SPEC_JUDGE_PROVIDER" --model "$SPEC_JUDGE_MODEL" >/dev/null 2>&1 \
                || echo "ALERT spec-judge: pi-systemd-run relaunch rc=$? unit=$unit repo=$repo — retry never started; the relaunched flag is already set so next tick goes straight to failure-fallback (fleet-ops silent-drop)" >&2
        fi
        return 0
    fi
    # Second failure: durable record FIRST so the release survives a dropped
    # comment (fleet-ops#5438 — bin/fleet-decisions-ledger is a lint, not a
    # writer, and the vault decisions-ledger.md is a guarded shared file; the
    # spec-judge state dir is the durable sink this organ owns). Then the
    # comment, then clear the marker so intake can claim the batch unjudged
    # after SPEC_JUDGE_UNJUDGED_S.
    local newest record
    newest=$(printf '%s\n' "$batch" | jq -r 'max // empty' 2>/dev/null || echo "")
    record="$(spec_judge_state_dir)/unavailable-$repo-$sha.json"
    jq -nc --arg repo "$repo" --arg sha "$sha" --arg unit "$unit" \
        --argjson batch "$batch" --arg newest "$newest" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{repo:$repo, sha:$sha, unit:$unit, batch:$batch, newest_issue:($newest | tonumber? // null), at:$at, reason:"judge unit died twice with no verdict; batch claimable unjudged"}' \
        > "$record" 2>/dev/null \
        || echo "ALERT spec-judge: durable-record write failed path=$record — no trace of the unjudged release survives (fleet-ops silent-drop)" >&2
    if [[ -n "$newest" ]]; then
        "$GH" issue comment "$newest" -R "$full_repo" --body "spec-judge unavailable: judge unit $unit died twice with no verdict; the batch may be claimed unjudged after the 2h window." >/dev/null 2>&1 \
            || echo "ALERT spec-judge: gh issue comment rc=$? work=failure-fallback issue=$newest repo=$full_repo — 'spec-judge unavailable' notice dropped; durable record at $record; batch claims unjudged after ${SPEC_JUDGE_UNJUDGED_S}s (fleet-ops silent-drop)" >&2
    fi
    rm -f "$inflight" 2>/dev/null || true
    return 0
}

# --- absorbed tickets (fleet-ops#5131) --------------------------------------
#
# A binding judge edit can declare a same-repo ticket subsumed by the one it
# edits (`- Absorbs #2387.`). Nothing used to consume that word: the absorbed
# ticket kept agent-ready, got claimed, and the worker burned its slot proving
# work that already landed (live: 0509#2379 absorbed #2387, PR #2681 merged,
# #2387 was claimed 4m24s later).
#
# Parked the cheap way — option (a) in the issue: agent-blocked +
# `needs-orchestrator` added, agent-ready removed, and a live
# `blocked-on: orchestrator` line. That line is load-bearing twice over —
# (1) blocked-reconcile forces all_cleared=0 for any issue carrying an
# orchestrator block, so the ticket can never be requeued when the absorbing
# issue closes (a `blocked-on: Nishfleet/<repo>#2379` ref WOULD resolve
# CLOSED and flip it straight back to agent-ready — the fleet-ops#1083
# re-queue class); (2) it makes blocked-reconcile START the existing
# orchestrator decision sweep once the ticket ages past an hour, which closes
# it as subsumed. The judge never closes it.

# Seconds a park entry is honoured by the same-tick claim skip. The label
# flip is the durable guard across ticks; this only has to outlive the tick
# whose ready list was fetched before the verdict landed.
SPEC_JUDGE_ABSORB_TTL_S="${SPEC_JUDGE_ABSORB_TTL_S:-86400}"

# Per-repo park ledger: `number<TAB>absorbing-number<TAB>epoch`, one per line.
spec_judge_absorbed_file() {
    printf '%s\n' "$(spec_judge_state_dir)/absorbed-$1.tsv"
}

# Print the same-repo issue numbers a binding section declares absorbed.
# Handles `Absorbs #N` and `Absorbed by #N`, bare or as `<owner>/<repo>#N`,
# and the ref LIST the judge actually writes on 0509 (`Absorbs #2428 and
# #2429`, `Absorbs #2424, #2426, #2427`). A cross-repo ref is deliberately
# ignored — one repo's judge run never parks another repo's ticket.
spec_judge_absorbed_refs() {
    local text="$1" full_repo="$2" wanted
    wanted="$(printf '%s' "$full_repo" | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$text" | tr '[:upper:]' '[:lower:]' \
        | awk -v repo="$wanted" '
            function emit(tok,   i, rp, num) {
                i = index(tok, "#")
                num = substr(tok, i + 1)
                rp = (i > 1) ? substr(tok, 1, i - 1) : ""
                if (rp != "" && rp != repo) return
                print num
            }
            {
                rest = $0
                while (match(rest, /(absorbed by|absorbs)[ \t]+/)) {
                    rest = substr(rest, RSTART + RLENGTH)
                    while (match(rest, /^([a-z0-9._-]+\/[a-z0-9._-]+)?#[0-9]+/)) {
                        emit(substr(rest, RSTART, RLENGTH))
                        rest = substr(rest, RLENGTH + 1)
                        sub(/^[ \t]*(,|;|&|and)[ \t]*/, "", rest)
                    }
                }
            }
        ' | sort -n -u
}

# Drop park entries older than the TTL so the ledger cannot grow forever.
spec_judge_absorbed_prune() {
    local repo="$1" f tmp now
    f="$(spec_judge_absorbed_file "$repo")"
    [[ -f "$f" ]] || return 0
    now="$(date +%s)"
    tmp="$(mktemp)" || return 0
    awk -F'\t' -v now="$now" -v ttl="$SPEC_JUDGE_ABSORB_TTL_S" \
        'NF >= 3 && (now - $3) <= ttl' "$f" >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# Record a parked ticket so this tick's claim loop still skips it.
spec_judge_absorbed_record() {
    local repo="$1" n="$2" by="$3"
    spec_judge_absorbed_prune "$repo" || true
    printf '%s\t%s\t%s\n' "$n" "$by" "$(date +%s)" \
        >>"$(spec_judge_absorbed_file "$repo")" 2>/dev/null \
        || echo "ALERT spec-judge: absorbed-ledger append failed issue=$n repo=$repo — same-tick claim skip for the parked ticket is lost (fleet-ops silent-drop)" >&2
}

# Exit 0 if issue N is parked as absorbed for this repo.
spec_judge_absorbed_has() {
    local repo="$1" n="$2" f
    f="$(spec_judge_absorbed_file "$repo")"
    [[ -f "$f" ]] || return 1
    awk -F'\t' -v n="$n" '$1 == n { found = 1 } END { exit !found }' "$f" 2>/dev/null
}

# Park one absorbed ticket. Returns non-zero (and touches nothing) when the
# ref names an issue that is not an OPEN agent-ready ticket: a closed ticket,
# a PR number, or an already-claimed ticket is left exactly as it is.
spec_judge_park_absorbed() {
    local full_repo="$1" repo="$2" absorbed="$3" absorbing="$4" state
    [[ "$absorbed" =~ ^[0-9]+$ ]] || return 1
    state=$("$GH" issue view "$absorbed" -R "$full_repo" --json state,labels 2>/dev/null || true)
    [[ -n "$state" ]] || { echo "ALERT spec-judge: gh issue view failed/empty absorbed=$absorbed repo=$full_repo — judge-declared park skipped, no retry (fleet-ops silent-drop)" >&2; return 1; }
    [[ "$(printf '%s' "$state" | jq -r '.state // ""' 2>/dev/null || echo "")" == "OPEN" ]] || return 1
    printf '%s' "$state" \
        | jq -e '[.labels[]? | if type == "object" then (.name // empty) else . end] | index("agent-ready") != null' >/dev/null 2>&1 \
        || return 1
    "$GH" issue edit "$absorbed" -R "$full_repo" \
        --remove-label agent-ready --add-label agent-blocked \
        --add-label needs-orchestrator >/dev/null 2>&1 \
        || echo "ALERT spec-judge: gh issue edit rc=$? work=absorbed-park-labels issue=$absorbed repo=$full_repo — absorbed ticket stays agent-ready and may be claimed (fleet-ops silent-drop)" >&2
    # The `blocked-on: orchestrator` line is what makes the park hold: an
    # orchestrator block forces blocked-reconcile's all_cleared to 0 on every
    # pass, so a ref to the absorbing issue (already on the ticket, or added
    # later) can never flip it back to agent-ready when that issue closes.
    # It also makes blocked-reconcile START the existing orchestrator decision
    # sweep once the ticket ages past an hour (fleet-ops#4260 belt), which is
    # the "until an orchestrator closes it as subsumed" half of option (a).
    local body
    body="spec-judge: absorbed by #${absorbing} — the binding judge edit on #${absorbing} declares this ticket subsumed."
    body+=$'\n\nParked: agent-ready removed, agent-blocked + needs-orchestrator added. Do not claim it; that work is already in the absorbing issue.'
    body+=$'\n\nNo ref to the absorbing issue on purpose: when that issue closes, a ref would requeue this ticket and a worker would burn a slot proving work that already landed (fleet-ops#1083/#5131). The judge does not close it.'
    body+=$'\n\nblocked-on: orchestrator'
    "$GH" issue comment "$absorbed" -R "$full_repo" --body "$body" >/dev/null 2>&1 \
        || echo "ALERT spec-judge: gh issue comment rc=$? work=absorbed-park-notice issue=$absorbed repo=$full_repo — park notice dropped; park still holds via labels + blocked-on line (fleet-ops silent-drop)" >&2
    spec_judge_absorbed_record "$repo" "$absorbed" "$absorbing"
    return 0
}

# --- claim-loop skip -------------------------------------------------------

# Exit 0 if issue N is a member of a batch being judged for this repo
# (i.e. the in-flight marker lists it), or was parked as absorbed by a
# verdict that landed earlier in THIS tick (the ready list was fetched
# before the verdict was applied, so the label flip alone is too late).
spec_judge_skip_member() {
    local repo="$1" n="$2"
    local inflight
    inflight="$(spec_judge_inflight_file "$repo")"
    if [[ -f "$inflight" ]] \
        && jq -e --arg n "$n" '.batch | index(($n | tonumber)) != null' "$inflight" >/dev/null 2>&1; then
        return 0
    fi
    spec_judge_absorbed_has "$repo" "$n"
}
