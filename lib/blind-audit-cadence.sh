#!/usr/bin/env bash
# blind-audit-cadence — heartbeat canary for a stuck mechanical audit
# (fleet-ops#378).
#
# Sourced by bin/fleet-heartbeat-tier1 §11. Also runnable:
#   PLAN_FILE=... FLEET_HEARTBEAT_TRIAGE=... \
#     bash lib/blind-audit-cadence.sh
#
# Reads last-blind-audit-run: from $PLAN_FILE (written by bin/fleet-blind-audit
# on start and on every terminal point) and emits a LOUD
# BLIND-AUDIT-CADENCE-OVERDUE triage line when the stamp is missing, unreadable,
# unparseable, or older than AUDIT_CADENCE_MAX_AGE_S (default 108000 = 30h:
# 24h daily floor + 6h grace for RandomizedDelaySec, Persistent missed-tick
# slop, and the 45min reviewer wall-clock).
#
# Pure observer. Never starts the audit, never bypasses the daily timer.
# Sets audit_canary_status and audit_canary_age_s for the caller's tick log.
#
# Test overrides: AUDIT_CADENCE_MAX_AGE_S AUDIT_CADENCE_DISABLE PLAN_FILE
#   FLEET_HEARTBEAT_TRIAGE (via the caller's loud()).

_cadence_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$*"
        return
    fi
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

_cadence_loud() {
    local tag="$1"; shift
    if declare -F loud >/dev/null 2>&1; then
        loud "$tag" "$*"
        return
    fi
    local triage="${FLEET_HEARTBEAT_TRIAGE:-${TRIAGE:-/dev/null}}"
    _cadence_log "LOUD [$tag] $*"
    {
        printf '\n[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$*"
    } >> "$triage" 2>/dev/null || _cadence_log "WARN: could not append to triage $triage"
}

_cadence_timeout_guard() {
    # fleet-ops#5780: report a fleet-blind-audit run that SIGTERMed on its
    # TimeoutStartSec in the last 24h (ExecMainStatus=15/TERM). The tier1
    # cadence canary stays the detector; this drills the guard so an audit
    # killed mid-filing cannot pass silently. Tests replay a fixture via
    # FLEET_BLIND_AUDIT_JOURNAL_CMD. The live tick (fleet-heartbeat-tier1
    # section 11) exports that override; standalone callers (tests) must
    # provide it too, or the guard stays silent rather than depending on a
    # live journalctl on every host.
    audit_canary_timeout="unchecked"
    [ "${AUDIT_CADENCE_TIMEOUT_DISABLE:-0}" = "1" ] && return 0
    if [ -z "${FLEET_BLIND_AUDIT_JOURNAL_CMD:-}" ]; then
        return 0
    fi
    local cmd="${FLEET_BLIND_AUDIT_JOURNAL_CMD:-journalctl --user -u fleet-blind-audit.service --since -24h --no-pager}"
    local journal_out
    journal_out=$(bash -c "$cmd" 2>/dev/null || true)
    audit_canary_timeout="none"
    [ -n "$journal_out" ] || return 0
    if printf '%s\n' "$journal_out" | grep -q 'status=15/TERM'; then
        audit_canary_timeout="term-timeout"
        audit_canary_status="timeout-term"
        _cadence_loud "BLIND-AUDIT-TIMEOUT-TERM" \
            "fleet-blind-audit terminated with status=15/TERM (TimeoutStartSec) in the last 24h — findings went unfiled; filing budget must be fixed (fleet-ops#5780)"
    fi
}

heartbeat_blind_audit_cadence_canary() {
    audit_canary_status="ok"
    audit_canary_age_s="-"
    if [ "${AUDIT_CADENCE_DISABLE:-0}" = "1" ]; then
        audit_canary_status="disabled"
        _cadence_log "11. blind-audit cadence canary DISABLED (AUDIT_CADENCE_DISABLE=1)"
        return 0
    fi

    local max_age_s="${AUDIT_CADENCE_MAX_AGE_S:-108000}"
    local plan="${PLAN_FILE:-}"
    if [ -z "$plan" ] || [ ! -f "$plan" ]; then
        audit_canary_status="missing-plan"
        _cadence_loud "BLIND-AUDIT-CADENCE-OVERDUE" \
            "plan file missing at ${plan:-unset} — last-blind-audit-run stamp unreadable (fleet-blind-audit has nowhere to write; cadence floor unverifiable)"
        _cadence_log "11. blind-audit cadence canary: status=$audit_canary_status age=${audit_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    # Any last-blind-audit-run stamp counts: started, dry-run, or completed.
    # Cadence cares that the unit is being launched on schedule. If even the
    # STARTED stamp is stale, the unit is not being launched at all.
    local audit_stamp
    audit_stamp="$(grep -E '^last-blind-audit-run:' "$plan" 2>/dev/null | tail -n 1 | sed -E 's/^last-blind-audit-run:[[:space:]]+//' | awk '{print $1}' || true)"
    if [ -z "$audit_stamp" ]; then
        audit_canary_status="never-ran"
        _cadence_loud "BLIND-AUDIT-CADENCE-OVERDUE" \
            "no last-blind-audit-run stamp in $plan — audit has never run (or its stamps have been wiped); daily timer alone may be silently broken"
        _cadence_log "11. blind-audit cadence canary: status=$audit_canary_status age=${audit_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    local now_s stamp_s
    now_s="$(date -u +%s)"
    stamp_s="$(date -u -d "$audit_stamp" +%s 2>/dev/null || echo 0)"
    if [ "$stamp_s" -eq 0 ]; then
        audit_canary_status="unparseable-stamp"
        _cadence_loud "BLIND-AUDIT-CADENCE-OVERDUE" \
            "last-blind-audit-run stamp '$audit_stamp' is not parseable by date(1) — audit cadence cannot be verified"
        _cadence_log "11. blind-audit cadence canary: status=$audit_canary_status age=${audit_canary_age_s}s limit=${max_age_s}s"
        return 0
    fi

    local age_s=$(( now_s - stamp_s ))
    audit_canary_age_s="$age_s"
    if [ "$age_s" -gt "$max_age_s" ]; then
        local age_h=$(( age_s / 3600 ))
        local limit_h=$(( max_age_s / 3600 ))
        audit_canary_status="overdue"
        _cadence_loud "BLIND-AUDIT-CADENCE-OVERDUE" \
            "audit last ran ${age_h}h ago (limit ${limit_h}h, stamp='$audit_stamp') — daily floor is not firing; §10 dispatch or systemd timer is broken; manual systemctl --user start fleet-blind-audit.service required"
    fi
    _cadence_log "11. blind-audit cadence canary: status=$audit_canary_status age=${audit_canary_age_s}s limit=${max_age_s}s"
    _cadence_timeout_guard
    if [ -n "${audit_canary_timeout:-}" ]; then
        _cadence_log "11. blind-audit timeout guard: ${audit_canary_timeout}"
    fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    heartbeat_blind_audit_cadence_canary
fi
