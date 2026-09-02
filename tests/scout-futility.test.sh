#!/usr/bin/env bash
# tests/scout-futility.test.sh
#
# Proves the green-and-empty scout detector (fleet-ops#454) offline:
#   1. Unit + MANIFEST wiring: ExecStartPre begin, ExecStopPost end,
#      both dash-prefixed; MANIFEST installs the helper.
#   2. One dry green run below the buffer: consecutive_dry=1, no ticket.
#   3. Drill: fixture scout that files nothing for N=3 runs while
#      ready stays at 2 -> LOUD SCOUT-FUTILITY + escalate-senior ticket
#      with signal key and both labels.
#   4. Fourth dry run: LOUD again, deduped (no second create).
#   5. Net ready increase resets the counter.
#   6. Ready at/above the 12h buffer cap does not escalate.
#   7. Non-zero scout exit does not increment (OnFailure owns crashes).
#   8. end without begin creates a snapshot (success-run), does not
#      increment consecutive_dry, does not file (fleet-ops#1277).
#   9. Tracker always exits 0 (must not fail the scout unit).
#  10. Production ExecStopPost shape (no argv, SERVICE_RESULT=success)
#      counts as a green dry run.
#  11. SERVICE_RESULT failure does not increment (OnFailure owns crashes).
#  12. begin writes last_run_epoch + fleet_scout_last_run_seconds; a
#      missing-begin end preserves last_run and does not bump it.
#  13. pi-scout@0509 uses the same template ExecCondition (no instance
#      override). fleet_rules.yml ships FleetScoutStale (organ heartbeat).
#  14. export_last_run writes fleet-scout.prom mode 0644 (node_exporter
#      is a different uid; mktemp is 0600 and would make the metric
#      absent — FleetScoutStale 2026-08-27T19:41Z).
#  15. last_run_epoch 0 / missing is omitted (a rest-skip end must not
#      export 0 and re-fire FleetScoutStale).
#
# The live pi-scout@ oneshot is the outermost edge (it would run a real
# LLM). The detector decision is exercised through the real helper.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/scout-futility-check"
unit="$repo_root/systemd/pi-scout@.service"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "scout-futility-check: bash syntax error"
[[ -f "$unit" ]] || fail "missing: $unit"
[[ -f "$manifest" ]] || fail "missing: $manifest"

# --- 1. wiring --------------------------------------------------------------
grep -q "ExecStartPre=-/bin/bash -c 'exec /home/nish/.local/bin/scout-futility-check begin %i'" "$unit" \
  || fail "pi-scout@.service must ExecStartPre=- scout-futility-check begin"
grep -q "ExecStopPost=-/bin/bash -c 'exec /home/nish/.local/bin/scout-futility-check end %i'" "$unit" \
  || fail "pi-scout@.service must ExecStopPost=- scout-futility-check end"
grep -q "pi-scout-run %i scout" "$unit" \
  || fail "pi-scout@.service ExecStart must still invoke pi-scout-run"
grep -q "fleet-work-supply-canary" "$unit" && grep -q "gate %i" "$unit" \
  || fail "pi-scout@.service ExecCondition must stay the hours gate"
! grep -E '^ExecCondition=.*scout-futility-check' "$unit" \
  || fail "scout-futility-check must not be an ExecCondition"
[[ ! -f "$repo_root/systemd/pi-scout@0509.service" ]] \
  || fail "pi-scout@0509 must not have an instance unit; it shares the template"
dropin="$repo_root/systemd/pi-scout@.service.d/10-keystone-hc.conf"
if [[ -f "$dropin" ]]; then
  ! grep -q '^ExecCondition=' "$dropin" \
    || fail "pi-scout@ drop-in must not replace ExecCondition"
fi
grep -Fxq "bin/scout-futility-check /home/nish/.local/bin/scout-futility-check" "$manifest" \
  || fail "MANIFEST missing scout-futility-check dest"
ok "wiring: unit snapshots begin/end; 0509 shares the template; MANIFEST installs the helper"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no "$unit" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for pi-scout@.service"
  ok "systemd-analyze verify accepts pi-scout@.service"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t scout-futility.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
state="$scratch/state"
mkdir -p "$state"
triage="$scratch/triage.md"
: >"$triage"

export SCOUT_FUTILITY_STATE_DIR="$state"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export SCOUT_FUTILITY_N=3
export SCOUT_FUTILITY_BUFFER=12
export SCOUT_FUTILITY_REPO="Nishfleet/fleet-ops"
export SCOUT_FUTILITY_FILE=1
export SCOUT_FUTILITY_READY_COUNT=2
export SCOUT_FUTILITY_PROM="$scratch/fleet-scout.prom"

gh_log="$scratch/gh.log"
open_issues="$scratch/open-issues.json"
echo '[]' >"$open_issues"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export GH_OPEN_ISSUES="$open_issues"
export PATH="$scratch:$PATH"

run_pair() {
  local rc1 rc2
  set +e
  "$bin" begin 0509 >/dev/null
  rc1=$?
  "$bin" end 0509 "${1:-0}" >/dev/null
  rc2=$?
  set -e
  [[ "$rc1" == "0" ]] || fail "begin must exit 0, got $rc1"
  [[ "$rc2" == "0" ]] || fail "end must exit 0, got $rc2"
}

state_field() {
  local field="${1:-}" repo="${2:-0509}"
  grep -E "^${field}=" "$state/${repo}.state" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# --- 2. one dry green run: track, do not file --------------------------------
: >"$gh_log"
: >"$triage"
run_pair 0
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario2: consecutive_dry must be 1, got '$(state_field consecutive_dry)'"
! grep -q 'issue create' "$gh_log" || fail "scenario2: must not file on first dry run"
! grep -q 'SCOUT-FUTILITY' "$triage" || fail "scenario2: must not LOUD on first dry run"
ok "scenario2: one dry green run tracks, does not escalate"

# --- 3. drill: fixture scout files nothing for N=3 --------------------------
: >"$gh_log"
: >"$triage"
run_pair 0
[[ "$(state_field consecutive_dry)" == "2" ]] \
  || fail "scenario3: after 2 dry runs consecutive_dry must be 2"
! grep -q 'issue create' "$gh_log" || fail "scenario3: must not file before N"
run_pair 0
[[ "$(state_field consecutive_dry)" == "3" ]] \
  || fail "scenario3: after 3 dry runs consecutive_dry must be 3"
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario3: missing LOUD SCOUT-FUTILITY (triage=$(cat "$triage"))"
grep -q 'issue create' "$gh_log" \
  || fail "scenario3: third dry run must auto-file (log=$(cat "$gh_log"))"
grep -q -- '--label escalate-senior' "$gh_log" \
  || fail "scenario3: ticket must carry escalate-senior"
grep -q -- '--label agent-ready' "$gh_log" \
  || fail "scenario3: ticket must carry agent-ready so intake can claim it"
grep -q -- '--body-file' "$gh_log" \
  || fail "scenario3: create must use --body-file"
grep -q '\[escalate-senior\] scout futility: Nishfleet/0509' "$gh_log" \
  || fail "scenario3: title must name the repo (log=$(cat "$gh_log"))"
ok "scenario3: drill — fixture scout files nothing for N=3, escalates"

# Reconstruct the body-file that create used is gone; lock the signal key
# by running create through a recorder that keeps the body. Re-check via
# a dedicated create capture on a fresh repo instance.
# (signal key is asserted in scenario4's open-issue fixture + in the
#  helper source, and again by feeding the marker back in scenario4.)
grep -q 'signal: scout-futility/' "$bin" \
  || fail "helper must embed signal: scout-futility/<repo> for the #362 pipeline"

# Capture body on a fresh repo so we can read the filed text.
: >"$gh_log"
: >"$triage"
rm -f "$state/fleet-ops.state"
export SCOUT_FUTILITY_READY_COUNT=0
body_cap="$scratch/filed-body.md"
cat >"$gh_fake" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${GH_LOG:-/dev/null}"
case "\$*" in
  *"issue create"*)
    bodyf=""
    prev=""
    for a in "\$@"; do
      if [[ "\$prev" == "--body-file" ]]; then
        bodyf="\$a"
      fi
      prev="\$a"
    done
    if [[ -n "\$bodyf" && -f "\$bodyf" ]]; then
      cp "\$bodyf" "$body_cap"
    fi
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue list"*)
    echo '[]'
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 0 >/dev/null
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 0 >/dev/null
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 0 >/dev/null
[[ -f "$body_cap" ]] || fail "scenario3b: did not capture filed body"
grep -Fq 'signal: scout-futility/fleet-ops' "$body_cap" \
  || fail "scenario3b: body missing signal key, got: $(cat "$body_cap")"
grep -Fq 'fleet-ops#454' "$body_cap" \
  || fail "scenario3b: body must cite #454"
ok "scenario3b: filed body carries signal: scout-futility/<repo>"

# --- 4. fourth dry run: LOUD, deduped ---------------------------------------
# Restore the 0509 fake gh that serves an already-open issue with the marker.
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export SCOUT_FUTILITY_READY_COUNT=2
cat >"$open_issues" <<'JSON'
[{"number": 77, "body": "already open\n\nsignal: scout-futility/0509\n"}]
JSON
: >"$gh_log"
: >"$triage"
run_pair 0
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario4: still LOUD on later dry runs"
grep -q 'issue create' "$gh_log" \
  && fail "scenario4: must not file a second ticket (log=$(cat "$gh_log"))"
ok "scenario4: later dry runs stay LOUD and dedupe"

# --- 5. net increase resets -------------------------------------------------
echo '[]' >"$open_issues"
: >"$gh_log"
: >"$triage"
export SCOUT_FUTILITY_READY_COUNT=2
"$bin" begin 0509 >/dev/null
export SCOUT_FUTILITY_READY_COUNT=5
"$bin" end 0509 0 >/dev/null
[[ "$(state_field consecutive_dry)" == "0" ]] \
  || fail "scenario5: net increase must reset consecutive_dry, got '$(state_field consecutive_dry)'"
! grep -q 'issue create' "$gh_log" || fail "scenario5: must not file on increase"
ok "scenario5: net ready-work increase resets the counter"

# --- 6. at/above buffer cap does not escalate --------------------------------
: >"$gh_log"
: >"$triage"
# Force a high consecutive_dry then a dry run at the cap.
printf '%s\n' 'before=12' 'consecutive_dry=2' >"$state/0509.state"
export SCOUT_FUTILITY_READY_COUNT=12
"$bin" begin 0509 >/dev/null
"$bin" end 0509 0 >/dev/null
[[ "$(state_field consecutive_dry)" == "0" ]] \
  || fail "scenario6: at buffer cap must reset, got '$(state_field consecutive_dry)'"
! grep -q 'SCOUT-FUTILITY' "$triage" || fail "scenario6: must not LOUD at cap"
ok "scenario6: ready at the 12h buffer cap does not escalate"

# --- 7. non-zero exit does not increment ------------------------------------
: >"$gh_log"
: >"$triage"
export SCOUT_FUTILITY_READY_COUNT=1
printf '%s\n' 'before=1' 'consecutive_dry=2' >"$state/0509.state"
"$bin" begin 0509 >/dev/null
"$bin" end 0509 1 >/dev/null
[[ "$(state_field consecutive_dry)" == "2" ]] \
  || fail "scenario7: crash must leave consecutive_dry untouched, got '$(state_field consecutive_dry)'"
! grep -q 'issue create' "$gh_log" || fail "scenario7: crash must not file futility"
ok "scenario7: non-zero exit does not increment (OnFailure owns crashes)"

# --- 8. end without begin creates a snapshot (success-run) ------------------
: >"$gh_log"
: >"$triage"
rm -f "$state/siterep-public.state"
set +e
"$bin" end siterep-public 0 >/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario8: end without begin must exit 0, got $rc"
[[ -f "$state/siterep-public.state" ]] \
  || fail "scenario8: missing snapshot must create a state file"
siterep_dry=$(grep -E '^consecutive_dry=' "$state/siterep-public.state" | cut -d= -f2-)
[[ "$siterep_dry" == "0" ]] \
  || fail "scenario8: must not increment consecutive_dry, got '$siterep_dry'"
siterep_before=$(grep -E '^before=' "$state/siterep-public.state" | cut -d= -f2-)
[[ -z "$siterep_before" ]] \
  || fail "scenario8: seeded snapshot must leave before empty so a later skip-end cannot false-count dry, got '$siterep_before'"
siterep_run=$(grep -E '^last_run_epoch=' "$state/siterep-public.state" | cut -d= -f2-)
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_uint "$siterep_run" && [[ "$siterep_run" -gt 0 ]] \
  || fail "scenario8: missing-begin end must refresh last_run_epoch to a live tick, got '$siterep_run'"
grep -q "fleet_scout_last_run_seconds{repo=\"siterep-public\"} ${siterep_run}" "$scratch/fleet-scout.prom" \
  || fail "scenario8: prom must export the refreshed live tick for siterep-public"
! grep -q 'issue create' "$gh_log" || fail "scenario8: must not file"
ok "scenario8: end without begin creates snapshot, success-run, refreshes live epoch"

# --- 9. tracker always exits 0 ----------------------------------------------
set +e
"$bin" begin 'bad/repo' >/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario9: invalid repo must still exit 0, got $rc"
ok "scenario9: tracker always exits 0 so it cannot fail the scout"

# --- 10. production ExecStopPost shape: no argv, SERVICE_RESULT=success -----
# pi-scout@.service calls `end %i` with no exit-code argv. systemd sets
# SERVICE_RESULT / EXIT_STATUS on ExecStopPost. That path must count as green.
: >"$gh_log"
: >"$triage"
rm -f "$state/0509.state"
export SCOUT_FUTILITY_READY_COUNT=2
unset SERVICE_RESULT EXIT_STATUS || true
"$bin" begin 0509 >/dev/null
export SERVICE_RESULT=success
"$bin" end 0509 >/dev/null
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario10: SERVICE_RESULT=success must count as green dry, got '$(state_field consecutive_dry)'"
ok "scenario10: ExecStopPost-shaped end (SERVICE_RESULT=success) counts as green"

# --- 11. SERVICE_RESULT failure does not increment --------------------------
unset SERVICE_RESULT EXIT_STATUS || true
export SERVICE_RESULT=exit-code
export EXIT_STATUS=1
printf '%s\n' 'before=2' 'consecutive_dry=2' >"$state/0509.state"
"$bin" begin 0509 >/dev/null
"$bin" end 0509 >/dev/null
[[ "$(state_field consecutive_dry)" == "2" ]] \
  || fail "scenario11: failed SERVICE_RESULT must leave consecutive_dry, got '$(state_field consecutive_dry)'"
ok "scenario11: ExecStopPost-shaped crash does not increment"

# --- 12. begin writes last_run; missing-begin end does not bump it ----------
unset SERVICE_RESULT EXIT_STATUS || true
: >"$gh_log"
: >"$triage"
rm -f "$state/0509.state" "$scratch/fleet-scout.prom"
export SCOUT_FUTILITY_READY_COUNT=2
"$bin" begin 0509 >/dev/null
epoch1=$(state_field last_run_epoch)
is_epoch() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_epoch "$epoch1" && [[ "$epoch1" -gt 0 ]] \
  || fail "scenario12: begin must write last_run_epoch > 0, got '$epoch1'"
grep -q "fleet_scout_last_run_seconds{repo=\"0509\"} ${epoch1}" "$scratch/fleet-scout.prom" \
  || fail "scenario12: prom missing last_run for 0509 (prom=$(cat "$scratch/fleet-scout.prom" 2>/dev/null))"
"$bin" end 0509 0 >/dev/null
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario12: first completed end should dry=1"
epoch_after_real_end=$(state_field last_run_epoch)
[[ "$epoch_after_real_end" == "$epoch1" ]] \
  || fail "scenario12: real end must preserve begin epoch ($epoch1), got '$epoch_after_real_end'"
grep -q "fleet_scout_last_run_seconds{repo=\"0509\"} ${epoch1}" "$scratch/fleet-scout.prom" \
  || fail "scenario12: real end must not disturb begin epoch in prom"
"$bin" end 0509 0 >/dev/null
epoch_after_missing=$(state_field last_run_epoch)
[[ "$epoch_after_missing" -ge "$epoch1" ]] \
  || fail "scenario12: missing-begin end must refresh last_run_epoch (>= $epoch1), got '$epoch_after_missing'"
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario12: missing-begin end must not increment dry, got '$(state_field consecutive_dry)'"
grep -q "fleet_scout_last_run_seconds{repo=\"0509\"} ${epoch_after_missing}" "$scratch/fleet-scout.prom" \
  || fail "scenario12: skip-end must export the refreshed live epoch in prom"
! grep -q 'issue create' "$gh_log" || fail "scenario12: must not file"
ok "scenario12: begin epoch preserved across real ends; missing-begin ends refresh"

# --- 12b. unreadable snapshot is the same success-run path ------------------
printf 'this is garbage\nnot a state file\n' >"$state/0509.state"
set +e
"$bin" end 0509 0 >/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario12b: unreadable snapshot must exit 0, got $rc"
[[ "$(state_field consecutive_dry)" == "0" ]] \
  || fail "scenario12b: unreadable snapshot must seed consecutive_dry=0, got '$(state_field consecutive_dry)'"
ok "scenario12b: unreadable snapshot creates a clean snapshot, success-run"

# --- 13. FleetScoutStale organ heartbeat + 0509 shares the template ---------
rules="$repo_root/config/fleet_rules.yml"
[[ -f "$rules" ]] || fail "missing $rules"
grep -q 'alert: FleetScoutStale' "$rules" \
  || fail "fleet_rules.yml missing FleetScoutStale (organ heartbeat)"
grep -q 'absent(fleet_scout_last_run_seconds)' "$rules" \
  || fail "FleetScoutStale must key absent() on fleet_scout_last_run_seconds"
grep -q 'time() - fleet_scout_last_run_seconds' "$rules" \
  || fail "FleetScoutStale must compare time() - last_run"
grep -q '28800' "$rules" \
  || fail "FleetScoutStale threshold must be 8h (28800s, two 4h ticks)"
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed after FleetScoutStale"
  ok "promtool check rules accepts FleetScoutStale"
else
  echo "SKIP: promtool not on PATH"
fi
ok "scenario13: FleetScoutStale ships with the organ; 0509 uses the shared template"

# --- 14. fleet-scout.prom is 0644 (node_exporter is prometheus uid) ---------
unset SERVICE_RESULT EXIT_STATUS || true
rm -f "$scratch/fleet-scout.prom"
export SCOUT_FUTILITY_READY_COUNT=2
"$bin" begin 0509 >/dev/null
mode=$(stat -c '%a' "$scratch/fleet-scout.prom")
[[ "$mode" == "644" ]] \
  || fail "scenario14: begin must write fleet-scout.prom mode 0644, got '$mode'"
# A leftover 0600 (the live 2026-08-27 failure) must be repaired on rewrite.
chmod 0600 "$scratch/fleet-scout.prom"
"$bin" end 0509 0 >/dev/null
mode=$(stat -c '%a' "$scratch/fleet-scout.prom")
[[ "$mode" == "644" ]] \
  || fail "scenario14: end must rewrite fleet-scout.prom mode 0644, got '$mode'"
ok "scenario14: fleet-scout.prom is 0644 after begin and after end"

# --- 15. rest-skip end must not export last_run=0 ---------------------------
unset SERVICE_RESULT EXIT_STATUS || true
rm -f "$state/0509.state" "$state/fleet-ops.state" "$scratch/fleet-scout.prom"
export SCOUT_FUTILITY_READY_COUNT=2
"$bin" begin 0509 >/dev/null
epoch1=$(state_field last_run_epoch)
"$bin" end fleet-ops 0 >/dev/null
grep -q "fleet_scout_last_run_seconds{repo=\"0509\"} ${epoch1}" "$scratch/fleet-scout.prom" \
  || fail "scenario15: 0509 last_run must survive a fleet-ops rest-skip end"
if grep -E 'fleet_scout_last_run_seconds\{repo="fleet-ops"\} 0$' "$scratch/fleet-scout.prom"; then
  fail "scenario15: rest-skip must not export fleet-ops last_run=0 (prom=$(cat "$scratch/fleet-scout.prom"))"
fi
ok "scenario15: rest-skip end omits last_run=0"

# --- 16. runway is measured in hours, not just ready items ------------------
# 12 ready issues with no consumption = 12h runway (>= cap) -> reset.
# 12 ready with 12 closed in the last 6h = drain rate 2/h -> runway 6h.
# The item count alone would say "at cap"; the hours metric must escalate.
: >"$gh_log"
: >"$triage"
rm -f "$state/0509.state"
export SCOUT_FUTILITY_READY_COUNT=12
export SCOUT_FUTILITY_CLOSED_JSON="$scratch/closed-12.json"
now=$(date -u +%s)
jq -n --arg ts "$(date -u -d '@'"$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
  '[range(12) | {number:(.+1), closedAt:$ts}]' >"$SCOUT_FUTILITY_CLOSED_JSON"
printf '%s\n' 'before=12' 'consecutive_dry=2' >"$state/0509.state"
"$bin" begin 0509 >/dev/null
"$bin" end 0509 0 >/dev/null
[[ "$(state_field consecutive_dry)" == "3" ]] \
  || fail "scenario16: 12 ready with high drain (12 closed in 6h) = 6h runway; should escalate, got '$(state_field consecutive_dry)'"
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario16: missing LOUD SCOUT-FUTILITY for runway < 12h"
ok "scenario16: runway in hours — high drain turns 12 ready items into 6h buffer, escalates"
unset SCOUT_FUTILITY_CLOSED_JSON

# --- 17. provider-wall crash loop (fleet-ops#2468) ---------------------------
# N consecutive crashes where EVERY journal error line matches a provider-wall
# pattern (503 overloaded_error, 429 FreeUsageLimitError, INFERENCE_CAP_ERROR,
# out-of-credits, 404 "Provider returned error") are structurally equivalent
# to green-and-empty futility: a bench/seat famine, not a work crash. The
# tracker escalates ONCE under signal: scout-futility/<repo> (so the existing
# unit-escalation-write dedupe gate matches it), then dedupes on repeats.
# Non-wall crashes do NOT increment consecutive_wall.
unset SCOUT_FUTILITY_CLOSED_JSON || true
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
rm -f "$state/fleet-ops.state"
export SCOUT_FUTILITY_READY_COUNT=16

# Stub journalctl that emulates journald filtering: `-p err` returns only
# err-priority lines, `-n N` truncates to the last N lines, and priority
# tags are stripped like `journalctl -o cat`. The provider wall error is
# printed by the pi script at info priority, so the err-priority view never
# sees it and only the all-priority -n 50 view (the hot-patch, fleet-ops
# #2521) reaches it.
# Body is written to a separate file and read by the stub so JSON quotes
# inside the body don't conflict with the stub's quoting.
mkdir -p "$scratch/bin"
write_journalctl_stub() {
    cat >"$scratch/bin/journalctl" <<'EOFSTUB'
#!/usr/bin/env bash
# Body is read from $JOURNALCTL_BODY_FILE (set by the test) so JSON quotes
# inside the body never touch this script's quoting. Fixture lines may carry
# a `info:` / `err:` priority tag; -o cat output strips them.
body_file="${JOURNALCTL_BODY_FILE:-/dev/null}"
n=10
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-n" ]]; then
        case "$arg" in ''|*[!0-9]*) ;; *) n="$arg" ;; esac
    fi
    prev="$arg"
done
if [[ -f "$body_file" ]]; then
    if [[ "$*" == *"-p err"* ]]; then
        grep '^err:' "$body_file" | tail -n "$n" | sed 's/^err: //'
    else
        sed 's/^\(info\|err\): //' "$body_file" | tail -n "$n"
    fi
fi
exit 0
EOFSTUB
    chmod +x "$scratch/bin/journalctl"
}
write_journalctl_stub
export JOURNALCTL="$scratch/bin/journalctl"
export PATH="$scratch/bin:$PATH"

# Scenario 17a: 3 consecutive wall-crashes on fleet-ops -> escalate under
# signal: scout-futility/fleet-ops. First two do not file; third does.
echo '503: {"message":"Upstream model provider is temporarily unavailable. Please try again in a moment.","type":"overloaded_error"}' >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"

# Set up body-capture gh BEFORE the wall-crashes fire. Wall-crash #3 will
# invoke file_wall_escalation which calls gh_create, so the body-cap gh
# must be on disk by then. (Setting this AFTER the wall-crashes fire
# means the cap gh is never seen by the test's python subprocess.)
body_cap_wall="$scratch/filed-body-wall.md"
cat >"$gh_fake" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${GH_LOG:-/dev/null}"
case "\$*" in
    *"issue create"*)
        bodyf=""
        prev=""
        for a in "\$@"; do
            if [[ "\$prev" == "--body-file" ]]; then
                bodyf="\$a"
            fi
            prev="\$a"
        done
        # When GH_BODY_CAP is set, capture the body file there too.
        if [[ -n "\$bodyf" && -f "\$bodyf" ]]; then
            if [[ -n "\${GH_BODY_CAP:-}" ]]; then
                cp "\$bodyf" "\$GH_BODY_CAP" 2>&1 || true
            fi
        fi
        echo "https://github.com/Nishfleet/fleet-ops/issues/2468"
        exit 0
        ;;
    *"issue list"*)
        echo '[]'
        exit 0
        ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH_BODY_CAP="$body_cap_wall"

"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "1" ]] \
  || fail "scenario17a: first wall-crash must set consecutive_wall=1, got '$(state_field consecutive_wall fleet-ops)'"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario17a: must not file on first wall-crash (gh_log=$(cat "$gh_log"))"

"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "2" ]] \
  || fail "scenario17b: second wall-crash must set consecutive_wall=2, got '$(state_field consecutive_wall fleet-ops)'"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario17b: must not file on second wall-crash (gh_log=$(cat "$gh_log"))"

"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "3" ]] \
  || fail "scenario17c: third wall-crash must set consecutive_wall=3, got '$(state_field consecutive_wall fleet-ops)'"
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario17c: missing LOUD SCOUT-FUTILITY (triage=$(cat "$triage"))"
grep -q 'issue create' "$gh_log" \
  || fail "scenario17c: third wall-crash must auto-file (gh_log=$(cat "$gh_log"))"
grep -q -- '--label escalate-senior' "$gh_log" \
  || fail "scenario17c: ticket must carry escalate-senior label (gh_log=$(cat "$gh_log"))"
grep -q '\[escalate-senior\] scout wall-crash loop: Nishfleet/fleet-ops' "$gh_log" \
  || fail "scenario17c: title must name wall-crash + repo (gh_log=$(cat "$gh_log"))"
[[ -f "$body_cap_wall" ]] || fail "scenario17c: did not capture filed body"
grep -Fq 'signal: scout-futility/fleet-ops' "$body_cap_wall" \
  || fail "scenario17c: filed body missing signal key, got: $(cat "$body_cap_wall")"
grep -Fq 'consecutive_wall' "$body_cap_wall" \
  || fail "scenario17c: filed body must name consecutive_wall in evidence, got: $(cat "$body_cap_wall")"
grep -Fq 'overloaded_error' "$body_cap_wall" \
  || fail "scenario17c: filed body must name wall-class evidence (overloaded_error), got: $(cat "$body_cap_wall")"
ok "scenario17c: 3 consecutive wall-crashes escalate under signal: scout-futility/fleet-ops"

# Scenario 17d: 4th wall-crash with prior ticket open -> NO new ticket.
# Restore the 0509-style fake gh that serves an already-open issue with the
# signal marker (this is the existing dedupe path used by scenario4).
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
    *"issue create"*)
        echo "https://github.com/Nishfleet/fleet-ops/issues/2468"
        exit 0
        ;;
    *"issue list"*)
        if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
            cat "${GH_OPEN_ISSUES}"
        else
            echo '[]'
        fi
        exit 0
        ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
cat >"$open_issues" <<'JSON'
[{"number": 2468, "body": "already open\n\nsignal: scout-futility/fleet-ops\n"}]
JSON
: >"$gh_log"
: >"$triage"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "4" ]] \
  || fail "scenario17d: fourth wall-crash must still increment to 4, got '$(state_field consecutive_wall fleet-ops)'"
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario17d: still LOUD on later wall-crashes"
grep -q 'issue create' "$gh_log" \
  && fail "scenario17d: must NOT file a second ticket (gh_log=$(cat "$gh_log"))"
ok "scenario17d: wall-crash loop escalates once, dedupes on repeats"

# Scenario 17e: non-wall crash (exit=1, journal empty / non-wall lines) does
# NOT increment consecutive_wall. A transient worker assertion or OOM must
# not be mistaken for provider-wall class.
echo 'AssertionError: expected design-system-ratchet counts to match ceiling' >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
: >"$gh_log"
: >"$triage"
# Reset consecutive_wall via a green run on a clean repo so we test the
# "non-wall crash resets" path on a fresh counter starting from >= N.
# Actually, simpler: the current state has consecutive_wall=4. Issue a
# non-wall crash and verify consecutive_wall resets to 0.
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "0" ]] \
  || fail "scenario17e: non-wall crash must reset consecutive_wall to 0, got '$(state_field consecutive_wall fleet-ops)'"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario17e: non-wall crash must not file futility (gh_log=$(cat "$gh_log"))"
ok "scenario17e: non-wall crash resets consecutive_wall, no escalation"

# Scenario 17f: a single mixed run (one wall line + one non-wall line) is NOT
# wall-class — the rule is ALL non-empty error lines match. This protects
# against misclassifying a flaky seat or a real bug that happens to mention
# "INFERENCE_CAP_ERROR" once.
printf '503 overloaded_error\nAssertionError: should not reach here\n' >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
: >"$gh_log"
: >"$triage"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "0" ]] \
  || fail "scenario17f: mixed wall + non-wall lines must reset consecutive_wall, got '$(state_field consecutive_wall fleet-ops)'"
ok "scenario17f: mixed wall + non-wall lines are NOT wall-class"

# Scenario 17g: opencode 404 "Provider returned error" pattern is wall-class
# (the opencode corpse class: the model itself is gone, provider returns 404
# forever; bench/seat famine, not a work fault). Issue the issue body line
# alone, no 503 / 429 noise.
echo 'opencode API error: 404 Provider returned error for model muse-spark-1.2-contributor-free' >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "3" ]] \
  || fail "scenario17g: opencode 404 'Provider returned error' alone is wall-class, got consecutive_wall='$(state_field consecutive_wall fleet-ops)'"
grep -q 'SCOUT-FUTILITY' "$triage" \
  || fail "scenario17g: opencode 404 wall-crash must LOUD on N=3 (triage=$(cat "$triage"))"
ok "scenario17g: opencode 404 'Provider returned error' is wall-class"

# Scenario 17h: provider wall at INFO priority, 40 lines back (fleet-ops
# #2521). The pi script prints the 503/429 wall error to stdout/stderr at
# info priority, not err. A long run pushes it far back. The pattern merged
# in PR #2498 scanned `-p err -n 10`: it loses the case twice — the
# err-priority filter drops the info line entirely, and a 10-line tail
# window cannot reach 40 lines back. The hot-patch scans the last 50 lines
# at all priorities. Fixture: 50 info-priority lines, the explicit
# `503 overloaded_error` at line 10 (40 lines from the tail), the rest a
# retry storm that also carries the wall pattern so EVERY line in the
# 50-line window matches (the strict all-lines rule for wall class).
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
rm -f "$state/fleet-ops.state"
{
    i=1
    while [[ $i -le 50 ]]; do
        if [[ $i -eq 10 ]]; then
            printf 'info: INFO pi: HTTP 503 overloaded_error: Upstream model provider is temporarily unavailable\n'
        else
            printf 'info: INFO pi: retry %d/60 (overloaded_error)\n' "$i"
        fi
        i=$((i + 1))
    done
} >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"

# The OLD invocation shape (-p err -n 10) sees nothing: the wall line is
# info priority, 40 lines back.
old_out=$("$scratch/bin/journalctl" --user -u pi-scout@fleet-ops.service -p err -n 10 --no-pager -o cat 2>/dev/null || true)
[[ -z "$old_out" ]] \
  || fail "scenario17h: err-priority view must be empty for an info-priority wall line, got: $old_out"
# Even at all priorities, a 10-line tail window stops 40 lines short.
tail10=$("$scratch/bin/journalctl" --user -u pi-scout@fleet-ops.service -n 10 --no-pager -o cat 2>/dev/null || true)
! grep -q '503 overloaded_error' <<<"$tail10" \
  || fail "scenario17h: -n 10 tail must not reach the wall line 40 lines back"
# The fixed invocation (-n 50, all priorities) reaches 40 lines back and
# surfaces the info-priority 503.
window50=$("$scratch/bin/journalctl" --user -u pi-scout@fleet-ops.service -n 50 --no-pager -o cat 2>/dev/null || true)
grep -q '503 overloaded_error' <<<"$window50" \
  || fail "scenario17h: -n 50 window must include the wall line 40 lines back"

# The helper source must keep the all-priority 50-line scan (a re-narrowing
# to -p err -n 10 would break this scenario AND silently miss info-priority
# wall crashes in production).
grep -q -- '--user -u "\$unit" -n 50' "$bin" \
  || fail "scenario17h: helper must scan the last 50 lines at all priorities"
! grep -q -- '-p err -n 10' "$bin" \
  || fail "scenario17h: helper must not filter -p err (info-priority wall lines would vanish)"

# End-to-end through the real helper: one crash on this journal counts as a
# wall crash (detect_provider_wall returns true; consecutive_wall bumps).
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "1" ]] \
  || fail "scenario17h: info-priority 503 40 lines back must count as wall-class, got consecutive_wall='$(state_field consecutive_wall fleet-ops)'"
ok "scenario17h: provider wall at info priority 40 lines back is detected (all priorities, -n 50)"

# Scenario 17i: PRODUCTION-mixed journal (the real 2026-08-31 failed-run
# layout) is wall-class. The fatal 503/429 line ALWAYS lands next to benign
# pi-machinery + systemd lifecycle lines (EXTLOAD-OK, PACKET-VERDICT, seat
# selection, tracker logs, notify;Pi, "Main process exited", "Failed to
# start", "Consumed ... CPU time"). The all-lines-must-match rule could
# never succeed against this journal, so consecutive_wall stayed pinned at 0
# and the #2351 dedupe gate never opened — every crash re-summoned the
# auditor (the 08-31 loop). Fixture mirrors journald -o cat output for the
# failed run at 15:07Z on 2026-08-31.
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
rm -f "$state/fleet-ops.state"
{
    # Faithful to production 2026-08-31: the fatal 503 is printed by pi on
    # the SAME journal line as the trailing notify;Pi escape sequence
    # (journald preserves the glue), surrounded by benign machinery lines.
    printf 'EXTLOAD-OK extension=bash-spawn-hook guard=tool_call depth_max=1 ceiling=2800/3000 wrangler_deploy_guard=0509\n'
    printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\n'
    printf 'EXTLOAD-OK extension=seat-health source=after_provider_response\n'
    printf 'EXTLOAD-OK extension=stop-judge mode=print-safe\n'
    printf '\033]777;notify;Pi;Ready for input\007\033]777;notify;Pi;Ready for input\007503: {"message":"Upstream model provider is temporarily unavailable. Please try again in a moment.","type":"overloaded_error"}\n'
    printf 'PACKET-VERDICT tools=4 class=worked\n'
    printf 'pi-scout@fleet-ops.service: Main process exited, code=exited, status=1/FAILURE\n'
    printf '[2026-08-31T15:07:21Z] [scout-futility-check] end: fleet-ops exit=1 (not green, not provider-wall) — leave consecutive_dry=0, consecutive_wall=0\n'
    printf '[2026-08-31T15:07:23Z] pi-scout-run: fleet-ops/scout running on commandcode/minimax/minimax-m3-free (weight=heavy)\n'
    printf "pi-scout@fleet-ops.service: Failed with result 'exit-code'.\n"
    printf 'Failed to start pi-scout@fleet-ops.service - Pi fleet product scout for Nishfleet/fleet-ops.\n'
    printf 'pi-scout@fleet-ops.service: Triggering OnFailure= dependencies.\n'
    printf 'pi-scout@fleet-ops.service: Consumed 4.442s CPU time, 98.5M memory peak, 0B memory swap peak.\n'
} >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "1" ]] \
  || fail "scenario17i: production-mixed journal (benign machinery + 503) must be wall-class, got consecutive_wall='$(state_field consecutive_wall fleet-ops)'"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "2" ]] \
  || fail "scenario17i: second production-mixed wall crash must increment to 2, got '$(state_field consecutive_wall fleet-ops)'"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario17i: must not file below N=3 (gh_log=$(cat "$gh_log"))"
ok "scenario17i: production-mixed journal is wall-class (benign lines no longer demote)"

# Scenario 17j: production-mixed journal PLUS a non-wall work fault line is
# NOT wall-class — a real assertion/tool error next to a 503 demotes the run
# so OnFailure repair handles it. Benign-line filtering must not swallow work
# faults.
{
    printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\n'
    printf '\033]777;notify;Pi;Ready for input\007503: {"message":"Upstream model provider is temporarily unavailable. Please try again in a moment.","type":"overloaded_error"}\n'
    printf 'PACKET-VERDICT tools=4 class=worked\n'
    printf 'Error: unexpected token in JSON at position 42\n'
    printf 'pi-scout@fleet-ops.service: Main process exited, code=exited, status=1/FAILURE\n'
} >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
"$bin" begin fleet-ops >/dev/null
"$bin" end fleet-ops 1 >/dev/null
[[ "$(state_field consecutive_wall fleet-ops)" == "0" ]] \
  || fail "scenario17j: mixed benign + wall + work-fault journal must reset consecutive_wall, got '$(state_field consecutive_wall fleet-ops)'"
ok "scenario17j: work-fault line still demotes inside a production-mixed journal"

# Scenario 17k: prior-run non-wall lines in the bare -n 50 window must NOT
# demote the CURRENT run's 503 when begin_at scopes journalctl --since.
# Proven live 2026-09-02T19:46Z: pi-scout@0509 died on overloaded_error but
# detect_provider_wall returned false because the previous invocation's
# "Devin exited ... resource_exhausted" / JSON fragment sat inside -n 50 and
# demoted the whole window. begin_at (written by cmd_begin) scopes the read.
# Fixture encoding: lines before '---SINCE---' = prior-run residue; lines
# after = current run. The stub drops prior lines when --since is in argv.
write_journalctl_stub_since() {
    cat >"$scratch/bin/journalctl" <<'EOFSTUB'
#!/usr/bin/env bash
body_file="${JOURNALCTL_BODY_FILE:-/dev/null}"
n=10
prev=""
since=0
for arg in "$@"; do
    if [[ "$prev" == "-n" ]]; then
        case "$arg" in ''|*[!0-9]*) ;; *) n="$arg" ;; esac
    fi
    if [[ "$arg" == "--since" ]]; then since=1; fi
    prev="$arg"
done
if [[ -f "$body_file" ]]; then
    if [[ "$since" == "1" ]] && grep -q '^---SINCE---$' "$body_file"; then
        body=$(awk 'f; /^---SINCE---$/ {f=1; next}' "$body_file")
    else
        body=$(cat "$body_file")
    fi
    if [[ " $* " == *" -p err "* ]]; then
        printf '%s\n' "$body" | grep '^err:' | tail -n "$n" | sed 's/^err: //'
    else
        printf '%s\n' "$body" | sed 's/^\(info\|err\): //' | sed '/^---SINCE---$/d' | tail -n "$n"
    fi
fi
exit 0
EOFSTUB
    chmod +x "$scratch/bin/journalctl"
}
write_journalctl_stub_since
export JOURNALCTL="$scratch/bin/journalctl"
{
    # Prior-run residue: a real work-fault demoter (NOT a wall pattern).
    printf 'Error: unexpected token in JSON at position 42\n'
    printf 'Traceback (most recent call last): KeyError: patch\n'
    printf '%s\n' '---SINCE---'
    # Current-run pure wall (production-mixed)
    printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\n'
    printf '\033]777;notify;Pi;Ready for input\007503: {"message":"Upstream model provider is temporarily unavailable. Please try again in a moment.","type":"overloaded_error"}\n'
    printf 'PACKET-VERDICT tools=3 class=worked\n'
    printf 'pi-scout@0509.service: Main process exited, code=exited, status=1/FAILURE\n'
} >"$scratch/journalctl-body.txt"
export JOURNALCTL_BODY_FILE="$scratch/journalctl-body.txt"
: >"$gh_log"
: >"$triage"
echo '[]' >"$open_issues"
rm -f "$state/0509.state"
# begin writes begin_at → detect_provider_wall passes --since → stub drops
# the prior KeyError → current 503 is wall-class.
"$bin" begin 0509 >/dev/null
"$bin" end 0509 1 >/dev/null
[[ "$(state_field consecutive_wall 0509)" == "1" ]] \
  || fail "scenario17k: begin_at-scoped journal must classify current 503 as wall despite prior-run KeyError, got consecutive_wall='$(state_field consecutive_wall 0509)'"
# Current-window KeyError must still demote (scope must not swallow real faults).
{
    printf '%s\n' '---SINCE---'
    printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\n'
    printf '\033]777;notify;Pi;Ready for input\007503: {"message":"Upstream model provider is temporarily unavailable. Please try again in a moment.","type":"overloaded_error"}\n'
    printf 'Error: unexpected token in JSON at position 42\n'
    printf 'PACKET-VERDICT tools=3 class=worked\n'
} >"$scratch/journalctl-body.txt"
"$bin" begin 0509 >/dev/null
"$bin" end 0509 1 >/dev/null
[[ "$(state_field consecutive_wall 0509)" == "0" ]] \
  || fail "scenario17k: current-window KeyError must still demote, got consecutive_wall='$(state_field consecutive_wall 0509)'"
ok "scenario17k: begin_at scopes journal so prior-run faults cannot demote current wall"

# Reset journalctl stub + state file so subsequent test runs (if any) start clean.
unset JOURNALCTL JOURNALCTL_BODY_FILE
rm -f "$scratch/journalctl-body.txt"
ok "scenario17: provider-wall crash loop escalates + dedupes (fleet-ops#2468)"

echo "OK: scout-futility: green-and-empty + provider-wall crash loop escalates after N, never loops quietly"
