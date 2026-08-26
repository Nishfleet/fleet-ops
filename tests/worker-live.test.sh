#!/usr/bin/env bash
# tests/worker-live.test.sh
#
# Pins the single source of truth for "is a fleet worker unit live":
# lib/worker-live.sh :: worker_unit_is_live. This helper is shared by the
# OnFailure reaper (bin/pi-issue-failed-reap) and the heartbeat §3 orphan
# sweep (bin/fleet-heartbeat-tier1) so the two cannot drift — fleet-ops#222
# was exactly that drift (the reaper's #109 MainPID-aware fix never reached
# tier1's inline copy, so four orphans sat frozen ~1h).
#
# What it proves:
#   1. The helper exists and is sourced by BOTH the reaper and tier1.
#   2. The truth table: every ActiveState/SubState/MainPID combination
#      classifies live/not-live correctly, through a fake systemctl.
#   3. auto-restart with MainPID=0 is NOT live (the #109/#222 fix).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

lib="$repo_root/lib/worker-live.sh"
reaper="$repo_root/bin/pi-issue-failed-reap"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
[[ -f "$lib" ]] || fail "missing lib/worker-live.sh"
bash -n "$lib" || fail "worker-live.sh: bash syntax error"

# 1. Both callers source the shared helper (no drifted second copy).
grep -F 'worker_unit_is_live' "$reaper" >/dev/null \
  || fail "pi-issue-failed-reap must use worker_unit_is_live (shared helper)"
grep -F 'WORKER_LIVE_LIB=' "$tier1" >/dev/null \
  || fail "fleet-heartbeat-tier1 must source lib/worker-live.sh via WORKER_LIVE_LIB"
ok "shared worker_unit_is_live sourced by reaper + tier1"

# 2. Truth table through a fake systemctl.
scratch="$(mktemp -d -t worker-live.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
fake="$scratch/fake-systemctl"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  show)
    prop=""; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p) prop="$2"; shift 2 ;;
        --property=*) prop="${1#--property=}"; shift ;;
        --value) shift ;;
        -*) shift ;;
        *) shift ;;
      esac
    done
    case "$prop" in
      ActiveState) printf '%s' "$ACTIVE_STATE" ;;
      MainPID)     printf '%s' "$MAIN_PID" ;;
      SubState)    printf '%s' "$SUB_STATE" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake"

# classify <active> <mainpid> <sub> -> live | not
classify() {
    ACTIVE_STATE="$1" MAIN_PID="$2" SUB_STATE="${3:-running}" \
    SYSTEMCTL="$fake" bash -c '
        source "$1"
        if worker_unit_is_live "pi-issue@fleet-ops-1.service"; then echo live; else echo not; fi
    ' -- "$lib"
}

# Genuinely live.
[[ "$(classify active 12345 running)" == "live" ]] || fail "active/running -> live"
[[ "$(classify active 0 running)" == "live" ]] || fail "active (oneshot done) -> live"
[[ "$(classify activating 4242 start)" == "live" ]] || fail "activating/start PID>0 -> live"
[[ "$(classify activating 99 auto-restart)" == "live" ]] || fail "activating/auto-restart PID>0 -> live"
# Not live (the three orphan shapes).
[[ "$(classify inactive 0 dead)" == "not" ]] || fail "inactive/dead -> not (orphan a)"
[[ "$(classify failed 0 failed)" == "not" ]] || fail "failed -> not (orphan b)"
[[ "$(classify activating 0 auto-restart)" == "not" ]] || fail "activating/auto-restart PID=0 -> not (orphan c, fleet-ops#109/#222)"
[[ "$(classify activating 0 start)" == "not" ]] || fail "activating/start PID=0 -> not (no process)"
# Empty/unknown active state with no process -> not live.
[[ "$(classify "" 0 running)" == "not" ]] || fail "empty active + PID 0 -> not"
ok "worker_unit_is_live truth table: live holds busy workers; not-live releases all 3 orphan shapes"

echo "OK: worker-live single source of truth pinned"
