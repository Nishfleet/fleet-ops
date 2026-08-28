# shellcheck shell=bash
# precedence-band.sh — rent-paying band + overnight surge (fleet-ops#1223).
#
# Sourced by pi-intake-tick and fleet-precedence-band-canary. Not executed.
#
# Ledger 2026-08-27 | Precedence band + overnight machinery surge (Nish):
#   Until 2026-08-28 08:00 IST (cutoff_utc): GO HAM, leverage-ranked only.
#   After: machinery capped at ~30% of live pi-issue@ lanes; product 70%
#   with product_front first. One repair lane always runs when live
#   machinery == 0 (fleet-ops#1452 floor); ratio resumes from the second
#   machinery unit. A machinery issue jumps the band only by naming
#   `band-multiplier: N` on its body. Weekly Fleet Review owns
#   machinery_max_pct / product_min_pct (tighten only).
#
# Environment (tests):
#   PRECEDENCE_BAND_JSON         config/precedence-band.json
#   PRECEDENCE_BAND_NOW          ISO-8601 UTC clock (default: live date -u)
#   FLEET_PRECEDENCE_UNITS_FILE  one pi-issue@ unit name per line
#   BAND_PENDING_FILE            intra-tick floor latch (default: runtime dir)

PRECEDENCE_BAND_JSON="${PRECEDENCE_BAND_JSON:-}"
PRECEDENCE_BAND_NOW="${PRECEDENCE_BAND_NOW:-}"

# Intra-tick floor latch (fleet-ops#1452). pi-intake-tick captures the
# allow_claim reason in $(), so a bash variable cannot persist to the next
# claim. Bash $$ is the original shell even inside $(), so a file keyed on
# $$ is visible to every claim in this tick. The tick starts workers
# --no-block; without the latch the floor would dump the overnight queue.
precedence_band_pending_file() {
    printf '%s\n' "${BAND_PENDING_FILE:-${XDG_RUNTIME_DIR:-/tmp}/precedence-band-pending.$$}"
}
precedence_band_pending_get() {
    if [[ -f "$(precedence_band_pending_file)" ]]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}
precedence_band_pending_set() {
    local f dir
    f="$(precedence_band_pending_file)"
    dir="$(dirname "$f")"
    mkdir -p "$dir"
    : >"$f"
}
precedence_band_pending_clear() {
    rm -f "$(precedence_band_pending_file)"
}

precedence_band_resolve_json() {
    local here
    if [[ -n "$PRECEDENCE_BAND_JSON" && -f "$PRECEDENCE_BAND_JSON" ]]; then
        printf '%s\n' "$PRECEDENCE_BAND_JSON"
        return 0
    fi
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -f "$here/config/precedence-band.json" ]]; then
        printf '%s\n' "$here/config/precedence-band.json"
        return 0
    fi
    if [[ -f "${HOME}/.local/state/pi-packet/precedence-band.json" ]]; then
        printf '%s\n' "${HOME}/.local/state/pi-packet/precedence-band.json"
        return 0
    fi
    return 1
}

precedence_band_now_utc() {
    if [[ -n "$PRECEDENCE_BAND_NOW" ]]; then
        printf '%s\n' "$PRECEDENCE_BAND_NOW"
        return 0
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ
}

precedence_band_epoch() {
    local stamp="$1"
    date -u -d "$stamp" +%s 2>/dev/null || date -u -d "${stamp%Z} UTC" +%s
}

# Prints "surge" or "band".
precedence_band_phase() {
    local json cutoff now_s cut_s
    json="$(precedence_band_resolve_json)" || return 1
    cutoff="$(jq -r '.cutoff_utc // empty' "$json")"
    [[ -n "$cutoff" ]] || return 1
    now_s="$(precedence_band_epoch "$(precedence_band_now_utc)")"
    cut_s="$(precedence_band_epoch "$cutoff")"
    if (( now_s < cut_s )); then
        printf 'surge\n'
    else
        printf 'band\n'
    fi
}

precedence_band_max_pct() {
    local json
    json="$(precedence_band_resolve_json)" || { echo 30; return 0; }
    jq -r '.machinery_max_pct // 30' "$json"
}

precedence_band_is_leverage_issue() {
    local n="$1" json
    json="$(precedence_band_resolve_json)" || return 1
    jq -e --argjson n "$n" '.surge_leverage_issues | index($n) != null' "$json" >/dev/null
}

precedence_band_has_multiplier() {
    local body="$1"
    printf '%s\n' "$body" | grep -qE '^band-multiplier:[[:space:]]*[1-9][0-9]*[[:space:]]*$'
}

# Outage/defect signals that promote an UNPREFIXED title to repair. When a
# title carries no conventional-commit prefix, its content (title + body) is
# scanned for these; a hit is repair, anything else is churn. Prefixed titles
# keep their prefix mapping regardless of body (chore: stays churn even if the
# body says "broken") — the legit-work guard (fleet-ops#1516) depends on this.
PRECEDENCE_BAND_REPAIR_SIGNALS='\b(red|fail(s|ed|ing)?|broken|down|absent|stall(s|ed|ing)?|stuck|starv[a-z]*|outages?|regressions?|leak[a-z]*|crash[a-z]*|hang(s|ed|ing)?|timeouts?|deadlock|block(s|ed|ing)?|frozen|exhaust(s|ed|ion)?|dead|wedg(e|es|ed|ing)?|drift(s|ed|ing)?)\b'

# Classify issue quality from title (and optionally body/labels).
# Prints: upgrade | repair | churn
# Based on conventional-commit prefix heuristic (fleet-ops#1136):
#   feat       -> upgrade (new forward capability)
#   fix, test  -> repair  (fixing / bulletproofing existing behaviour)
#   chore      -> churn   (no forward value)
# Prefixed titles are classified by their type token ALONE — the prefix
# mapping is authoritative and content-blind (chore: is churn even when the
# body says "broken"). An UNPREFIXED title is classified on its content:
# an unambiguous outage/defect signal (see PRECEDENCE_BAND_REPAIR_SIGNALS) in
# the title or body is repair; chore/refactor/polish/docs/rename/cleanup/tidy
# and signal-less titles stay churn. Without this, every alert-filed issue
# (plain-English title, no prefix) fell to churn and starved the #1516 surge
# valve — the starvation reports and "main is red" alerts skipped themselves.
precedence_band_classify_quality() {
    local title="${1:-}" body="${2:-}"
    # Conventional-commit prefix? "feat(scope): ...", "fix!: ...", "chore: ..."
    # If not, fall through to content-based classification below.
    if printf '%s\n' "$title" \
        | grep -qE '^[[:space:]]*[A-Za-z]+(\([^)]*\))?!?[[:space:]]*:'; then
        local prefix
        prefix="$(printf '%s\n' "$title" | sed -E 's/^\s*([A-Za-z]+)(\([^)]*\))?!?\s*:.*/\1/I' | tr '[:upper:]' '[:lower:]')"
        case "$prefix" in
            feat)     printf 'upgrade\n' ;;
            fix|test) printf 'repair\n'  ;;
            chore)    printf 'churn\n'   ;;
            *)        printf 'churn\n'   ;;
        esac
        return 0
    fi
    # No prefix: classify on content (title + body).
    if printf '%s\n%s\n' "$title" "$body" \
        | grep -qiE "$PRECEDENCE_BAND_REPAIR_SIGNALS"; then
        printf 'repair\n'
    else
        printf 'churn\n'
    fi
}

# Check if an issue qualifies as legit work (not churn-class).
# Legit work = upgrade or repair. Churn = NOT legit for surge expansion.
# Args: title [body]
precedence_band_is_legit_work() {
    local quality
    quality="$(precedence_band_classify_quality "$@")"
    [[ "$quality" == "upgrade" || "$quality" == "repair" ]]
}

precedence_band_product_front_numbers() {
    local repo="$1" json
    json="$(precedence_band_resolve_json)" || return 0
    jq -r --arg repo "$repo" '
      .product_front[]? | select(startswith($repo + "#")) | split("#")[1]
    ' "$json"
}

# Classify a pi-issue@ unit. Prints machinery|product|other.
precedence_band_classify_unit() {
    local u="$1" repo instance
    repo="${2:-fleet-ops}"
    case "$u" in
        pi-issue@*.service)
            instance="${u#pi-issue@}"
            instance="${instance%.service}"
            case "$instance" in
                "${repo}"-*) printf 'machinery\n' ;;
                *)           printf 'product\n' ;;
            esac
            ;;
        *) printf 'other\n' ;;
    esac
}

precedence_band_read_units() {
    if [[ -n "${FLEET_PRECEDENCE_UNITS_FILE:-}" && -f "$FLEET_PRECEDENCE_UNITS_FILE" ]]; then
        grep -E '^pi-issue@' "$FLEET_PRECEDENCE_UNITS_FILE" || true
        return 0
    fi
    systemctl --user list-units 'pi-issue@*.service' \
        --state=active,activating --no-legend --plain 2>/dev/null \
        | awk '{print $1}' || true
}

# Sets BAND_MACHINERY and BAND_PRODUCT from live units.
precedence_band_count_live() {
    local u kind
    BAND_MACHINERY=0
    BAND_PRODUCT=0
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        kind="$(precedence_band_classify_unit "$u")"
        case "$kind" in
            machinery) BAND_MACHINERY=$((BAND_MACHINERY + 1)) ;;
            product)   BAND_PRODUCT=$((BAND_PRODUCT + 1)) ;;
        esac
    done < <(precedence_band_read_units)
}

# Return 0 if machinery count m of total t exceeds pct.
precedence_band_over_cap() {
    local m="$1" t="$2" pct="$3"
    (( t > 0 )) || return 1
    (( m * 100 > pct * t ))
}

# Return 0 if this claim may proceed. Prints a one-token reason.
# Args: repo issue_number body [title]
precedence_band_allow_claim() {
    local repo="$1" n="$2" body="${3:-}" title="${4:-}"
    local phase pct
    # Product repos are never gated by the machinery band. Check this
    # before reading the policy so a missing config cannot stall 0509.
    if [[ "$repo" != "fleet-ops" ]]; then
        printf 'allow-product\n'
        return 0
    fi
    phase="$(precedence_band_phase)" || {
        printf 'deny-config\n'
        return 1
    }
    if [[ "$phase" == "surge" ]]; then
        if precedence_band_is_leverage_issue "$n"; then
            printf 'allow-surge-leverage\n'
            return 0
        fi
        printf 'skip-surge-leverage\n'
        return 1
    fi
    pct="$(precedence_band_max_pct)"
    precedence_band_count_live
    BAND_PENDING_MACHINERY="$(precedence_band_pending_get)"
    # Bootstrap exception (auditor 2026-08-28, summon unit-failure
    # fleet-heartbeat): when nothing is live (BAND_MACHINERY + BAND_PRODUCT
    # == 0), the first claim cannot violate the machinery share — 30% of 0
    # is 0, and the ratio constraint is meaningless with no running units.
    # Without this, the band phase deadlocks: the first machinery claim
    # makes it 100% > 30% → skip-band, so machinery can never start when
    # product is all blocked-on.
    if (( BAND_MACHINERY + BAND_PRODUCT == 0 && BAND_PENDING_MACHINERY == 0 )); then
        precedence_band_pending_set
        printf 'allow-band-bootstrap\n'
        return 0
    fi
    # Machinery floor (fleet-ops#1452): the 0-live bootstrap does not cover
    # the low-n case. Overnight 2026-08-27→28, 1-2 product units were live
    # and every machinery claim computed as 1/(1+N) > 30% (N=1 → 50%,
    # N=2 → 33%), so the whole repair queue was skipped-precedence-band —
    # including the starvation reports themselves. One repair lane may
    # always run when live machinery == 0. Ratio enforcement resumes from
    # the second machinery unit. BAND_PENDING_MACHINERY is the intra-tick
    # latch: pi-intake-tick starts workers --no-block, so systemd may not
    # list the new unit before the next ready issue is considered. Without
    # the latch the floor would dump the whole overnight queue.
    if (( BAND_MACHINERY == 0 && BAND_PENDING_MACHINERY == 0 )); then
        precedence_band_pending_set
        printf 'allow-band-floor\n'
        return 0
    fi
    if precedence_band_over_cap "$((BAND_MACHINERY + BAND_PENDING_MACHINERY + 1))" "$((BAND_MACHINERY + BAND_PRODUCT + BAND_PENDING_MACHINERY + 1))" "$pct"; then
        # Empty-product surge expansion (fleet-ops#1516): when product-ready
        # is empty (or below claimable count), machinery may expand beyond
        # machinery_max_pct up to full capacity — BUT only for legit work.
        # Legit work = upgrade or repair (passes existing spec/quality gates).
        # Churn-class (chore, refactor, polish, machinery-on-machinery) does
        # NOT qualify. The legit-work guard is fleet-wide (global standing
        # rule 2026-08-28).
        if (( BAND_PRODUCT == 0 )) && precedence_band_is_legit_work "$title" "$body"; then
            printf 'allow-band-surge-legit\n'
            return 0
        fi
        if precedence_band_has_multiplier "$body"; then
            printf 'allow-multiplier\n'
            return 0
        fi
        printf 'skip-band\n'
        return 1
    fi
    printf 'allow-band\n'
    return 0
}
