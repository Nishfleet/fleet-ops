#!/usr/bin/env bash
# heartbeat-watchman — the watchman for the watchman (fleet-ops#76).
#
# Sourced by fleet-heartbeat (dead-man ping on success) and
# fleet-heartbeat-tier1 (failed-unit repair-then-page, seat-health
# freshness). Also runnable as:
#   heartbeat-watchman.sh ping|process-failed|seat-health|seat-health-per-seat|seat-caps-drift
#
# No new units. Reuses healthchecks.io (HC_URL, ping on success only,
# same pattern as siterep-uptime), hermes send --urgent, and
# pi-transport-check.service.
#
# Test overrides: CURL SYSTEMCTL HERMES JOURNALCTL HC_URL HC_TIMEOUT
#   FLEET_HEARTBEAT_TRIAGE FLEET_SEAT_HEALTH FLEET_SEAT_HEALTH_MAX_AGE_SEC
#   PI_TRANSPORT_CHECK_UNIT FLEET_SEAT_LEDGER_DIR FLEET_SEAT_PER_SEAT_STALE_SEC
#   FLEET_SEAT_PER_SEAT_STALE_PCT PI_MODELS_JSON SEAT_CAPS_JSON

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
# Per-seat ledger dir (mirrors lib/seat-lib.sh LEDGER_DIR). The single
# SEAT_HEALTH summary is one seat's rollup; these per-seat files are the
# real per-seat state seat_usable reads. fleet-ops#156 finding 14: the
# summary can be fresh while this dir is mostly stale, masking the true
# fleet seat picture. This check alarms on that divergence.
SEAT_LEDGER_DIR="${FLEET_SEAT_LEDGER_DIR:-/home/nish/workspaces/agent-state/lanes/seats}"
# Same 6h "no data" threshold as seat-lib.sh STALE_SECS.
SEAT_HEALTH_PER_SEAT_STALE_SEC="${FLEET_SEAT_PER_SEAT_STALE_SEC:-21600}"
# Alarm when this integer percent of per-seat files are stale while the
# summary is fresh. 50 = more than half the ledger is stale. Integer so
# bash $(( )) cannot silently collapse a float.
SEAT_HEALTH_PER_SEAT_STALE_PCT="${FLEET_SEAT_PER_SEAT_STALE_PCT:-50}"
[[ "$SEAT_HEALTH_PER_SEAT_STALE_PCT" =~ ^[0-9]+$ ]] || SEAT_HEALTH_PER_SEAT_STALE_PCT=50

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
        excerpt=$("$JOURNALCTL" --user -u "$unit" -n 5 --no-pager -q 2>/dev/null \
                    | tr '\n' ' ' | head -c 400 || true)
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

# fleet-ops#156 finding 14: summary fresh + per-seat ledger mostly stale
# is a masked fleet. Never fails the tick (returns 0); the loud line +
# transport-check is the signal. Missing/empty ledger dir is skip, not
# a fault — the summary check owns the no-data case.
heartbeat_seat_health_per_seat_check() {
    [[ -d "$SEAT_LEDGER_DIR" ]] || {
        _watchman_log "seat-health-per-seat: no ledger dir at $SEAT_LEDGER_DIR — skip"
        return 0
    }
    local counts summary_age total stale
    counts="$(python3 - "$SEAT_LEDGER_DIR" "$SEAT_HEALTH" "$SEAT_HEALTH_MAX_AGE_SEC" "$SEAT_HEALTH_PER_SEAT_STALE_SEC" <<'PY'
import json, sys, glob, os
from datetime import datetime, timezone

ledger, summary_path, max_age_s, stale_s = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
now = datetime.now(timezone.utc)

def parse_obs(obs):
    if not isinstance(obs, str) or not obs.strip():
        return None
    raw = obs.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        p = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if p.tzinfo is None:
        p = p.replace(tzinfo=timezone.utc)
    return p

def summary_fresh():
    try:
        with open(summary_path, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        return False
    if not isinstance(d, dict):
        return False
    p = parse_obs(d.get("observed_at"))
    if p is None:
        return False
    age = int((now - p).total_seconds())
    return 0 <= age <= max_age_s

files = sorted(glob.glob(os.path.join(ledger, "*.json")))
stale = 0
for path in files:
    try:
        with open(path, encoding="utf-8") as fh:
            e = json.load(fh)
    except Exception:
        stale += 1
        continue
    p = parse_obs(e.get("observed_at") if isinstance(e, dict) else None)
    if p is None:
        stale += 1
        continue
    age = int((now - p).total_seconds())
    if age > stale_s or age < 0:
        stale += 1
print(("fresh" if summary_fresh() else "stale") + f" {len(files)} {stale}")
PY
    )" || {
        _watchman_log "seat-health-per-seat: python failed — skip"
        return 0
    }
    read -r summary_age total stale <<<"$counts"
    : "${summary_age:=stale}" "${total:=0}" "${stale:=0}"
    _watchman_log "seat-health-per-seat: total=$total fresh=$(( total - stale )) stale=$stale (stale_thresh=${SEAT_HEALTH_PER_SEAT_STALE_SEC}s pct=${SEAT_HEALTH_PER_SEAT_STALE_PCT}) summary=$summary_age"

    if [[ "$summary_age" == "fresh" && "$total" -gt 0 ]]; then
        if (( stale * 100 > total * SEAT_HEALTH_PER_SEAT_STALE_PCT )); then
            "$SYSTEMCTL" --user start "$PI_TRANSPORT_CHECK_UNIT" >/dev/null 2>&1 || \
                _watchman_log "seat-health-per-seat: trigger $PI_TRANSPORT_CHECK_UNIT failed"
            _watchman_loud "SEAT-HEALTH-PER-SEAT" \
                "divergence: summary fresh but $stale/$total per-seat files stale (>${SEAT_HEALTH_PER_SEAT_STALE_SEC}s, pct>${SEAT_HEALTH_PER_SEAT_STALE_PCT}) — summary masks stale fleet; triggered $PI_TRANSPORT_CHECK_UNIT"
        fi
    fi
    return 0
}

# fleet-ops#156 finding 10: every models.json provider must appear in
# seat-caps.json. cap 0 is an explicit decision; absence is silent skip
# in seat-lib.sh with no alarm. Uses jq (already a fleet dependency).
# Reads ONLY .providers keys — never apiKey/baseUrl/headers.
# Return: 0 clean or skip, 1 drift, 2 structural.
MODELS_JSON="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
SEAT_CAPS_JSON="${SEAT_CAPS_JSON:-$HOME/.local/state/pi-packet/seat-caps.json}"

heartbeat_seat_caps_drift_check() {
    command -v jq >/dev/null 2>&1 || {
        _watchman_log "seat-caps-drift: jq missing — skip"
        return 0
    }
    [[ -f "$MODELS_JSON" ]] || {
        _watchman_log "seat-caps-drift: no models.json at $MODELS_JSON — skip"
        return 0
    }
    [[ -f "$SEAT_CAPS_JSON" ]] || {
        _watchman_log "seat-caps-drift: no seat-caps.json at $SEAT_CAPS_JSON — skip"
        return 0
    }
    local drift
    drift="$(jq -r '
        (.providers | keys? // empty) as $m
        | input.providers
        | keys? // empty
        | $m - .
        | .[]
    ' "$MODELS_JSON" "$SEAT_CAPS_JSON" 2>/dev/null)" || {
        _watchman_log "seat-caps-drift: unparseable JSON — skip"
        return 0
    }
    if [[ -n "$drift" ]]; then
        local list
        list="$(printf '%s' "$drift" | tr '\n' ',' | sed 's/,$//')"
        _watchman_loud "SEAT-CAPS-DRIFT" \
            "providers in models.json ABSENT from seat-caps.json (cap 0 is the explicit form): $list"
        _watchman_log "seat-caps-drift: DRIFT $list"
        return 1
    fi
    _watchman_log "seat-caps-drift: clean — every models.json provider has a seat-caps.json entry"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-}"
    case "$cmd" in
        ping) heartbeat_ping_deadman ;;
        process-failed) heartbeat_process_failed_units ;;
        seat-health) heartbeat_seat_health_check ;;
        seat-health-per-seat) heartbeat_seat_health_per_seat_check ;;
        seat-caps-drift) heartbeat_seat_caps_drift_check ;;
        *)
            printf 'usage: %s ping|process-failed|seat-health|seat-health-per-seat|seat-caps-drift\n' "$0" >&2
            exit 2
            ;;
    esac
fi
# trailing comment
