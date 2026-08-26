#!/usr/bin/env bash
# tests/fleet-heartbeat-orphan-distinguish.test.sh
#
# fleet-ops#63 originally made the orphan sweep use --state=active,activating
# so it did not release a genuinely busy worker (activating/start) or a
# crash-looping one (activating/auto-restart). fleet-ops#222 (2026-08-26)
# refined that: a crash-looping worker in auto-restart with MainPID=0 has NO
# live process — only the RestartSec timer is pending — so it IS an orphan
# and must be released. The live-check is now the shared worker_unit_is_live
# helper (lib/worker-live.sh), MainPID-aware, used by both the heartbeat §3
# sweep and the OnFailure reaper so the two cannot drift.
#
# This test pins the helper's truth table and that tier1 wires it into §3.
# The end-to-end "all three shapes release in one tick" proof lives in
# tests/orphan-release-drill.test.sh (the fleet-ops#180 detector drill).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

bin="$repo_root/bin/fleet-heartbeat-tier1"
lib="$repo_root/lib/worker-live.sh"
reaper="$repo_root/bin/pi-issue-failed-reap"
[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing shared helper: $lib"
[[ -x "$reaper" ]] || fail "not executable: $reaper"

# --- Phase A: tier1 §3 wires the shared helper, not an inline probe ---------
# The §3 orphan sweep must call orphan_release_for_issue (the shared release
# fn from lib/orphan-release.sh), which in turn calls worker_unit_is_live
# (the single source of truth). The old inline `list-units
# --state=active,activating` + SubState case must be gone from §3 — that was
# the drifted copy (fleet-ops#222).
grep -F 'orphan_release_for_issue "$repo" "$issue_n" "$short"' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 §3 must call orphan_release_for_issue (shared release fn)"
# The shared helper is sourced (with a fallback), not re-defined inline in §3.
grep -F 'WORKER_LIVE_LIB=' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must source lib/worker-live.sh via WORKER_LIVE_LIB"
grep -F 'ORPHAN_RELEASE_LIB=' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must source lib/orphan-release.sh via ORPHAN_RELEASE_LIB"
# The reaper must also use the shared helper (no drifted second copy).
grep -F 'worker_unit_is_live' "$reaper" >/dev/null \
  || fail "pi-issue-failed-reap must use worker_unit_is_live (shared helper)"
# The §3 stop-on-auto-restart step must exist (shape (c) release requires it
# so intake's pi-issue-start can re-dispatch). It lives in lib/orphan-release.sh
# now, so check the lib too.
grep -F 'stopped auto-restarting unit' "$repo_root/lib/orphan-release.sh" >/dev/null \
  || fail "lib/orphan-release.sh must stop auto-restarting units on release (fleet-ops#222)"
ok "tier1 §3 + reaper share worker_unit_is_live; §3 stops auto-restart units on release"

# --- Phase B: the helper's truth table, through a fake systemctl ------------
# worker_unit_is_live is MainPID-aware. We prove every state combination
# classifies correctly: the three orphan shapes (a/b/c) are NOT live; a
# genuinely running worker IS live.
scratch="$(mktemp -d -t heartbeat-orphan.XXXXXX)"
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
        --value) shift ;;
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

# classify <active_state> <main_pid> <sub_state>  -> live | not
classify() {
    local active="$1" pid="$2" sub="${3:-running}"
    ACTIVE_STATE="$active" MAIN_PID="$pid" SUB_STATE="$sub" \
    SYSTEMCTL="$fake" bash -c '
        source "$1"; 
        if worker_unit_is_live "pi-issue@fleet-ops-1.service"; then echo live; else echo not; fi
    ' -- "$lib"
}

# Genuinely live workers — must NOT be released.
[[ "$(classify active 12345 running)" == "live" ]] \
    || fail "active/running must be live (busy worker)"
[[ "$(classify activating 4242 start)" == "live" ]] \
    || fail "activating/start MainPID>0 must be live (worker launching pi)"
[[ "$(classify activating 99 auto-restart)" == "live" ]] \
    || fail "activating/auto-restart MainPID>0 must be live (process alive mid-restart)"
ok "live-check holds genuinely running workers: active | activating/start | activating/auto-restart+PID"

# The three orphan shapes — must be released (NOT live).
#   (a) unit dead (inactive) + branch exists + no PR
#   (b) unit dead (failed)   + branch already reaped + no PR
#   (c) unit in auto-restart with MainPID=0 (crash-loop, no process)
[[ "$(classify inactive 0 dead)" == "not" ]] \
    || fail "inactive/dead must be NOT live (orphan shape a)"
[[ "$(classify failed 0 failed)" == "not" ]] \
    || fail "failed/failed must be NOT live (orphan shape b)"
[[ "$(classify activating 0 auto-restart)" == "not" ]] \
    || fail "activating/auto-restart MainPID=0 must be NOT live (orphan shape c — the fleet-ops#222 root cause)"
ok "live-check releases all three orphan shapes: inactive | failed | auto-restart+MainPID=0"

# --- Phase C: degraded-lane reporter still publishes auto-restart -----------
# §7 is observability: it still reports auto-restart units as DEGRADED-LANES
# so the operator can see crash-loops even after §3 releases the claim.
grep -F "SubState" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must query SubState for the degraded-lane classification"
grep -F "DEGRADED-LANES" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must publish DEGRADED-LANES loud triage lines for auto-restart units"
grep -F "loud \"DEGRADED-LANES\"" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must wire DEGRADED-LANES through loud() (visible to operators)"
ok "degraded-lane reporter: SubState query + DEGRADED-LANES loud line wired"

# --- Phase D: default config covers fleet-ops -------------------------------
grep -F '"Nishfleet/fleet-ops"' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 default claim_repos must include Nishfleet/fleet-ops (fleet-ops#61)"
default_block=$(awk '/cat > "\$REPOS_JSON"/,/^JSON$/' "$bin")
printf '%s\n' "$default_block" | grep -F '"Nishfleet/fleet-ops"' >/dev/null \
  || fail "Nishfleet/fleet-ops must appear in the default fleet-repos.json heredoc"
printf '%s\n' "$default_block" | grep -F '"claim_repos": ["Nishfleet/fleet-ops"' >/dev/null \
  || fail 'Nishfleet/fleet-ops must lead the "claim_repos" array in the default fleet-repos.json'
ok "default claim_repos includes Nishfleet/fleet-ops (orphan sweep covers this repo)"

echo "OK: orphan-distinguish pins shared worker_unit_is_live truth table + tier1 §3 wiring"
