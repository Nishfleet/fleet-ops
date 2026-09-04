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

# 0509 usage-telemetry seams (fleet-ops#3149). Each source is best-effort: a
# source that is missing, unreachable, permission-denied, or empty is DROPPED
# from the usage block with a visible marker, never failing the scout run.
PACKET_0509_DIR="${PACKET_0509_DIR:-$HOME/workspaces/products/0509}"
PACKET_CF_FILE="${PACKET_CF_FILE:-$HOME/.config/cloudflare/deploy-ci.env}"
PACKET_ZONE_NAME="${PACKET_ZONE_NAME:-0509.io}"
PACKET_CF_ZONE="${PACKET_CF_ZONE:-}"
PACKET_USAGE_SOURCES="${PACKET_USAGE_SOURCES:-1}"
PACKET_MONEY_PATH_WALK="${PACKET_MONEY_PATH_WALK:-1}"
PACKET_WALK_OUT="${PACKET_WALK_OUT:-$AGENT_STATE_DIR/scout-money-path}"
# Where the 0509 lp_run_audit (PR #1537) and /search query-log telemetry dump
# when they exist. Both are D1/log-backed inside the 0509 app today; a scout
# run that cannot read them sees the source DROPPED (empty) until a reader
# exports them here.
PACKET_LP_AUDIT_DIR="${PACKET_LP_AUDIT_DIR:-$AGENT_STATE_DIR/0509-lp-run-audit}"
PACKET_SEARCH_LOG_DIR="${PACKET_SEARCH_LOG_DIR:-$AGENT_STATE_DIR/0509-search-log}"
PACKET_MAILBOX_DIR="${PACKET_MAILBOX_DIR:-}"

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
        printf '## Transformation campaign state\n\n'
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
        printf '## North-star rule (verbatim)\n\n'
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

# packet_cf_token <file>
# Read CLOUDFLARE_API_TOKEN from a CF env file (never echoes the value).
# Returns 0 + prints the token, or 1 with empty output.
packet_cf_token() {
    local f="$1" line val
    [[ -f "$f" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" != CLOUDFLARE_API_TOKEN=* ]] && continue
        val="${line#CLOUDFLARE_API_TOKEN=}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        if [[ -n "$val" ]]; then
            printf '%s' "$val"
            return 0
        fi
    done < "$f"
    return 1
}

# packet_cf_zone_id <token> <zone_name>
# Resolve a zone id by name via Cloudflare's zones list API. Read-only.
packet_cf_zone_id() {
    local token="$1" name="$2" resp id
    resp=$(curl -sS -m 20 \
        "https://api.cloudflare.com/client/v4/zones?name=$name" \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/json' 2>/dev/null) || return 1
    id=$(printf '%s' "$resp" \
        | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 if d.get("success") and d.get("result"): print(d["result"][0]["id"])
except Exception: pass' 2>/dev/null)
    [[ -n "$id" ]] || return 1
    printf '%s' "$id"
}

# packet_cf_analytics_usage <zone_name> <days>
# Attempt Cloudflare Zone Analytics (GraphQL) for the last <days> days and
# print a compact usage block: total volume, top pages (uniques/requests),
# 4xx (404s), and slow routes (avg edge time). Vendor API via the sanctioned
# CF token. Returns 1 (DROP) when the token is missing, lacks analytics scope,
# the zone is unknown, or the query returns no rows. fleet-ops#3149.
packet_cf_analytics_usage() {
    local zone_name="${1:-$PACKET_ZONE_NAME}" days="${2:-7}"
    local token zone from now q resp rows lines t
    if [[ ! -f "$PACKET_CF_FILE" ]]; then
        printf '### Cloudflare analytics (%s, %s days): (empty — no CF token file at %s)\n\n' "$zone_name" "$days" "$PACKET_CF_FILE"
        return 1
    fi
    token=$(packet_cf_token "$PACKET_CF_FILE") || return 1
    if [[ -n "$PACKET_CF_ZONE" ]]; then
        zone="$PACKET_CF_ZONE"
    else
        zone=$(packet_cf_zone_id "$token" "$zone_name") || return 1
    fi
    now=$(date -u +%Y-%m-%d)
    from=$(date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null)
    # Schema-validated shape: httpRequests1dGroups date x (requests, uniques).
    # Path-level dimensions (top pages / 404s / slow routes) were not validated
    # here and the sanctioned token lacks zone.analytics.read (see filed gap
    # issue), so THAT fidelity is a follow-up; the volume query is the one that
    # parses cleanly (authz-gated only).
    q="query {
  viewer {
    zones(filter: {zoneTag: \"$zone\"}) {
      httpRequests1dGroups(
        limit: 7
        filter: {date_geq: \"$from\", date_lt: \"$now\"}
      ) {
        dimensions { date }
        sum { requests }
        uniq { uniques }
      }
    }
  }
}"
    r=$(curl -sS -m 40 "https://api.cloudflare.com/client/v4/graphql" \
        -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        --data "$(python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "$q")" 2>/dev/null)
    [[ -n "$r" ]] || return 1
    lines=$(printf '%s' "$r" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 errs=d.get("errors")
 if errs:
  m=errs[0].get("message","")
  print("ERR: " + m[:140]); raise SystemExit(0)
 g=(d.get("data",{}) or {}).get("viewer",{}).get("zones",[{}])
 rows=(g[0].get("httpRequests1dGroups",[]) if g and isinstance(g[0],dict) else [])
 if not rows: print("EMPTY"); raise SystemExit(0)
 for rw in rows:
  dim=rw.get("dimensions",{}).get("date") or ""
  s=rw.get("sum",{}); u=rw.get("uniq",{})
  print(dim, s.get("requests",0), u.get("uniques",0))
except Exception as e:
 print("ERR: parse")
' 2>/dev/null)
    [[ -n "$lines" ]] || return 1
    case "$lines" in
        ERR:*|EMPTY) printf '### Cloudflare analytics (%s, %s days): %s\n\n' "$zone_name" "$days" "${lines#ERR: }"; return 1 ;;
    esac
    printf '### Cloudflare analytics — %s, %s days (vendor API)\n' "$zone_name" "$days"
    printf 'Daily requests + uniques (date, requests, uniques):\n'
    printf '%s\n' "$lines" | sed 's/^/- /'
    printf '\nSource: Cloudflare Zone Analytics GraphQL (sanctioned CF token), %s.\n\n' "$zone_name"
}

# packet_local_usage <label> <dir> <glob>
# Print a usage sub-block from the newest matching file in <dir>, or drop.
packet_local_usage() {
    local label="$1" dir="$2" glob="$3" f
    [[ -d "$dir" ]] || { printf '### %s: (empty — no dump at %s)\n' "$label" "$dir"; return 1; }
    f=$(find "$dir" -maxdepth 1 -type f -name "$glob" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
    [[ -n "$f" ]] || { printf '### %s: (empty — no %s files in %s)\n' "$label" "$glob" "$dir"; return 1; }
    printf '### %s (newest: %s)\n' "$label" "$(basename "$f")"
    cat "$f"
    printf '\nSource: %s.\n\n' "$f"
}

# packet_inbound_email_usage <days>
# Emails from the last <days> days in a mailbox export dir (PACKET_MAILBOX_DIR),
# or drop when no mailbox export exists.
packet_inbound_email_usage() {
    local days="${1:-7}" dir="$PACKET_MAILBOX_DIR"
    [[ -n "$dir" && -d "$dir" ]] || { printf '### Inbound customer email (last %s days): (none — no mailbox export dir configured)\n' "$days"; return 1; }
    local cutoff n
    cutoff=$(date -u -d "$days days ago" +%s 2>/dev/null)
    n=$(find "$dir" -maxdepth 1 -type f \( -name '*.eml' -o -name '*.mbox' \) \
        -newermt "@$cutoff" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${n:-0}" == "0" ]]; then
        printf '### Inbound customer email (last %s days): (empty — %s new messages in %s)\n' "$days" "$n" "$dir"
        return 1
    fi
    printf '### Inbound customer email (last %s days): %s message(s) in %s\n' "$days" "$n" "$dir"
    printf 'Subject/from lines (truncated):\n'
    find "$dir" -maxdepth 1 -type f -newermt "@$cutoff" \( -name '*.eml' \) \
        2>/dev/null | head -10 | while read -r f; do
        printf -- '- %s: ' "$(basename "$f")"
        sed -n 's/^Subject: //p' "$f" | head -1
    done
    printf 'Source: inbound mailbox export %s.\n\n' "$dir"
}

# packet_money_path_walk
# Drive https://0509.io through search -> result -> pricing -> signup start in
# fresh sessions at mobile + desktop viewports, using the Playwright already
# installed in the 0509 checkout. Prints a findings block with screenshot
# evidence paths. Best-effort: returns 1 (DROP) when the 0509 checkout or its
# playwright is unavailable, and never fails the scout. fleet-ops#3149.
packet_money_path_walk() {
    local walker lib_dir out
    if [[ "$PACKET_MONEY_PATH_WALK" == "0" ]]; then
        printf '### Money-path walk: skipped (PACKET_MONEY_PATH_WALK=0)\n\n'
        return 1
    fi
    [[ -d "$PACKET_0509_DIR/node_modules/playwright" ]] \
        || { printf '### Money-path walk: (unavailable — no playwright in %s)\n\n' "$PACKET_0509_DIR"; return 1; }
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    walker="$lib_dir/scout-money-path-walk.mjs"
    out="$PACKET_WALK_OUT/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$out"
    # 0509_DIR starts with a digit so it is not a valid bash assignment
    # identifier — prefix via env, never VAR=... node.
    if ! env OUTDIR="$out" 0509_DIR="$PACKET_0509_DIR" node "$walker" 2>/dev/null; then
        printf '### Money-path walk: (failed — screenshots in %s)\n\n' "$out"
        return 1
    fi
    printf 'Screenshots: %s (fresh mobile + desktop sessions).\n\n' "$out"
}

# packet_usage_block
# Assemble the RESEARCH CONTEXT 'usage' block from best-effort sources. Each
# empty/unavailable source is DROPPED with a marker. Never fails the scout.
packet_usage_block() {
    local any=0
    printf '## Usage (live product telemetry, 0509 only)\n\n'
    if [[ "$PACKET_USAGE_SOURCES" == "0" ]]; then
        printf 'Usage telemetry disabled (PACKET_USAGE_SOURCES=0).\n\n'
        return 0
    fi
    packet_cf_analytics_usage "$PACKET_ZONE_NAME" 7 && any=1
    packet_local_usage 'lp_run_audit / landing-page telemetry' "$PACKET_LP_AUDIT_DIR" '*.ndjson' && any=1
    packet_local_usage '/search query log' "$PACKET_SEARCH_LOG_DIR" '*.ndjson' && any=1
    packet_money_path_walk && any=1
    packet_inbound_email_usage 7 && any=1
    if [[ "$any" == "0" ]]; then
        printf 'NOTE: every usage source is empty in this environment; the scout must DROP any usage-uncited candidate (accept its own market-signal/walk sources instead).\n\n'
    fi
}

# packet_mechanical_fix_rule
# Print the fleet-ops#366 ledger line verbatim for auditor/conference packets.
packet_mechanical_fix_rule() {
    local lib_dir gate
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    gate="${PACKET_MECHANISM_GATE:-$lib_dir/failure-mechanism-gate.py}"
    printf '## Mechanical-fix rule (verbatim ledger line, fleet-ops#366)\n\n'
    if [[ ! -f "$gate" ]]; then
        printf 'MISSING gate script: %s\n\n' "$gate"
        return 1
    fi
    python3 "$gate" --ledger-line
    printf '\n\n'
}

# packet_decisions_ledger
# Print the DECISIONS LEDGER section from the plan file, or the whole file.
# Do not byte-cap: starving the ledger to save tokens is forbidden
# (sr-token-efficiency; fleet-ops#670).
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
             flag' "$f"
    else
        cat "$f"
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
        packet_usage_block
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
