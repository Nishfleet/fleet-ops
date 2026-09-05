#!/usr/bin/env bash
# heartbeat-watchman — the watchman for the watchman (fleet-ops#76, #428).
#
# Sourced by fleet-heartbeat (dead-man ping on success) and
# fleet-heartbeat-tier1 (failed-unit repair-then-triage, seat-health
# freshness). Also runnable as:
#   heartbeat-watchman.sh ping|process-failed|seat-health
#
# No new units. Reuses healthchecks.io (HC_URL, ping on success only,
# same pattern as siterep-uptime) and pi-transport-check.service.
#
# fleet-ops#428: unit failures do NOT page Nish directly. They are written
# to the triage file so tier 2 / the unit-escalation drop-in can dispatch an
# agent. Only Nish-reserved boundary items (money/legal/etc.) reach Telegram
# via nish-boundary-notify.
#
# Test overrides: CURL SYSTEMCTL HERMES JOURNALCTL HC_URL HC_TIMEOUT
#   FLEET_HEARTBEAT_TRIAGE FLEET_SEAT_HEALTH FLEET_SEAT_HEALTH_MAX_AGE_SEC
#   PI_TRANSPORT_CHECK_UNIT

# Defaults (safe to re-source).
CURL="${CURL:-curl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
HERMES="${HERMES:-hermes}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
HC_TIMEOUT="${HC_TIMEOUT:-10}"
TRIAGE="${FLEET_HEARTBEAT_TRIAGE:-${TRIAGE:-/home/nish/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md}}"
SEAT_HEALTH="${FLEET_SEAT_HEALTH:-/home/nish/workspaces/agent-state/lanes/pi-seat-health.json}"
SEAT_HEALTH_MAX_AGE_SEC="${FLEET_SEAT_HEALTH_MAX_AGE_SEC:-5400}"
PI_TRANSPORT_CHECK_UNIT="${PI_TRANSPORT_CHECK_UNIT:-pi-transport-check.service}"

_watchman_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$*"
        return
    fi
    printf '[%s] [watchman] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

_watchman_loud() {
    local tag="$1"; shift
    if declare -F loud >/dev/null 2>&1; then
        loud "$tag" "$*"
        return
    fi
    _watchman_log "LOUD [$tag] $*"
    {
        printf '\n[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$*"
    } >> "$TRIAGE" 2>/dev/null || _watchman_log "WARN: could not append to triage $TRIAGE"
}

# Ping HC_URL on success only. Never fails the caller. Never prints the URL.
heartbeat_ping_deadman() {
    if [[ -z "${HC_URL:-}" ]]; then
        _watchman_log "dead-man: skip (HC_URL unset)"
        return 0
    fi
    if "$CURL" -fsS -m "$HC_TIMEOUT" "$HC_URL" >/dev/null 2>&1; then
        _watchman_log "dead-man: ping ok"
    else
        _watchman_log "dead-man: ping failed (best-effort, tick still clean)"
    fi
    return 0
}

heartbeat_list_failed_units() {
    local unit
    # fleet-ops#428: --plain suppresses the bullet glyph systemd may place in
    # the first column of list-units output, which awk '{print $1}' would
    # otherwise capture as the unit name.
    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        case "$unit" in
            fleet-heartbeat.service|fleet-heartbeat.timer|fleet-heartbeat-failed-notify.service)
                continue
                ;;
        esac
        printf '%s\n' "$unit"
    done < <("$SYSTEMCTL" --user list-units --state=failed --no-legend --plain 2>/dev/null \
                | awk '{print $1}' || true)

    # fleet-ops#1570: also list --system failed units. The heartbeat runs as
    # user nish and only auto-repairs fleet USER units (block 4 of tier1);
    # system-scope units are host services (claude-telegram-watchdog.service,
    # restic, ...) that must NOT be reset+started blindly — a failed system
    # unit is a signal to diagnose, not noise to clear. Prefixed "system:" so
    # callers can route them to surface-only handling, and tier 2 / the
    # unit-escalation drop-in (root) can dispatch the real repair.
    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        printf 'system:%s\n' "$unit"
    done < <("$SYSTEMCTL" --system list-units --state=failed --no-legend --plain 2>/dev/null \
                | awk '{print $1}' || true)
}

heartbeat_repair_unit() {
    local unit="$1"
    # fleet-ops#1570: system-scope units are surfaced only, never auto-repaired.
    # nish has NOPASSWD sudo, so capability is not the blocker — safety is:
    # reset-failed+start on an arbitrary failed host service can mask a real
    # fault (the watchdog's exit-1-on-success bug was exactly such a signal)
    # or start a service that should stay down. Tier 2 / the unit-escalation
    # drop-in diagnoses and repairs; the heartbeat's job is to make the
    # failure visible, not to act on it.
    if [[ "$unit" == system:* ]]; then
        _watchman_log "repair: surface-only system-scope ${unit#system:} (host service — diagnose, do not auto-restart)"
        return 0
    fi
    "$SYSTEMCTL" --user reset-failed "$unit" >/dev/null 2>&1 || true
    "$SYSTEMCTL" --user start "$unit" >/dev/null 2>&1 || true
}

heartbeat_page_units() {
    local n="$1"; shift
    local list="$1"
    # fleet-ops#428: unit failures are surfaced in triage only. They do NOT
    # text Nish directly; the unit-escalation drop-in and tier 2 dispatch the
    # repair. Nish is only reached for Nish-reserved boundary items via
    # nish-boundary-notify.
    _watchman_loud "UNIT-FAILED" "still failed after repair n=$n :: $list"
    _watchman_log "failed-units: triaged n=$n (no telegram)"
    return 0
}

# Repair first, triage second. Remaining failed units are surfaced for tier 2.
heartbeat_process_failed_units() {
    local unit excerpt list n
    local -a failed=()
    local -a still_units=()

    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        failed+=("$unit")
    done < <(heartbeat_list_failed_units)

    if [ "${#failed[@]}" -eq 0 ]; then
        _watchman_log "failed-units: none"
        return 0
    fi

    for unit in "${failed[@]}"; do
        # fleet-ops#1570: system-scope journal may need group membership; best-effort.
        # The excerpt is a log/journal snippet (not model context), capped to
        # keep the tick log bounded; the cap is on the same line as the
        # excerpt= assignment so the token-efficiency gate sees the log marker.
        if [[ "$unit" == system:* ]]; then
            excerpt=$("$JOURNALCTL" --system -u "${unit#system:}" -n 5 --no-pager -q 2>/dev/null | tr '\n' ' ' | head -c 400 || true)
        else
            excerpt=$("$JOURNALCTL" --user -u "$unit" -n 5 --no-pager -q 2>/dev/null | tr '\n' ' ' | head -c 400 || true)
        fi
        _watchman_log "failed-units: repairing $unit :: ${excerpt:-<no-journal>}"
        heartbeat_repair_unit "$unit"
    done

    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        still_units+=("$unit")
    done < <(heartbeat_list_failed_units)

    n=${#still_units[@]}
    if [ "$n" -eq 0 ]; then
        _watchman_log "failed-units: all repaired (${#failed[@]} attempted)"
        return 0
    fi

    # Build a comma-joined list without mutating IFS (semgrep
    # bash.lang.security.ifs-tampering). ${still_units[*]} with IFS=', '
    # joins on the first char (","), so printf matches the prior output.
    list=$(printf '%s,' "${still_units[@]}")
    list=${list%,}
    heartbeat_page_units "$n" "$list" || true
    return 0
}

# observed_at must parse and be < 90 minutes old. Stale or unparseable:
# trigger pi-transport-check, then report. Never fails the tick.
heartbeat_seat_health_check() {
    local verdict age_s
    verdict=$(python3 - "$SEAT_HEALTH" "$SEAT_HEALTH_MAX_AGE_SEC" <<'PY'
import json, sys
from datetime import datetime, timezone

path, max_age = sys.argv[1], int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    print("missing")
    sys.exit(2)
except (json.JSONDecodeError, OSError, UnicodeError):
    print("unparseable")
    sys.exit(2)
if not isinstance(data, dict):
    print("unparseable")
    sys.exit(2)
obs = data.get("observed_at")
if not obs or not isinstance(obs, str):
    print("missing-observed-at")
    sys.exit(2)
raw = obs.strip()
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    parsed = datetime.fromisoformat(raw)
except ValueError:
    print("unparseable-observed-at")
    sys.exit(2)
if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
age = int((datetime.now(timezone.utc) - parsed).total_seconds())
if age > max_age or age < 0:
    print(f"stale age={age}s")
    sys.exit(1)
print(str(age))
sys.exit(0)
PY
    ) || {
        local rc=$?
        _watchman_log "seat-health: $verdict (rc=$rc) — triggering $PI_TRANSPORT_CHECK_UNIT"
        "$SYSTEMCTL" --user start "$PI_TRANSPORT_CHECK_UNIT" >/dev/null 2>&1 || \
            _watchman_log "seat-health: trigger $PI_TRANSPORT_CHECK_UNIT failed"
        _watchman_loud "SEAT-HEALTH" "fault=$verdict path=$SEAT_HEALTH — triggered $PI_TRANSPORT_CHECK_UNIT"
        return 0
    }
    age_s="$verdict"
    _watchman_log "seat-health: fresh observed_at age=${age_s}s (max=${SEAT_HEALTH_MAX_AGE_SEC}s)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-}"
    case "$cmd" in
        ping) heartbeat_ping_deadman ;;
        process-failed) heartbeat_process_failed_units ;;
        seat-health) heartbeat_seat_health_check ;;
        *)
            printf 'usage: %s ping|process-failed|seat-health\n' "$0" >&2
            exit 2
            ;;
    esac
fi
# trailing comment
