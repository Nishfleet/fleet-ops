#!/usr/bin/env bash
# tests/fleet-heartbeat-red-pr-repair.test.sh
#
# fleet-ops#124: a worker opens a PR, exits, and if CI comes back red the
# PR sits indefinitely — the claim branch blocks re-claiming, the
# agent-in-progress label blocks re-queueing, and nothing watches fleet PRs
# for red checks. This test pins the heartbeat tier1 red-pr-repair block:
#
#   A. Red PR + dead worker, FIRST tick  -> observe only (set one-tick
#      marker), NO dispatch. The issue requires "no live MainPID for >1
#      tick" before dispatching — a transient gap or a self-healing check
#      must not trigger a repair.
#   B. Red PR + dead worker, SECOND tick -> dispatch ONE repair worker onto
#      the existing claim branch (pi-issue-start), bounded by
#      RED_PR_MAX_ATTEMPTS (default 2).
#   C. After RED_PR_MAX_ATTEMPTS dispatches with the PR still red + worker
#      still dead -> FAIL LOUD (RED-PR-ESCALATE triage line + exit non-zero
#      -> fleet-heartbeat.service --state=failed -> page per #76/#86).
#   D. Red PR but worker LIVE -> no dispatch (work in flight; a repair
#      would race a second worker onto the same claim).
#   E. Green / pending / no-checks PR -> no dispatch, stale state cleared.
#
# Entirely offline with mocked gh + systemctl + pi-issue-start, mirroring
# tests/fleet-heartbeat-undersaturation.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-red-pr-repair"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t redpr.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# fleet-repos.json with one claim repo "demo".
repos_json="$scratch/fleet-repos.json"
cat >"$repos_json" <<'JSON'
{
  "queue_repos": ["Nishfleet/demo"],
  "claim_repos": ["Nishfleet/demo"],
  "hands_off": [],
  "verify_timers": []
}
JSON

log_dir="$scratch/log"
triage="$scratch/triage.md"
mkdir -p "$log_dir"

# Shared call log: every dispatch (pi-issue-start) + reset-failed appends here.
calls="$scratch/calls.log"
: >"$calls"

# --- fake gh ----------------------------------------------------------------
# Controlled by per-PR state files. PRs are declared in $PRS_JSON (a jq array
# of {number,head,isDraft,checks}). checks is one of: red, green, pending,
# none. The fake answers `pr list` and `pr checks` from this map.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)
    # Emit the PR rows whose head starts with claim/issue-.
    jq -c '[.[] | select(.head | startswith("claim/issue-")) | {number,headRefName:.head,isDraft:.draft}]' "${PRS_JSON:-/dev/null}" 2>/dev/null || printf '[]'
    exit 0
    ;;
  *"pr checks"*)
    # Pull the PR number out of argv (the token before -R).
    num=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "checks" ]] && num="$a"
      prev="$a"
    done
    state=$(jq -r --argjson n "$num" '.[] | select(.number == $n) | .checks' "${PRS_JSON:-/dev/null}" 2>/dev/null || echo none)
    case "$state" in
      red)
        printf '[{"name":"shellcheck","bucket":"fail","state":"FAILURE"},{"name":"semgrep","bucket":"pass","state":"SUCCESS"}]\n'
        ;;
      green)
        printf '[{"name":"shellcheck","bucket":"pass","state":"SUCCESS"},{"name":"semgrep","bucket":"pass","state":"SUCCESS"}]\n'
        ;;
      pending)
        printf '[{"name":"shellcheck","bucket":"pending","state":"PENDING"}]\n'
        ;;
      none|*)
        printf '[]\n'
        ;;
    esac
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake systemctl ---------------------------------------------------------
# is-active is driven by $LIVE_UNITS (one unit per line considered live).
# reset-failed appends to $CALLS.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift
case "$cmd" in
  is-active)
    unit="$1"
    if [[ -f "${LIVE_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${LIVE_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo active
    else
      echo inactive
    fi
    exit 0
    ;;
  reset-failed)
    unit="$1"
    printf 'reset-failed %s\n' "$unit" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  start)
    unit="$1"
    printf 'start %s\n' "$unit" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# --- fake pi-issue-start ----------------------------------------------------
# Records the dispatch. The real one no-ops on a live unit; the fake always
# "starts" so the test can count dispatches.
pi_issue_start_fake="$scratch/pi-issue-start"
cat >"$pi_issue_start_fake" <<'FAKE'
#!/usr/bin/env bash
printf 'pi-issue-start %s\n' "$1" >>"${CALLS:-/dev/null}"
exit 0
FAKE
chmod +x "$pi_issue_start_fake"

# Common env for every invocation.
export FLEET_REDPR_REPOS_JSON="$repos_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export CALLS="$calls"
LIVE_UNITS="$scratch/live_units"
export LIVE_UNITS
: >"$LIVE_UNITS"

PRS_JSON="$scratch/prs.json"
export PRS_JSON

run_helper() {
  set +e
  env_out=$(SYSTEMCTL="$systemctl_fake" GH="$gh_fake" PI_ISSUE_START="$pi_issue_start_fake" "$bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  rm -rf "${log_dir:?}"/* "$triage" "$calls"
  mkdir -p "$log_dir/red-pr-repair"
  : >"$calls"
  : >"$LIVE_UNITS"
}

# One red PR, issue 55, dead worker, across multiple ticks.
make_red_pr() {
  cat >"$PRS_JSON" <<'JSON'
[{"number":55,"head":"claim/issue-55","draft":false,"checks":"red"}]
JSON
}

count_dispatches() { local n; n=$(grep -c '^pi-issue-start ' "$calls" 2>/dev/null || true); echo "${n:-0}"; }
count_reset_failed() { local n; n=$(grep -c '^reset-failed ' "$calls" 2>/dev/null || true); echo "${n:-0}"; }

# ============================================================================
# Scenario A: red PR + dead worker, FIRST tick -> observe only, NO dispatch
# ============================================================================
reset_state
make_red_pr
: >"$LIVE_UNITS"   # worker dead

run_helper
[[ "$env_rc" == 0 ]] || fail "scenarioA: first tick must exit 0, got $env_rc ($env_out)"

# No dispatch yet (debounce: >1 tick required).
[[ "$(count_dispatches)" == "0" ]] \
    || fail "scenarioA: first tick must NOT dispatch, got $(count_dispatches) ($(cat "$calls"))"
# One-tick marker set.
[[ -f "$log_dir/red-pr-repair/demo-55.flag" ]] \
    || fail "scenarioA: debounce flag not set after first observation"
# State file records attempts=0.
sf="$log_dir/red-pr-repair/demo-55.json"
[[ -f "$sf" ]] || fail "scenarioA: state file not created"
[[ "$(jq -r '.attempts' "$sf")" == "0" ]] || fail "scenarioA: attempts must be 0 after observe"
ok "scenarioA: red+dead first tick -> observe only, no dispatch, flag set"

# ============================================================================
# Scenario B: red PR + dead worker, SECOND tick -> dispatch ONE repair
# ============================================================================
# Reuse scenarioA state (flag already set). Still red, still dead.
run_helper
[[ "$env_rc" == 0 ]] || fail "scenarioB: dispatch tick must exit 0, got $env_rc ($env_out)"

# Exactly one dispatch onto the existing claim branch.
[[ "$(count_dispatches)" == "1" ]] \
    || fail "scenarioB: must dispatch exactly once, got $(count_dispatches) ($(cat "$calls"))"
grep -qx 'pi-issue-start demo-55' "$calls" \
    || fail "scenarioB: dispatch must target demo-55 (existing claim branch), got $(cat "$calls")"
# reset-failed called before start (clears StartLimitBurst so start lands).
grep -qx 'reset-failed pi-issue@demo-55.service' "$calls" \
    || fail "scenarioB: reset-failed must precede start, got $(cat "$calls")"
# Flag cleared after dispatch (debounce restarts for the next attempt).
[[ ! -f "$log_dir/red-pr-repair/demo-55.flag" ]] \
    || fail "scenarioB: flag must be cleared after dispatch"
# attempts incremented to 1.
[[ "$(jq -r '.attempts' "$sf")" == "1" ]] || fail "scenarioB: attempts must be 1 after dispatch"
# Repair loud line in triage.
grep -q 'RED-PR-REPAIR' "$triage" || fail "scenarioB: triage missing RED-PR-REPAIR"
ok "scenarioB: red+dead second tick -> one dispatch onto existing claim, reset-failed first, attempt=1"

# ============================================================================
# Scenario C: still red+dead after 2 attempts -> FAIL LOUD (exit non-zero)
# ============================================================================
# Advance to attempt 2 first: re-observe (tick 3) then dispatch (tick 4).
run_helper   # tick 3: re-observe (flag was cleared), no dispatch
[[ "$(count_dispatches)" == "1" ]] \
    || fail "scenarioC-tick3: re-observe must not dispatch, got $(count_dispatches)"
run_helper   # tick 4: dispatch attempt 2
[[ "$(count_dispatches)" == "2" ]] \
    || fail "scenarioC-tick4: must dispatch attempt 2, got $(count_dispatches)"
[[ "$(jq -r '.attempts' "$sf")" == "2" ]] || fail "scenarioC: attempts must be 2 after second dispatch"
[[ "$env_rc" == 0 ]] || fail "scenarioC-tick4: dispatch tick must exit 0, got $env_rc"

# Now attempts == max (2). Re-observe (tick 5) then escalate (tick 6).
run_helper   # tick 5: re-observe
run_helper   # tick 6: budget exhausted -> FAIL LOUD
[[ "$env_rc" != 0 ]] \
    || fail "scenarioC: exhausted budget must exit non-zero, got 0 ($env_out)"
[[ "$env_rc" == 1 ]] || fail "scenarioC: expected exit 1, got $env_rc ($env_out)"
# No third dispatch.
[[ "$(count_dispatches)" == "2" ]] \
    || fail "scenarioC: must NOT dispatch a 3rd time, got $(count_dispatches) ($(cat "$calls"))"
# Escalation loud line in triage.
grep -q 'RED-PR-ESCALATE' "$triage" || fail "scenarioC: triage missing RED-PR-ESCALATE"
# Escalation marker set so we do not spam the triage file every tick.
[[ "$(jq -r '.escalated' "$sf")" == "true" ]] || fail "scenarioC: state must mark escalated=true"
ok "scenarioC: after 2 attempts still red+dead -> fail loud (exit 1), no 3rd dispatch, RED-PR-ESCALATE"

# ============================================================================
# Scenario C2: re-running after escalation does not spam (idempotent loud)
# ============================================================================
run_helper
[[ "$env_rc" != 0 ]] || fail "scenarioC2: post-escalation tick must still exit non-zero"
# Still exactly 2 dispatches total (no new dispatch).
[[ "$(count_dispatches)" == "2" ]] \
    || fail "scenarioC2: must not dispatch after escalation, got $(count_dispatches)"
# Exactly one RED-PR-ESCALATE line (not one per tick).
n_esc=$(grep -c 'RED-PR-ESCALATE' "$triage" 2>/dev/null || echo 0)
[[ "$n_esc" == "1" ]] || fail "scenarioC2: must emit RED-PR-ESCALATE once, got $n_esc"
ok "scenarioC2: post-escalation tick stays loud (exit 1) without spamming triage"

# ============================================================================
# Scenario D: red PR but worker LIVE -> no dispatch (work in flight)
# ============================================================================
reset_state
make_red_pr
printf 'pi-issue@demo-55.service\n' >"$LIVE_UNITS"   # worker live

run_helper
[[ "$env_rc" == 0 ]] || fail "scenarioD: live-worker tick must exit 0, got $env_rc ($env_out)"
[[ "$(count_dispatches)" == "0" ]] \
    || fail "scenarioD: must NOT dispatch while worker live, got $(count_dispatches) ($(cat "$calls"))"
# No flag set (live worker clears the debounce).
[[ ! -f "$log_dir/red-pr-repair/demo-55.flag" ]] \
    || fail "scenarioD: flag must be cleared when worker is live"
ok "scenarioD: red PR + live worker -> no dispatch (no race onto the same claim)"

# ============================================================================
# Scenario E: green / pending / no-checks PR -> no dispatch, state cleared
# ============================================================================
for st in green pending none; do
  reset_state
  cat >"$PRS_JSON" <<JSON
[{"number":55,"head":"claim/issue-55","draft":false,"checks":"$st"}]
JSON
  : >"$LIVE_UNITS"
  # Pre-seed stale state so we can prove it is cleared.
  mkdir -p "$log_dir/red-pr-repair"
  printf '{"short":"demo","issue":"55","pr":"55","attempts":1,"escalated":false,"first_seen":"x","last_seen":"x"}' \
      >"$log_dir/red-pr-repair/demo-55.json"
  touch "$log_dir/red-pr-repair/demo-55.flag"

  run_helper
  [[ "$env_rc" == 0 ]] || fail "scenarioE($st): must exit 0, got $env_rc ($env_out)"
  [[ "$(count_dispatches)" == "0" ]] \
      || fail "scenarioE($st): must NOT dispatch for $st PR, got $(count_dispatches)"
  [[ ! -f "$log_dir/red-pr-repair/demo-55.json" ]] \
      || fail "scenarioE($st): stale state must be cleared for $st PR"
  [[ ! -f "$log_dir/red-pr-repair/demo-55.flag" ]] \
      || fail "scenarioE($st): stale flag must be cleared for $st PR"
done
ok "scenarioE: green/pending/no-checks PR -> no dispatch, stale state cleared"

# ============================================================================
# Scenario F: tier1 wires the helper and propagates its non-zero exit
# ============================================================================
tier1="$repo_root/bin/fleet-heartbeat-tier1"
grep -F 'fleet-heartbeat-red-pr-repair' "$tier1" >/dev/null \
    || fail "tier1 must invoke fleet-heartbeat-red-pr-repair"
grep -F 'redpr_rc' "$tier1" >/dev/null \
    || fail "tier1 must capture redpr_rc and propagate it"
grep -F -- 'exit "$redpr_rc"' "$tier1" >/dev/null \
    || fail "tier1 must exit non-zero when red-pr-repair fails loud (page path)"
grep -F 'RED-PR-ESCALATE' "$bin" >/dev/null \
    || fail "helper must emit RED-PR-ESCALATE on exhaustion"
ok "scenarioF: tier1 wires the helper and propagates fail-loud exit to the pager"

# ============================================================================
# Scenario G: pi-issue-start dispatch is NON-BLOCKING (--no-block)
# ============================================================================
# fleet-ops#2151 second fault: fleet-heartbeat.service is Type=oneshot with
# TimeoutStartSec=45min. dispatch_repair -> pi-issue-start -> `systemctl --user
# start` was BLOCKING, so a worker with a 2520s lifetime held the oneshot
# heartbeat hostage past its 45min timeout -> unit-failure -> auditor pages.
# The fix is one flag: `start --no-block`. This scenario drives the REAL
# pi-issue-start (not the fake) with a SYSTEMCTL that sleeps 5s on a plain
# `start` but returns immediately when `--no-block` is present, and asserts
# pi-issue-start returns well within that 5s window — proving the flag is
# wired through and the oneshot is never held hostage.
pi_issue_start_real="$repo_root/bin/pi-issue-start"
[[ -x "$pi_issue_start_real" ]] || fail "scenarioG: real pi-issue-start not executable: $pi_issue_start_real"

# Fake systemctl: blocking start sleeps 5s; --no-block start returns at once.
# Records every start argv so we can prove the flag reached it.
systemctl_noblock="$scratch/systemctl-noblock"
start_log="$scratch/start.log"
: >"$start_log"
cat >"$systemctl_noblock" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift
case "$cmd" in
  is-active)
    echo inactive; exit 0 ;;
  show)
    # `show -p MainPID --value <unit>` -> 0 (no live MainPID)
    echo 0; exit 0 ;;
  daemon-reload)
    exit 0 ;;
  start)
    printf 'start %s\n' "$*" >>"${START_LOG:-/dev/null}"
    # If --no-block is present, return immediately (the real flag's effect).
    # Otherwise simulate a blocking start that holds the caller for 5s.
    for a in "$@"; do
      [[ "$a" == "--no-block" ]] && exit 0
    done
    sleep 5
    exit 0
    ;;
  *)
    exit 0 ;;
esac
FAKE
chmod +x "$systemctl_noblock"

# Pre-create the .in packet so pi-issue-start skips regeneration, and point
# SEAT_LIB at a nonexistent path so the memory drop-in block is skipped —
# isolates the test to the final `exec systemctl start` line.
pi_issues_dir="$scratch/pi-issues"
mkdir -p "$pi_issues_dir"
printf 'worker prompt body\n\nTARGET: repo Nishfleet/demo issue 55 unit pi-issue-demo-55\n' \
    >"$pi_issues_dir/demo-55.in"

g_start=$(date +%s.%N)
set +e
g_out=$(SYSTEMCTL="$systemctl_noblock" START_LOG="$start_log" \
        PI_ISSUES_DIR="$pi_issues_dir" SEAT_LIB="/nonexistent/seat-lib.sh" \
        "$pi_issue_start_real" demo-55 2>&1)
g_rc=$?
set -e
g_end=$(date +%s.%N)
g_elapsed=$(awk -v s="$g_start" -v e="$g_end" 'BEGIN{printf "%.3f", e-s}')

[[ "$g_rc" == 0 ]] || fail "scenarioG: pi-issue-start must exit 0, got $g_rc ($g_out)"
# Must return well within the 5s blocking window (under 2s is comfortable headroom).
awk -v t="$g_elapsed" 'BEGIN{exit !(t < 2)}' \
    || fail "scenarioG: pi-issue-start took ${g_elapsed}s — NOT non-blocking (must be <2s; blocking path sleeps 5s)"
# The flag must actually have reached the fake systemctl.
grep -qx 'start --no-block pi-issue@demo-55.service' "$start_log" \
    || fail "scenarioG: start must carry --no-block, got $(cat "$start_log")"
ok "scenarioG: pi-issue-start dispatch is non-blocking (returned in ${g_elapsed}s, --no-block wired through)"

ok "red-pr-repair: observe-then-dispatch debounce, bounded 2 attempts, fail loud on exhaustion, live-worker skip, non-red clear, non-blocking dispatch"

echo "all phases passed"
