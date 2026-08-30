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
#   machinery unit. A machinery issue jumps the band only by carrying
#   a `priority` or `emergency` label. Weekly Fleet Review owns
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

# Starvation floor latch (fleet-ops#1448). Separate from BAND_PENDING_FILE
# so the one-lane starvation reservation does not consume the machinery
# floor latch (they are independent one-lane reservations in different
# failure modes).
precedence_band_pending_starvation_file() {
    printf '%s\n' "${BAND_PENDING_STARVATION_FILE:-${XDG_RUNTIME_DIR:-/tmp}/precedence-band-pending-starvation.$$}"
}
precedence_band_pending_starvation_get() {
    if [[ -f "$(precedence_band_pending_starvation_file)" ]]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}
precedence_band_pending_starvation_set() {
    local f dir
    f="$(precedence_band_pending_starvation_file)"
    dir="$(dirname "$f")"
    mkdir -p "$dir"
    : >"$f"
}
precedence_band_pending_starvation_clear() {
    rm -f "$(precedence_band_pending_starvation_file)"
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

PRECEDENCE_BAND_PRIORITY_LABEL="${PRECEDENCE_BAND_PRIORITY_LABEL:-priority}"
PRECEDENCE_BAND_EMERGENCY_LABEL="${PRECEDENCE_BAND_EMERGENCY_LABEL:-emergency}"

# Check if issue has a band-multiplier label (priority/emergency).
# Args: labels_json (from gh issue list --json labels)
precedence_band_has_multiplier() {
    local labels_json="$1"
    local priority="$PRECEDENCE_BAND_PRIORITY_LABEL"
    local emergency="$PRECEDENCE_BAND_EMERGENCY_LABEL"
    printf '%s\n' "$labels_json" | jq -e --arg p "$priority" --arg e "$emergency" '
      .[]? | select(.name == $p or .name == $e) | .name
    ' >/dev/null
}
# Detect starvation-class issues: meta-issues reporting the dispatch/claim
# pipeline is not consuming the ready queue. These differ from regular
# repair issues (specific code bugs) in that they diagnose the throttle
# itself. fleet-ops#1448: such issues must be floor-eligible so the
# machinery cap cannot lock out the very diagnostic that would unstick
# the queue. Uses the same signal set as classify_quality for repair
# classification, but additionally requires a dispatch/claim pipeline
# signal (ready_work, dispatches, claims, at-capacity, empty runs, etc.)
# to avoid promoting every outage issue into the starvation floor.
# Args: title body
precedence_band_is_starvation_issue() {
    local title="${1:-}" body="${2:-}"
    printf '%s\n%s\n' "$title" "$body" \
        | grep -qiE "$PRECEDENCE_BAND_STARVATION_SIGNALS"
}

# Outage/defect signals that promote an UNPREFIXED title to repair. When a
# title carries no conventional-commit prefix, its content (title + body) is
# scanned for these; a hit is repair, anything else is churn. Prefixed titles
# keep their prefix mapping regardless of body (chore: stays churn even if the
# body says "broken") — the legit-work guard (fleet-ops#1516) depends on this.
PRECEDENCE_BAND_REPAIR_SIGNALS='\b(red|fail(s|ed|ing|ure|ures)?|broken|down|absent|stall(s|ed|ing)?|stuck|starv[a-z]*|outages?|regressions?|leak[a-z]*|crash[a-z]*|hang(s|ed|ing)?|timeouts?|deadlock|block(s|ed|ing)?|frozen|exhaust(s|ed|ion)?|dead|wedg(e|es|ed|ing)?|drift(s|ed|ing)?)\b'

# Starvation-class signals: issues that report the dispatch/claim pipeline
# is not consuming the ready queue. These are metacompact — they exist
# because the fleet can't process its own backlog. Unlike regular repair
# issues (a specific code bug), starvation issues must be floor-eligible:
# they diagnose and fix the throttle itself, so locking them behind the
# machinery cap when the cap is already consumed re-creates the deadlock.
# fleet-ops#1448: "consider starvation-class issues as floor-eligible."
# Scans title + body for dispatch/claim pipeline stall signals.
PRECEDENCE_BAND_STARVATION_SIGNALS='\b(starv|starved|starvation|dispatcher.*idle|idle.*dispatcher|queue.*starv|starv.*queue|dispatch.*starv|intake.*starv|starv.*intake|claim.*starv|starv.*claim|no.*dispatch|no.*claim|skips|at[-_]capacity|ready_work|ready.*items?|dispatches?.*2h|claims?.*2h|empty.*run|no.op|outflow.*0|dispatch.*stalled|claim.*stalled|pipeline.*stalled)\b'

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
            # ci: is repair-class — wiring a test into CI bulletproofs the
            # existing build, same forward value as test: (fleet-ops#2133:
            # the 0509 ci: queue was the all-blocked-on product side that
            # stranded the fleet at 100% machinery). chore stays churn.
            ci)       printf 'repair\n'  ;;
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

# Explicit-churn detector (fleet-ops#2133). The empty-product surge valve
# (fleet-ops#1516) admits legit work when no product is live, but the
# legit-work guard alone is not enough to keep the queue moving: a
# machinery repo with NO product live AND only churn-class machinery ready
# still skip-bands every issue, and the fleet stays wedged at 100%
# machinery below the 25-worker floor. The deadlock is the band cap
# itself (30% of 0 product = 0 machinery), not the work quality. When
# product is empty AND every over-cap machinery claim is non-churn (not
# just upgrade/repair — also plain-English audit/gap/mechanism titles
# that the prefix classifier reads as churn but are real backlog), the
# band must admit one lane so the queue never hard-stalls. This helper is
# the negative check: it returns 0 (true) only when the title/body is
# EXPLICITLY churn (chore/refactor/polish/docs/rename/cleanup/tidy prefix
# or a churn keyword), so the surge valve can admit everything else.
# Args: title [body]
precedence_band_is_explicit_churn() {
    local title="${1:-}" body="${2:-}"
    # Prefixed churn types are authoritative (chore: stays churn even if
    # the body says "broken") — mirrors classify_quality's contract.
    if printf '%s\n' "$title" \
        | grep -qE '^[[:space:]]*[A-Za-z]+(\([^)]*\))?!?[[:space:]]*:'; then
        local prefix
        prefix="$(printf '%s\n' "$title" | sed -E 's/^\s*([A-Za-z]+)(\([^)]*\))?!?\s*:.*/\1/I' | tr '[:upper:]' '[:lower:]')"
        case "$prefix" in
            chore|refactor|polish|docs|doc|rename|cleanup|tidy|style|format) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # No prefix: explicit-churn keywords in title/body. Conservative —
    # only obvious housekeeping words; everything else is admitted.
    printf '%s\n%s\n' "$title" "$body" \
        | grep -qiE '\b(tidy|cleanup|clean[- ]?up|polish|rename|reformat|format only|whitespace|cosmetic)\b'
}

precedence_band_product_front_numbers() {
    local repo="$1" json
    json="$(precedence_band_resolve_json)" || return 0
    jq -r --arg repo "$repo" '
      .product_front[]? | select(startswith($repo + "#")) | split("#")[1]
    ' "$json"
}

# Admit floor for the empty-product below-floor valve (fleet-ops#2133).
# Mirrors seat-lib.sh admit_ceiling = min(target_concurrent, ram_governor_cap),
# but this lib is also sourced standalone by the canary/tests (no seat-lib),
# so it calls admit_ceiling when that function is defined (intake-tick context)
# and falls back to FLEET_PRECEDENCE_ADMIT_FLOOR (test seam) or 25 (the
# standing light-workload target, fleet-ops#1558) otherwise. Never fails.
precedence_band_admit_floor() {
    if [[ -n "${FLEET_PRECEDENCE_ADMIT_FLOOR:-}" ]]; then
        printf '%s\n' "$FLEET_PRECEDENCE_ADMIT_FLOOR"
        return 0
    fi
    if declare -F admit_ceiling >/dev/null 2>&1; then
        admit_ceiling 2>/dev/null || echo 25
        return 0
    fi
    echo 25
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
    local repo="$1" n="$2" labels_json="${3:-}" body="${4:-}" title="${5:-}"
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
        # Surge floor (fleet-ops#1431): the surge hold is leverage-only, so
        # when no surge_leverage_issue is still claimable (all claimed / blocked
        # / done) a pure skip leaves the fleet-ops queue at 0 dispatches for up
        # to the whole surge window. Watchers read that hard 0-outflow as
        # "dispatcher starvation" and auto-file a false issue cluster. Mirror
        # the band-phase machinery floor (#1452/#1474): allow exactly one
        # machinery/repair lane when live machinery == 0, latched for the rest
        # of the tick, so the queue can never hard-stall through a surge.
        # Leverage issues still take strict precedence; the floor only opens
        # when there is no surge work left, and grants ONE lane, not the 30%
        # band share — a deliberate surge hold stays a hold otherwise.
        precedence_band_count_live
        BAND_PENDING_MACHINERY="$(precedence_band_pending_get)"
        if (( BAND_MACHINERY == 0 && BAND_PENDING_MACHINERY == 0 )); then
            precedence_band_pending_set
            printf 'allow-surge-floor\n'
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
        # Empty-product below-floor valve (fleet-ops#2133): the legit-work
        # guard above admits upgrade/repair, but a machinery repo whose
        # ready queue is plain-English audit/gap/mechanism titles (no
        # conventional-commit prefix, no outage keyword) reads as churn
        # under classify_quality and skip-bands — stranding the fleet at
        # 100% machinery below the 25-worker floor with no product live
        # to open the ratio. The deadlock is the band cap (30% of 0
        # product = 0 machinery), not the work quality. When product is
        # empty AND the fleet is below the admit floor (total live <
        # admit_ceiling), admit one lane per eligible issue for anything
        # that is NOT explicit churn (chore/refactor/polish/docs/rename/
        # cleanup/tidy) AND has a non-empty title (safe catch-all), so
        # the queue never hard-stalls below the floor. At/above the floor
        # the strict #1516 legit-work guard holds (no broad admission).
        # Not latched (mirrors the #1516 legit valve): the band's job is
        # eligibility, and pi-intake-tick's own `slots = total_cap -
        # active` capacity gate bounds how many claims fire this tick.
        if (( BAND_PRODUCT == 0 )); then
            local _admit_floor _total_live
            _admit_floor="$(precedence_band_admit_floor)"
            _total_live=$(( BAND_MACHINERY + BAND_PRODUCT ))
            if (( _total_live < _admit_floor )) \
                    && [[ -n "${title// }" ]] \
                    && ! precedence_band_is_explicit_churn "$title" "$body"; then
                printf 'allow-band-surge-empty\n'
                return 0
            fi
        fi
        if precedence_band_has_multiplier "$labels_json"; then
            printf 'allow-multiplier\n'
            return 0
        fi
        # Starvation floor (fleet-ops#1448): when the machinery cap is already
        # consumed by emergency dispatches and product lanes are saturated,
        # starvation-class issues (dispatch/claim pipeline not consuming the
        # queue) must still get exactly ONE lane per tick to diagnose and
        # unstick the throttle. Without this, the machinery floor (one lane,
        # held by a long-running worker at 06:20Z) and band-multiplier (one lane,
        # insufficient when the doubled cap is already consumed) leave the
        # queue permanently stalled. Uses a separate latch from the machinery
        # floor so the two one-lane reservations do not collide.
        if precedence_band_is_starvation_issue "$title" "$body"; then
            BAND_PENDING_STARVATION="$(precedence_band_pending_starvation_get)"
            if (( BAND_PENDING_STARVATION == 0 )); then
                precedence_band_pending_starvation_set
                printf 'allow-starvation-floor\n'
                return 0
            fi
        fi
        printf 'skip-band\n'
        return 1
    fi
    printf 'allow-band\n'
    return 0
}
