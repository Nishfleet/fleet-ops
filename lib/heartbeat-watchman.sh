#!/usr/bin/env bash
# heartbeat-watchman — the watchman for the watchman (fleet-ops#76).
#
# Sourced by fleet-heartbeat (dead-man ping on success) and
# fleet-heartbeat-tier1 (failed-unit repair-then-page, seat-health
# freshness). Also runnable as:
#   heartbeat-watchman.sh ping|process-failed|seat-health
#
# No new units. Reuses healthchecks.io (HC_URL, ping on success only,
# same pattern as siterep-uptime), hermes send --urgent, and
# pi-transport-check.service.
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
    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        case "$unit" in
            fleet-heartbeat.service|fleet-heartbeat.timer|fleet-heartbeat-failed-notify.service)
                continue
                ;;
        esac
        printf '%s\n' "$unit"
    done < <("$SYSTEMCTL" --user --state=failed --no-legend 2>/dev/null \
                | awk '{print $1}' || true)
}

heartbeat_repair_unit() {
    local unit="$1"
    "$SYSTEMCTL" --user reset-failed "$unit" >/dev/null 2>&1 || true
    "$SYSTEMCTL" --user start "$unit" >/dev/null 2>&1 || true
}

heartbeat_page_units() {
    local n="$1"; shift
    local list="$1"
    local msg
    _watchman_loud "UNIT-FAILED" "still failed after repair n=$n :: $list"
    msg="Fleet: ${n} unit(s) still failed after repair: ${list}. See FLEET-HEARTBEAT-TRIAGE.md"
    if ! "$HERMES" send -t telegram --urgent "$msg" >/dev/null 2>&1; then
        _watchman_log "WARN: hermes send failed (triage already written)"
        return 1
    fi
    _watchman_log "failed-units: telegram page sent n=$n"
    return 0
}

# Repair first, page second. Remaining failed units go to triage AND hermes.
heartbeat_process_failed_units() {
    local unit excerpt list n
    local -a failed=()
    local -a still=()

    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        failed+=("$unit")
    done < <(heartbeat_list_failed_units)

    if [ "${#failed[@]}" -eq 0 ]; then
        _watchman_log "failed-units: none"
        return 0
    fi

    for unit in "${failed[@]}"; do
        excerpt=$("$JOURNALCTL" --user -u "$unit" -n 5 --no-pager -q 2>/dev/null \
                    | tr '\n' ' ' | head -c 400 || true)
        _watchman_log "failed-units: repairing $unit :: ${excerpt:-<no-journal>}"
        heartbeat_repair_unit "$unit"
    done

    while IFS= read -r unit; do
        [ -z "$unit" ] && continue
        still+=("$unit")
    done < <(heartbeat_list_failed_units)

    n=${#still[@]}
    if [ "$n" -eq 0 ]; then
        _watchman_log "failed-units: all repaired (${#failed[@]} attempted)"
        return 0
    fi

    list=$(IFS=', '; echo "${still[*]}")
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
