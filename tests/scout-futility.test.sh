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
  grep -E "^${1}=" "$state/0509.state" 2>/dev/null | head -n 1 | cut -d= -f2-
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
! grep -q 'issue create' "$gh_log" || fail "scenario8: must not file"
ok "scenario8: end without begin creates snapshot, success-run, not a dry count"

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
"$bin" end 0509 0 >/dev/null
[[ "$(state_field last_run_epoch)" == "$epoch1" ]] \
  || fail "scenario12: missing-begin end must preserve last_run_epoch ($epoch1), got '$(state_field last_run_epoch)'"
[[ "$(state_field consecutive_dry)" == "1" ]] \
  || fail "scenario12: missing-begin end must not increment dry, got '$(state_field consecutive_dry)'"
grep -q "fleet_scout_last_run_seconds{repo=\"0509\"} ${epoch1}" "$scratch/fleet-scout.prom" \
  || fail "scenario12: skip-end must not bump exported last_run"
! grep -q 'issue create' "$gh_log" || fail "scenario12: must not file"
ok "scenario12: last_run is begin-only; missing-begin end preserves it"

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

echo "OK: scout-futility: green-and-empty scout escalates after N dry runs, never loops quietly"
