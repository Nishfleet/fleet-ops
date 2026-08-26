# shellcheck shell=bash
# lib/packet-assembly.sh
#
# Shared, deterministic packet-assembly helpers for research-seeded 0509
# scouting and the #146 auditor context packet. Sourced by pi-scout-run and
# (future) auditor runners. Never executed directly.
#
# Goal: one place where the context packet is built. No duplicate assembly
# logic between scout and auditor.

export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Paths are overridable for tests and non-default agent-state layouts.
AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/workspaces/agent-state}"
PACKET_MARKET_SIGNAL_DIR="${PACKET_MARKET_SIGNAL_DIR:-$AGENT_STATE_DIR/cron-output}"
PACKET_TRANSFORMATION_DIR="${PACKET_TRANSFORMATION_DIR:-$AGENT_STATE_DIR/0509-transformation}"
PACKET_PLAN_FILE="${PACKET_PLAN_FILE:-$AGENT_STATE_DIR/fleet-restoration-2026-08-25.md}"
PACKET_NORTH_STAR_FILE="${PACKET_NORTH_STAR_FILE:-$HOME/workspaces/tooling/nish-vault/03 Knowledge/compiled/shared-memory/global/north-star-edge-ai-cannot-match.md}"
PACKET_GH="${PACKET_GH:-gh}"

# packet_market_signal <max_age_hours>
# Print the latest 0509-daily-market-signal file as a markdown section.
# Returns 1 if the file is missing or older than max_age_hours (default 36).
packet_market_signal() {
    local max_age="${1:-36}"
    local latest
    latest=$(find "$PACKET_MARKET_SIGNAL_DIR" -maxdepth 1 -type f \
        -name '0509-daily-market-signal-*.md' \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | head -n 1 \
        | cut -d' ' -f2-)

    if [[ -z "$latest" ]]; then
        printf '## Market signal (STALE — missing)\n'
        printf 'No 0509-daily-market-signal-*.md file found in %s.\n\n' "$PACKET_MARKET_SIGNAL_DIR"
        return 1
    fi

    local now mtime age_h
    now=$(date -u +%s)
    mtime=$(stat -c %Y "$latest" 2>/dev/null || echo 0)
    age_h=$(( (now - mtime) / 3600 ))

    if (( age_h > max_age )); then
        printf '## Market signal (STALE — %dh old > %dh): %s\n' "$age_h" "$max_age" "$latest"
        cat "$latest"
        printf '\n\n'
        return 1
    fi

    printf '## Market signal (%dh old): %s\n' "$age_h" "$latest"
    cat "$latest"
    printf '\n\n'
}

# packet_category_research
# Print the 0509 transformation category-research doc.
packet_category_research() {
    local f="$PACKET_TRANSFORMATION_DIR/category-research.md"
    if [[ -f "$f" ]]; then
        printf '## Transformation campaign state\n%s\n\n' "$f"
        cat "$f"
    else
        printf '## Transformation campaign state (missing)\nNo %s found.\n\n' "$f"
    fi
    printf '\n'
}

# packet_north_star
# Print the north-star rule verbatim.
packet_north_star() {
    local f="$PACKET_NORTH_STAR_FILE"
    if [[ -f "$f" ]]; then
        printf '## North-star rule (verbatim)\n%s\n\n' "$f"
        cat "$f"
    else
        printf '## North-star rule (missing — use the verbatim text below)\n'
        printf 'Nothing ships at parity with generic AI output: parity-quality work gets raised, not shipped.\n'
        printf 'Every feature must be clearly BETTER than what the customer'"'"'s own AI would give them.\n'
        printf 'See the compiled north-star memory for the full rule.\n\n'
    fi
    printf '\n'
}

# packet_repo_reality <repo>
# Print recent merged PR titles (last 20), open issues, and open PRs.
packet_repo_reality() {
    local repo="$1"
    local merged issues prs

    merged=$("$PACKET_GH" pr list -R "Nishfleet/$repo" --state merged \
        --json title --limit 20 2>/dev/null \
        | jq -r '[.[] | .title] | join("\n")' || true)
    issues=$("$PACKET_GH" issue list -R "Nishfleet/$repo" --state open \
        --json number,title --limit 200 2>/dev/null \
        | jq -r '[.[] | "#\(.number): \(.title)"] | join("\n")' || true)
    prs=$("$PACKET_GH" pr list -R "Nishfleet/$repo" --state open \
        --json number,title --limit 100 2>/dev/null \
        | jq -r '[.[] | "#\(.number): \(.title)"] | join("\n")' || true)

    {
        printf '## Recent merged PR titles (last 20)\n'
        if [[ -n "$merged" ]]; then
            printf '%s\n' "$merged" | sed 's/^/- /'
        else
            printf '- <none>\n'
        fi
        printf '\n## Open issues\n'
        printf '%s\n\n' "${issues:-<none>}"
        printf '## Open PRs\n'
        printf '%s\n\n' "${prs:-<none>}"
    }
}

# packet_decisions_ledger
# Print the DECISIONS LEDGER section from the plan file, or the first 8KB.
packet_decisions_ledger() {
    local f="$PACKET_PLAN_FILE"
    if [[ ! -f "$f" ]]; then
        printf '## Decisions ledger (missing)\nNo %s found.\n\n' "$f"
        return
    fi

    printf '## Decisions ledger (verbatim)\n'
    if grep -qEi '^#* *DECISIONS LEDGER' "$f" 2>/dev/null; then
        awk 'BEGIN{flag=0}
             /^#* *DECISIONS LEDGER/{flag=1; print; next}
             flag && (/^#/ || /^--- *$/){ if (/^--- *$/) exit; if (/^#/) exit }
             flag' "$f" | head -c 8000
    else
        head -c 8000 "$f"
    fi
    printf '\n\n'
}

# packet_assemble_0509_scout <prompt_file> <repo> <out_file>
# Assemble the full 0509 scout packet into out_file (or stdout if '-').
# The packet contains the prompt, a research-context block, and the
# TARGET line at the end.
# Returns 1 if the market signal is stale/missing, but still writes the
# packet with a STALE marker so callers can choose to fail loud.
packet_assemble_0509_scout() {
    local prompt_file="$1" repo="$2" out_file="${3:--}"
    local stale=0
    local tmp
    tmp=$(mktemp)

    {
        cat "$prompt_file"
        printf '\n\n---\n\n'
        printf '## RESEARCH CONTEXT (read and cite)\n\n'
        printf 'Every candidate you file MUST cite which research item motivated it. '
        printf 'Use a `source:` line in the issue body with the exact market-signal line, '
        printf 'bet ID, or rule reference. A candidate with no research citation is '
        printf 'auto-FAIL at the auditor panel.\n\n'

        packet_market_signal 36 || stale=1
        packet_category_research
        packet_north_star
        packet_repo_reality "$repo"

        printf '\n---\n\n'
        printf 'TARGET REPO: Nishfleet/%s\n' "$repo"
    } > "$tmp"

    if [[ "$out_file" == "-" ]]; then
        cat "$tmp"
    else
        mv "$tmp" "$out_file"
    fi
    rm -f "$tmp" 2>/dev/null || true

    return "$stale"
}
