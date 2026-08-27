# shellcheck shell=bash
# precedence-band.sh — rent-paying band + overnight surge (fleet-ops#1223).
#
# Sourced by pi-intake-tick and fleet-precedence-band-canary. Not executed.
#
# Ledger 2026-08-27 | Precedence band + overnight machinery surge (Nish):
#   Until 2026-08-28 08:00 IST (cutoff_utc): GO HAM, leverage-ranked only.
#   After: machinery capped at ~30% of live pi-issue@ lanes; product 70%
#   with product_front first. A machinery issue jumps the band only by
#   naming `band-multiplier: N` on its body. Weekly Fleet Review owns
#   machinery_max_pct / product_min_pct (tighten only).
#
# Environment (tests):
#   PRECEDENCE_BAND_JSON         config/precedence-band.json
#   PRECEDENCE_BAND_NOW          ISO-8601 UTC clock (default: live date -u)
#   FLEET_PRECEDENCE_UNITS_FILE  one pi-issue@ unit name per line

PRECEDENCE_BAND_JSON="${PRECEDENCE_BAND_JSON:-}"
PRECEDENCE_BAND_NOW="${PRECEDENCE_BAND_NOW:-}"

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
# Args: repo issue_number body
precedence_band_allow_claim() {
    local repo="$1" n="$2" body="${3:-}"
    local phase pct
    phase="$(precedence_band_phase)" || {
        printf 'deny-config\n'
        return 1
    }
    if [[ "$repo" != "fleet-ops" ]]; then
        printf 'allow-product\n'
        return 0
    fi
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
    if precedence_band_over_cap "$((BAND_MACHINERY + 1))" "$((BAND_MACHINERY + BAND_PRODUCT + 1))" "$pct"; then
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
