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

# Main-red floor latch (fleet-ops#2911). Separate from the machinery and
# starvation latches so a P14/main-CI-red repair can still take one lane
# per tick while product-first hold is spending the machinery floor on
# the lowest-number ready issue.
precedence_band_pending_main_red_file() {
    printf '%s\n' "${BAND_PENDING_MAIN_RED_FILE:-${XDG_RUNTIME_DIR:-/tmp}/precedence-band-pending-main-red.$$}"
}
precedence_band_pending_main_red_get() {
    if [[ -f "$(precedence_band_pending_main_red_file)" ]]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}
precedence_band_pending_main_red_set() {
    local f dir
    f="$(precedence_band_pending_main_red_file)"
    dir="$(dirname "$f")"
    mkdir -p "$dir"
    : >"$f"
}
precedence_band_pending_main_red_clear() {
    rm -f "$(precedence_band_pending_main_red_file)"
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
PRECEDENCE_BAND_REPAIR_SIGNALS='\b(red|fail(s|ed|ing)?|broken|down|absent|stall(s|ed|ing)?|stuck|starv[a-z]*|outages?|regressions?|leak[a-z]*|crash[a-z]*|hang(s|ed|ing)?|timeouts?|deadlock|block(s|ed|ing)?|frozen|exhaust(s|ed|ion)?|dead|wedg(e|es|ed|ing)?|drift(s|ed|ing)?)\b'

# Starvation-class signals: issues that report the dispatch/claim pipeline
# is not consuming the ready queue. These are metacompact — they exist
# because the fleet can't process its own backlog. Unlike regular repair
# issues (a specific code bug), starvation issues must be floor-eligible:
# they diagnose and fix the throttle itself, so locking them behind the
# machinery cap when the cap is already consumed re-creates the deadlock.
# fleet-ops#1448: "consider starvation-class issues as floor-eligible."
# Scans title + body for dispatch/claim pipeline stall signals.
PRECEDENCE_BAND_STARVATION_SIGNALS='\b(starv|starved|starvation|dispatcher.*idle|idle.*dispatcher|queue.*starv|starv.*queue|dispatch.*starv|intake.*starv|starv.*intake|claim.*starv|starv.*claim|no.*dispatch|no.*claim|skips|at[-_]capacity|ready_work|ready.*items?|dispatches?.*2h|claims?.*2h|empty.*run|no.op|outflow.*0|dispatch.*stalled|claim.*stalled|pipeline.*stalled)\b'

# Main-red-class signals (fleet-ops#2911): issues whose job is to turn
# fleet-ops default-branch CI green. Product-first hold spends its one
# machinery-floor lane on the lowest-number ready issue; these sat
# skipped-product-first-held (or unlabeled via spec-gate) for 5h+ while
# undersat_rc=0. Scans title + body. Case-insensitive.
PRECEDENCE_BAND_MAIN_RED_SIGNALS='\b(p14|listing[- ]gate|unhosted|FleetMainRed|main CI red|gate red on main|P14 reachable)\b'

precedence_band_is_main_red_issue() {
    local title="${1:-}" body="${2:-}"
    printf '%s\n%s\n' "$title" "$body" \
        | grep -qiE "$PRECEDENCE_BAND_MAIN_RED_SIGNALS"
}

# Prom file for fleet_main_ci_green. Tests inject FLEET_MAIN_CI_PROM.
# Missing file is unavailable (floor does not fire — fail-open to product).
precedence_band_main_ci_prom() {
    if [[ -n "${FLEET_MAIN_CI_PROM:-}" ]]; then
        [[ -f "$FLEET_MAIN_CI_PROM" ]] || return 1
        printf '%s\n' "$FLEET_MAIN_CI_PROM"
        return 0
    fi
    local p="/var/lib/prometheus/node-exporter/fleet.prom"
    [[ -f "$p" ]] || return 1
    printf '%s\n' "$p"
}

# Return 0 when fleet-ops default-branch CI is red (gauge == 0).
# Return 1 (not red) when the prom is missing, unparseable, or green so
# a dead exporter cannot steal a product lane.
precedence_band_fleet_ops_main_ci_red() {
    local prom line val
    prom="$(precedence_band_main_ci_prom)" || return 1
    line="$(grep -E '^fleet_main_ci_green\{[^}]*repo="(Nishfleet/)?fleet-ops"' "$prom" 2>/dev/null | head -1)" || return 1
    [[ -n "$line" ]] || return 1
    val="${line##* }"
    [[ "$val" == "0" || "$val" == "0.0" ]]
}

# One-lane reservation while fleet-ops main is red (fleet-ops#2911).
# Prints allow-main-red-floor and returns 0 when the lane is granted;
# returns 1 when the issue is not a main-red repair, CI is not red, or
# the latch is already spent this tick.
precedence_band_try_main_red_floor() {
    local title="${1:-}" body="${2:-}"
    local pending
    precedence_band_fleet_ops_main_ci_red || return 1
    precedence_band_is_main_red_issue "$title" "$body" || return 1
    pending="$(precedence_band_pending_main_red_get)"
    [[ "$pending" == "0" ]] || return 1
    precedence_band_pending_main_red_set
    printf 'allow-main-red-floor\n'
    return 0
}

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
        # Main-red floor (fleet-ops#2911) also fires in surge: a P14 repair
        # is not a surge_leverage_issue, so without this the 5h red-on-main
        # stall repeats through a leftover surge window.
        if precedence_band_try_main_red_floor "$title" "$body"; then
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
        # Main-red floor (fleet-ops#2911): when default-branch CI is red,
        # a P14/hosting/FleetMainRed repair gets one reserved lane even if
        # the machinery floor was already spent on a lower-number issue.
        if precedence_band_try_main_red_floor "$title" "$body"; then
            return 0
        fi
        printf 'skip-band\n'
        return 1
    fi
    # In-cap path (fleet-ops#2911): product-first hold still skips
    # allow-band. A P14/main-CI-red repair must surface as
    # allow-main-red-floor so the hold gate admits it while main is red.
    if precedence_band_try_main_red_floor "$title" "$body"; then
        return 0
    fi
    printf 'allow-band\n'
    return 0
}

# === Product-first precedence (fleet-ops#2519) ===
# When the queue self-maintenance ratio exceeds PRODUCT_FIRST_SELF_RATIO_MAX,
# the intake tick holds the self-maintenance repo (fleet-ops) in the intake
# buffer: its agent-ready issues are not admitted to the dispatch queue, so
# fleet capacity goes to product repos. Product repos are never gated. Fails
# open (admit) when the queue composition cache is unavailable, so a dead
# metrics exporter never freezes the fleet.
#
# Environment (tests):
#   PRODUCT_FIRST_QUEUE_CACHE    queue-composition-cache.json (default:
#                                agent-state/fleet-metrics)
#   PRODUCT_FIRST_QUEUE          which queue ratio gates admission
#                                (default: agent-ready)
#   PRODUCT_FIRST_SELF_RATIO_MAX threshold (default: 0.5)
#   SELF_MAINT_REPOS_JSON        self-maintenance repos (default:
#                                config/self-maintenance-repos.json)
#   PRODUCT_FIRST_PROM           prom path for fleet_queue_product_ratio
PRODUCT_FIRST_SELF_RATIO_MAX="${PRODUCT_FIRST_SELF_RATIO_MAX:-0.5}"
PRODUCT_FIRST_QUEUE="${PRODUCT_FIRST_QUEUE:-agent-ready}"
PRODUCT_FIRST_QUEUE_CACHE="${PRODUCT_FIRST_QUEUE_CACHE:-}"
SELF_MAINT_REPOS_JSON="${SELF_MAINT_REPOS_JSON:-}"

product_first_resolve_queue_cache() {
    # An explicitly-set PRODUCT_FIRST_QUEUE_CACHE is the operator's chosen
    # source of truth; missing means unavailable, not "fall back to live".
    # Without this, an override path that does not exist would silently
    # pull the live system cache and invert the fail-open contract (an
    # unavailable cache must admit, not serve numbers).
    if [[ -n "$PRODUCT_FIRST_QUEUE_CACHE" ]]; then
        [[ -f "$PRODUCT_FIRST_QUEUE_CACHE" ]] || return 1
        printf '%s\n' "$PRODUCT_FIRST_QUEUE_CACHE"
        return 0
    fi
    local p="/home/nish/workspaces/agent-state/fleet-metrics/queue-composition-cache.json"
    if [[ -f "$p" ]]; then
        printf '%s\n' "$p"
        return 0
    fi
    return 1
}

# Print "SELF TOTAL" for PRODUCT_FIRST_QUEUE from the cache. Returns 1 on
# unavailable cache or unparseable/total=0 data.
product_first_queue_counts() {
    local cache
    cache="$(product_first_resolve_queue_cache)" || return 1
    jq -r --arg q "$PRODUCT_FIRST_QUEUE" '.data[$q] | "\(.self) \(.total)"' "$cache" \
        2>/dev/null || return 1
}

# Print the self-maintenance ratio (0..1) for PRODUCT_FIRST_QUEUE.
# Returns 1 on unavailable cache or total=0.
product_first_ratio() {
    local counts self total
    counts="$(product_first_queue_counts)" || return 1
    self="${counts%% *}"
    total="${counts##* }"
    [[ "$self" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] || return 1
    awk -v s="$self" -v t="$total" 'BEGIN{printf "%.6f", s/t}'
}

# Print the product ratio (1 - self-maintenance ratio) for
# PRODUCT_FIRST_QUEUE. Returns 1 on unavailable cache or total=0.
product_first_product_ratio() {
    local r
    r="$(product_first_ratio)" || return 1
    awk -v r="$r" 'BEGIN{printf "%.6f", 1-r}'
}

# Return 0 (HOLD product-first precedence) when the self-maintenance ratio
# exceeds the max; 1 (ADMIT) otherwise or when the ratio is unavailable.
product_first_hold() {
    local r
    r="$(product_first_ratio)" || return 1
    awk -v r="$r" -v m="$PRODUCT_FIRST_SELF_RATIO_MAX" 'BEGIN{exit !(r > m)}'
}

# Return 0 if $1 is a self-maintenance repo
# (config/self-maintenance-repos.json); 1 otherwise.
product_first_is_self_maintenance() {
    local repo="$1" json
    if [[ -n "$SELF_MAINT_REPOS_JSON" && -f "$SELF_MAINT_REPOS_JSON" ]]; then
        json="$SELF_MAINT_REPOS_JSON"
    elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/self-maintenance-repos.json" ]]; then
        json="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/self-maintenance-repos.json"
    else
        json=""
    fi
    if [[ -n "$json" ]]; then
        jq -e --arg r "$repo" '.repos | index($r) != null' "$json" >/dev/null 2>&1
    else
        [[ "$repo" == "fleet-ops" ]]
    fi
}

# Best-effort export of fleet_queue_product_ratio for PRODUCT_FIRST_QUEUE to
# a prom file. Called by the intake tick so the metric is written even when
# the product-first precedence is currently holding (observability).
product_first_export_product_ratio() {
    local out="${PRODUCT_FIRST_PROM:-/var/lib/prometheus/node-exporter/fleet-queue-product-ratio.prom}"
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    local pr
    if pr="$(product_first_product_ratio)"; then
        {
            printf '# HELP fleet_queue_product_ratio Product / total agent-ready issues by queue. 1 - self-maintenance_ratio (fleet-ops#2519).\n'
            printf '# TYPE fleet_queue_product_ratio gauge\n'
            printf 'fleet_queue_product_ratio{queue="%s"} %s\n' "$PRODUCT_FIRST_QUEUE" "$pr"
        } > "$out.tmp.$$" 2>/dev/null || return 0
        mv "$out.tmp.$$" "$out" 2>/dev/null || true
    fi
}
