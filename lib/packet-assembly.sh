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
# fleet-ops#4562 accept 4: Direction block source (decisions ledger + the
# section heading that carries the current 0509 direction verdict).
PACKET_DIRECTION_LEDGER_FILE="${PACKET_DIRECTION_LEDGER_FILE:-$HOME/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md}"
PACKET_DIRECTION_SECTION="${PACKET_DIRECTION_SECTION:-2026-09-09 — 0509 direction}"
PACKET_GH="${PACKET_GH:-gh}"

# PACKET_CF_FILE must be defined before PACKET_PRODUCT_CF_FILE (which
# defaults to it) — sourcing this lib under `set -u` (fleet-blind-audit)
# otherwise trips on the forward reference.
PACKET_CF_FILE="${PACKET_CF_FILE:-$HOME/.config/cloudflare/deploy-ci.env}"

# fleet-ops#5699: live 0509 signup metrics for the Direction block, read at
# packet assembly from production D1 through the same sanctioned seam the
# measure feed uses (token from a deploy-ci.env-style file, D1 REST query).
# A failed read prints `signups_<field>=UNAVAILABLE:<why>` — never a
# fabricated 0, never a silent drop, never a scout-run failure.
PACKET_PRODUCT_CF_FILE="${PACKET_PRODUCT_CF_FILE:-${PACKET_CF_FILE:-$HOME/.config/cloudflare/deploy-ci.env}}"
PACKET_PRODUCT_D1_ACCOUNT="${PACKET_PRODUCT_D1_ACCOUNT:-f670a698e17bf160c8e4679823e68916}"
PACKET_PRODUCT_D1_DATABASE="${PACKET_PRODUCT_D1_DATABASE:-746c6e3d-782e-443a-82d6-28ca93a16294}"
PACKET_D1_TIMEOUT="${PACKET_D1_TIMEOUT:-15}"
PACKET_CURL="${PACKET_CURL:-curl}"
PACKET_JQ="${PACKET_JQ:-jq}"

# 0509 usage-telemetry seams (fleet-ops#3149). Each source is best-effort: a
# source that is missing, unreachable, permission-denied, or empty is DROPPED
# from the usage block with a visible marker, never failing the scout run.
PACKET_0509_DIR="${PACKET_0509_DIR:-$HOME/workspaces/products/0509}"
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

# _packet_d1q <label> <sql>
# fleet-ops#5699: one D1 REST query; echoes `label=<value|UNAVAILABLE:why>`.
# Mirrors the measure-feed convention (agent-state/fleet-landing-watch/
# measure.sh): a token-missing/file-missing/timeout/bad-response read is an
# explicit UNAVAILABLE marker, never a fabricated 0.
_packet_d1q() {
    local label="$1" sql="$2"
    local token=""
    if [[ -f "$PACKET_PRODUCT_CF_FILE" ]]; then
        token=$(awk -F= '/^CLOUDFLARE_API_TOKEN=/{print $2; exit}' "$PACKET_PRODUCT_CF_FILE" 2>/dev/null)
    fi
    if [[ -z "$token" ]]; then
        if [[ ! -f "$PACKET_PRODUCT_CF_FILE" ]]; then
            printf '%s=UNAVAILABLE:cf-token-file-missing(%s)\n' "$label" "$PACKET_PRODUCT_CF_FILE"
        else
            printf '%s=UNAVAILABLE:no-cf-token\n' "$label"
        fi
        return 0
    fi
    local body
    body=$(printf '{"sql":%s}' "$(command "$PACKET_JQ" -nc --arg q "$sql" '$q' 2>/dev/null)" | \
        command "$PACKET_CURL" -s -m "$PACKET_D1_TIMEOUT" -X POST \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/$PACKET_PRODUCT_D1_ACCOUNT/d1/database/$PACKET_PRODUCT_D1_DATABASE/query" \
        --data @- 2>/dev/null)
    local n
    n=$(printf '%s' "$body" | command "$PACKET_JQ" -r 'if .success==true then (.result[0].results[0].n) else empty end' 2>/dev/null)
    if [[ -z "$n" || "$n" == "null" ]]; then
        local why
        why=$(printf '%s' "$body" | command "$PACKET_JQ" -r '.errors[0].message // "bad-response"' 2>/dev/null)
        printf '%s=UNAVAILABLE:%s\n' "$label" "$(printf '%s' "$why" | cut -c1-120)"
    else
        printf '%s=%s\n' "$label" "$n"
    fi
}

# packet_direction_live_metric
# fleet-ops#5699: print the live-metric line for the Direction block.
# Three production-D1 reads (signups_24h, signups_30d, last_signup) joined
# onto one line. Every individual read failure degrades to
# `UNAVAILABLE:<why>` on its own field — the line is still printed so the
# scout always sees the machine-readable signal shape.
packet_direction_live_metric() {
    local s24 s30 last
    s24=$(_packet_d1q signups_24h "SELECT COUNT(*) AS n FROM user WHERE createdAt >= datetime('now','-1 day');")
    s30=$(_packet_d1q signups_30d "SELECT COUNT(*) AS n FROM user WHERE createdAt >= datetime('now','-30 day');")
    last=$(_packet_d1q last_signup "SELECT MAX(createdAt) AS n FROM user;")
    printf 'live metric (production D1, read at packet assembly): %s %s %s\n' "$s24" "$s30" "$last"
}

# packet_direction_block
# fleet-ops#4562 (accept 4): the 0509 scout RESEARCH CONTEXT gains a
# **Direction** block carrying the current product-direction decision fed
# from the decisions ledger (senior panel verdict on #4518, MATRIX-decided,
# Nish-vetoable). Best-effort: a missing ledger or section degrades to a
# marker, never fails the scout — but the citation line is always printed so
# the scout's `source: direction#4518` form is stable.
packet_direction_block() {
    local f="$PACKET_DIRECTION_LEDGER_FILE"
    local section="$PACKET_DIRECTION_SECTION"
    local printed=0
    if [[ -f "$f" && -n "$section" ]]; then
        local frag
        frag="$(awk -v hdr="$section" '
            flag && /^## / { if (seen) exit }
            index($0, hdr) > 0 { flag=1; seen=1; print; next }
            flag { print }
        ' "$f" 2>/dev/null)"
        if [[ -n "$frag" ]]; then
            printf '## Direction (current product direction — cite as `source: direction#4518`)\n\n'
            printf '%s\n\n' "$frag"
            printf '> live: %s\n\n' "$(packet_direction_live_metric)"
            printf 'Evaluate the A.7 direction half-cap and the A.8 acquisition-first condition (`signups-30d == 0`, fleet-ops#4518 + #4657) against the live `signups_30d=` value above, NOT against the ledger snapshot prose — the ledger entry may be frozen while the production metric has moved.\n\n'
            printf 'While this entry stands, at least half of the 0509 candidates you file MUST cite the Direction block (`source: direction#4518`) — see scout prompt A.6/A.7.\n\n'
            printed=1
        fi
    fi
    if [[ "$printed" == "0" ]]; then
        printf '## Direction (unavailable)\n\n'
        printf 'No direction entry found in the decisions ledger. File candidates per A.6 without a Direction citation; do NOT invent one.\n\n'
    fi
}

# _packet_gh_quota <credential>
# One `gh api rate_limit` read on the named credential (the endpoint is
# free — it does not consume the bucket it reports). Prints
# `core=<n>,graphql=<n>`; `?` fields when unreadable.
_packet_gh_quota() {
    local cred="$1" out q
    if [[ "$cred" == "user-rest" ]]; then
        out=$( ( unset GH_TOKEN GITHUB_TOKEN; "$PACKET_GH" api rate_limit ) 2>/dev/null)
    else
        out=$("$PACKET_GH" api rate_limit 2>/dev/null)
    fi
    q=$(printf '%s' "$out" | command "$PACKET_JQ" -r \
        '(.resources // {}) | "core=\(.core.remaining // "?"),graphql=\(.graphql.remaining // "?")"' \
        2>/dev/null)
    printf '%s' "${q:-core=?,graphql=?}"
}

# _packet_gh_stamp <label> <served-by>
# Append one credential-provenance line per list call to
# $PACKET_GH_STAMP_FILE when set (stderr otherwise):
#   gh-credential <label>: served-by=<cred> quota=core=<n>,graphql=<n>
_packet_gh_stamp() {
    local line
    line="gh-credential $1: served-by=$2 quota=$(_packet_gh_quota "$2")"
    if [[ -n "${PACKET_GH_STAMP_FILE:-}" ]]; then
        printf '%s\n' "$line" >>"$PACKET_GH_STAMP_FILE" 2>/dev/null || true
    else
        printf '%s\n' "$line" >&2
    fi
}

# packet_gh_read <label> <rest_path> <rest_jq> -- <gh args...>
# fleet-ops#5781: run `gh <args>` under the App installation credential
# (`gh issue|pr list` are GraphQL calls on the installation's graphql
# bucket). On error, retry the equivalent REST list via `gh api
# <rest_path>` with GH_TOKEN/GITHUB_TOKEN unset — gh then uses the human
# identity, which the fleet contract allows for organ READS
# (fleet-ops#3445 "Human gh is read-only for organs"; the #5489 _gh_read
# precedent). The installation and user buckets are independent, as are
# each credential's core (REST) and graphql buckets, so an exhausted
# installation-GraphQL budget no longer blinds the packet (live case
# 2026-09-12: the audit packet read "Open issues: []" on a repo with 200+
# open issues while the user REST bucket still held ~4984).
# <rest_jq> reshapes the REST response into the same JSON shape the
# primary `--json` list would have printed (REST /issues also returns
# PRs — filter on `.pull_request == null`; REST uses `closed_at` /
# `merged_at` snake_case where GraphQL uses closedAt/mergedAt, and has
# no closedByPullRequestsReferences equivalent — emit [] there).
# Prints the JSON on stdout; on a double failure prints nothing and
# returns 1 so callers keep their `|| echo '[]'` / `|| true` shape.
packet_gh_read() {
    local label="$1" rest_path="$2" rest_jq="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    local out
    if out=$("$PACKET_GH" "$@" 2>/dev/null); then
        _packet_gh_stamp "$label" "installation"
        printf '%s' "$out"
        return 0
    fi
    if out=$( ( unset GH_TOKEN GITHUB_TOKEN; "$PACKET_GH" api "$rest_path" ) 2>/dev/null \
              | command "$PACKET_JQ" -c "$rest_jq" 2>/dev/null) \
        && [[ -n "$out" ]]; then
        _packet_gh_stamp "$label" "user-rest"
        printf '%s' "$out"
        return 0
    fi
    _packet_gh_stamp "$label" "unavailable"
    return 1
}

# packet_repo_reality <repo>
# Print recent merged PR titles (last 20), open issues, and open PRs.
packet_repo_reality() {
    local repo="$1"
    local merged issues prs

    # fleet-ops#5781: every list goes through packet_gh_read; the serving
    # credential + remaining quota are stamped into the block so the packet
    # can never silently read "no open issues" on a repo full of them.
    local _stamp_f _saved_stamp
    _stamp_f=$(mktemp "${TMPDIR:-/tmp}/packet-gh-stamps.XXXXXX" 2>/dev/null || true)
    _saved_stamp="${PACKET_GH_STAMP_FILE:-}"
    [[ -n "$_stamp_f" ]] && PACKET_GH_STAMP_FILE="$_stamp_f"

    merged=$(packet_gh_read merged-prs "repos/Nishfleet/$repo/pulls?state=closed&per_page=100" \
        '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | reverse | .[0:20] | map({title})' \
        -- pr list -R "Nishfleet/$repo" --state merged --json title --limit 20 \
        | command "$PACKET_JQ" -r '[.[] | .title] | join("\n")' || true)
    issues=$(packet_gh_read open-issues "repos/Nishfleet/$repo/issues?state=open&per_page=100" \
        '[.[] | select(.pull_request == null) | {number,title}] | .[0:200]' \
        -- issue list -R "Nishfleet/$repo" --state open --json number,title --limit 200 \
        | command "$PACKET_JQ" -r '[.[] | "#\(.number): \(.title)"] | join("\n")' || true)
    prs=$(packet_gh_read open-prs "repos/Nishfleet/$repo/pulls?state=open&per_page=100" \
        '[.[] | {number,title}] | .[0:100]' \
        -- pr list -R "Nishfleet/$repo" --state open --json number,title --limit 100 \
        | command "$PACKET_JQ" -r '[.[] | "#\(.number): \(.title)"] | join("\n")' || true)

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
        if [[ -n "$_stamp_f" && -s "$_stamp_f" ]]; then
            while IFS= read -r _credline; do
                printf '> %s\n' "$_credline"
            done < "$_stamp_f"
            printf '\n'
        fi
    }

    if [[ -n "$_saved_stamp" ]]; then
        PACKET_GH_STAMP_FILE="$_saved_stamp"
    else
        unset PACKET_GH_STAMP_FILE
    fi
    [[ -n "$_stamp_f" ]] && rm -f "$_stamp_f"
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
#
# This source is OPTIONAL (fleet-ops#3172): when the sanctioned token lacks
# zone.analytics.read the authz failure is logged as a one-line
# `usage-source: cloudflare-analytics UNAVAILABLE (token scope)` marker and the
# source DROPS (returns 1) — it must never fail the scout run or drop the whole
# usage block. The other usage sources (lp_run_audit, /search query log, inbound
# email) still assemble around it.
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
    # TODO(fleet-ops#3172): once the sanctioned CF token is re-scoped with
    # Zone Analytics Read for the 0509 zone, this source lights up by itself —
    # the GraphQL call below returns data instead of the authz error, so the
    # UNAVAILABLE branch below stops matching and the block prints normally.
    # No code change needed at that point; re-run the packet-assembly probe to
    # confirm.
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
        ERR:*|EMPTY)
            # fleet-ops#3172: the sanctioned token lacks zone.analytics.read, so
            # the GraphQL call returns an authz error. This source is OPTIONAL —
            # log the availability line and DROP (return 1); the scout run and
            # the rest of the usage block continue. A missing optional source
            # must never fail the scout run.
            if [[ "$lines" == *"zone.analytics.read"* ]]; then
                printf 'usage-source: cloudflare-analytics UNAVAILABLE (token scope)\n'
            fi
            printf '### Cloudflare analytics (%s, %s days): %s\n\n' "$zone_name" "$days" "${lines#ERR: }"
            return 1
            ;;
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
    printf 'Subject/from lines:\n'
    find "$dir" -maxdepth 1 -type f -newermt "@$cutoff" \( -name '*.eml' \) \
        2>/dev/null | while read -r f; do
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
        printf 'NOTE: every usage source is empty or green in this environment. Per scout prompt A.6 (fleet-ops#4560, #4850) the scout must file at least 1 and at most SCOUT_RESEARCH_FLOOR (default 5) research-grounded candidates citing a market-signal line, a BET id, the north-star rule, or a merged-PR title, each tagged scout-candidate + usage-uncited. The floor is a hard minimum, not a deliberation prompt — do not loop between deciding and filing; file the next action, then print the supply: verdict line. Code-inspection-only candidates stay DROPPED.\n\n'
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
        packet_direction_block
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
