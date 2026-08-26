#!/usr/bin/env bash
# rulebook-redteam-cadence — heartbeat canary + heading-growth bonus
# (fleet-ops#527).
#
# Sourced by bin/fleet-heartbeat-tier1 §39. Also runnable:
#   PLAN_FILE=... FLEET_HEARTBEAT_TRIAGE=... \
#     bash lib/rulebook-redteam-cadence.sh
#
# Cadence: reads last-rulebook-redteam-run: from $PLAN_FILE (written by
# bin/fleet-rulebook-redteam on start and on every terminal point) and
# emits a LOUD RULEBOOK-REDTEAM-CADENCE-OVERDUE triage line when the
# stamp is missing, unreadable, unparseable, or older than
# RULEBOOK_CADENCE_MAX_AGE_S (default 3024000 = 35d: monthly floor +
# 5d grace for RandomizedDelaySec, Persistent missed-tick slop, and
# the 45min reviewer wall-clock).
#
# Heading bonus: if STANDING_RULES gained ## headings since the last
# successful run, start fleet-rulebook-redteam.service --no-block.
# The monthly timer remains the primary trigger; this never lengthens
# the cadence. A start failure is LOUD, never a silent skip.
#
# Pure observer for the overdue half. Never bypasses the monthly timer.
#
# Test overrides: RULEBOOK_CADENCE_MAX_AGE_S RULEBOOK_CADENCE_DISABLE
#   RULEBOOK_HEADING_BONUS_DISABLE PLAN_FILE FLEET_HEARTBEAT_TRIAGE
#   RULEBOOK_STANDING_RULES RULEBOOK_STATE_DIR RULEBOOK_REDTEAM_UNIT
#   SYSTEMCTL

_rulebook_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$*"
        return
    fi
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

_rulebook_loud() {
    local tag="$1"; shift
    if declare -F loud >/dev/null 2>&1; then
        loud "$tag" "$*"
        return
    fi
    local triage="${FLEET_HEARTBEAT_TRIAGE:-${TRIAGE:-/dev/null}}"
    _rulebook_log "LOUD [$tag] $*"
    {
        printf '\n[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$*"
    } >> "$triage" 2>/dev/null || _rulebook_log "WARN: could not append to triage $triage"
}

heartbeat_rulebook_redteam_cadence_canary() {
    rulebook_canary_status="ok"
    rulebook_canary_age_s="-"
    if [ "${RULEBOOK_CADENCE_DISABLE:-0}" = "1" ]; then
        rulebook_canary_status="disabled"
        _rulebook_log "39. rulebook red-team cadence canary DISABLED (RULEBOOK_CADENCE_DISABLE=1)"
        return 0
    fi

    local max_age_s="${RULEBOOK_CADENCE_MAX_AGE_S:-3024000}"
    local plan="${PLAN_FILE:-}"
    if [ -z "$plan" ] || [ ! -f "$plan" ]; then
        rulebook_canary_status="missing-plan"
        _rulebook_loud "RULEBOOK-REDTEAM-CADENCE-OVERDUE" \
            "plan file missing at ${plan:-unset} — last-rulebook-redteam-run stamp unreadable (fleet-rulebook-redteam has nowhere to write; monthly floor unverifiable)"
        _rulebook_log "39. rulebook red-team cadence canary: status=$rulebook_canary_status age=${rulebook_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    local stamp
    stamp="$(grep -E '^last-rulebook-redteam-run:' "$plan" 2>/dev/null | tail -n 1 | sed -E 's/^last-rulebook-redteam-run:[[:space:]]+//' | awk '{print $1}' || true)"
    if [ -z "$stamp" ]; then
        rulebook_canary_status="never-ran"
        _rulebook_loud "RULEBOOK-REDTEAM-CADENCE-OVERDUE" \
            "no last-rulebook-redteam-run stamp in $plan — red-team has never run (or its stamps have been wiped); monthly timer alone may be silently broken"
        _rulebook_log "39. rulebook red-team cadence canary: status=$rulebook_canary_status age=${rulebook_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    local now_s stamp_s
    now_s="$(date -u +%s)"
    stamp_s="$(date -u -d "$stamp" +%s 2>/dev/null || echo 0)"
    if [ "$stamp_s" -eq 0 ]; then
        rulebook_canary_status="unparseable-stamp"
        _rulebook_loud "RULEBOOK-REDTEAM-CADENCE-OVERDUE" \
            "last-rulebook-redteam-run stamp '$stamp' is not parseable by date(1) — monthly cadence cannot be verified"
        _rulebook_log "39. rulebook red-team cadence canary: status=$rulebook_canary_status age=${rulebook_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    local age_s=$(( now_s - stamp_s ))
    rulebook_canary_age_s="$age_s"
    if [ "$age_s" -gt "$max_age_s" ]; then
        local age_d=$(( age_s / 86400 ))
        local limit_d=$(( max_age_s / 86400 ))
        rulebook_canary_status="overdue"
        _rulebook_loud "RULEBOOK-REDTEAM-CADENCE-OVERDUE" \
            "red-team last ran ${age_d}d ago (limit ${limit_d}d, stamp='$stamp') — monthly floor is not firing; heading-growth dispatch or systemd timer is broken; manual systemctl --user start fleet-rulebook-redteam.service required"
    fi
    _rulebook_log "39. rulebook red-team cadence canary: status=$rulebook_canary_status age=${rulebook_canary_age_s}s limit=${max_age_s}s"
    return 0
}

heartbeat_rulebook_redteam_heading_bonus() {
    rulebook_heading_bonus="skip"
    if [ "${RULEBOOK_HEADING_BONUS_DISABLE:-0}" = "1" ]; then
        rulebook_heading_bonus="disabled"
        _rulebook_log "39. heading-growth bonus DISABLED"
        return 0
    fi
    local rules="${RULEBOOK_STANDING_RULES:-/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md}"
    local state_dir="${RULEBOOK_STATE_DIR:-/home/nish/workspaces/agent-state/fleet-rulebook-redteam}"
    local unit="${RULEBOOK_REDTEAM_UNIT:-fleet-rulebook-redteam.service}"
    local systemctl_bin="${SYSTEMCTL:-systemctl}"
    if [ ! -f "$rules" ]; then
        rulebook_heading_bonus="missing-rules"
        _rulebook_log "39. heading-growth bonus: standing-rules missing at $rules"
        return 0
    fi
    local now_n last_n=0
    now_n="$(grep -cE '^## ' "$rules" 2>/dev/null || true)"
    now_n="${now_n:-0}"
    if [ -f "$state_dir/last-heading-count" ]; then
        last_n="$(tr -cd '0-9' <"$state_dir/last-heading-count" || true)"
        last_n="${last_n:-0}"
    fi
    if [ "$now_n" -le "$last_n" ]; then
        rulebook_heading_bonus="no-growth"
        _rulebook_log "39. heading-growth bonus: headings=$now_n last=$last_n — no start"
        return 0
    fi
    local unit_state
    unit_state=$("$systemctl_bin" --user is-active "$unit" 2>/dev/null || echo unknown)
    case "$unit_state" in
        active|activating)
            rulebook_heading_bonus="already-running"
            _rulebook_log "39. heading-growth bonus: $unit is $unit_state — no-op"
            return 0
            ;;
    esac
    if "$systemctl_bin" --user start --no-block "$unit" >/dev/null 2>&1; then
        rulebook_heading_bonus="started"
        _rulebook_log "39. heading-growth bonus: started $unit (headings $last_n -> $now_n)"
    else
        rulebook_heading_bonus="start-fail"
        _rulebook_loud "RULEBOOK-REDTEAM-START-FAIL" \
            "systemctl start $unit failed after standing-rules headings grew $last_n -> $now_n"
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    heartbeat_rulebook_redteam_cadence_canary
    heartbeat_rulebook_redteam_heading_bonus
fi
