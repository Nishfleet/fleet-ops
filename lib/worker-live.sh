# shellcheck shell=bash
# lib/worker-live.sh — single source of truth for "is a fleet worker unit live".
#
# Sourced by every caller that must decide whether a pi-issue@/pi-packet@ worker
# still has a live process:
#   - bin/pi-issue-failed-reap   (OnFailure claim release)
#   - bin/fleet-heartbeat-tier1  (§3 orphan sweep)
#   - bin/orphan-release-drill   (fleet-ops#180 detector drill)
#
# Why this exists (fleet-ops#222, 2026-08-26): the orphan sweep and the reaper
# each carried their OWN copy of the live-check, and they drifted. The reaper's
# copy was fixed in fleet-ops#109/#125 to treat auto-restart (MainPID=0) as NOT
# live — a worker whose process has exited and is only waiting RestartSec is
# doing no work. tier1's copy never got that fix, so it held every auto-restart
# unit as "DEGRADED, not orphan" and four textbook orphans sat frozen ~1h while
# lanes idled. One function, pinned by tests/worker-live.test.sh, so the two
# cannot drift again.
#
# Contract:
#   worker_unit_is_live <unit>   -> 0 if the unit has a live process, 1 if not.
#   ${SYSTEMCTL} may be injected (tests/drill fake a systemctl). Defaults to
#   `systemctl`.
#
# Truth table (ActiveState / SubState / MainPID -> live?):
#   active            / *            / *      -> LIVE   (oneshot finished ok, or running)
#   activating        / start        / >0      -> LIVE   (worker launching/running)
#   activating        / auto-restart / 0       -> NOT    (process exited, restart timer pending — #109)
#   activating        / auto-restart / >0      -> LIVE   (process somehow alive mid-restart)
#   failed/inactive   / *            / *       -> NOT    (dead)
#
# `active` for a Type=oneshot means ExecStart succeeded and the unit is in its
# final state — that is a completed worker, not an orphan-in-progress, so the
# reaper/orphan sweep treat it as "live" (do not release a just-finished worker
# before its own PR/cleanup path runs). This matches the pre-existing reaper
# behaviour this helper was extracted from.

SYSTEMCTL="${SYSTEMCTL:-systemctl}"

worker_unit_is_live() {
    [ $# -ge 1 ] || return 1
    local unit="$1"
    local active main
    active="$("$SYSTEMCTL" --user show -p ActiveState --value "$unit" 2>/dev/null || echo "")"
    main="$("$SYSTEMCTL" --user show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
    case "$active" in
        active) return 0 ;;
        activating)
            # auto-restart has MainPID=0 (worker process exited, only the
            # restart timer is pending) — NOT live. Only activating with a
            # real MainPID>0 is a running worker. Treating auto-restart as
            # live was the never-release stuck-loop root cause
            # (fleet-ops#109, 2026-08-26): a worker that exits non-zero
            # thrashed forever because the reaper refused to release its
            # claim while StartLimitIntervalSec reset hourly.
            if [[ "$main" =~ ^[1-9][0-9]*$ ]]; then
                return 0
            fi
            return 1
            ;;
    esac
    if [[ "$main" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    fi
    return 1
}
