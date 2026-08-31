#!/usr/bin/env bash
# tests/fleet-canary-gh-failure-detector.test.sh
#
# fleet-ops#2538: data-plane failure detector for the gh-calling coverage
# canaries. Proves prevent + detect + observe-to-close, fully offline
# (stubbed journal + gh + issue-file):
#
#   1. WARN=0        -> no ticket, metric streak=0, exit 0.
#   2. WARN=2 in 1h  -> under threshold, no ticket, streak=2 metric.
#   3. WARN=3 in 1h  -> ticket filed via fleet-issue-file, metric streak=3.
#   4. WARN=3 across two ticks -> one ticket, signal: canary-gh-failure/
#      fleet-escalation-canary, deduped on the second tick.
#   5. Streak cleared (WARN=0) -> observe-to-close comments + closes the
#      ticket on the next clean tick (opt-in env + fresh sentinel).
#   6. A still-WARN under-threshold canary (count 1-2) keeps its ticket
#      open (no close while the streak is not fully clear).
#   7. Journal rotated (empty) but marker files carry the WARNs -> the
#      marker fallback still triggers detection.
#   8. The escalation + credential-expiry canaries write/clear the markers.
#   9. tier1 block wires the detector with opt-in close env + sentinel;
#      MANIFEST installs it.
#   10. rule-enforcement matrix row covers the data-plane failure watch.
#
# Hosted from tests/escalation-coverage-canary.test.sh (already in P14) so
# the worker token does not need .github/workflows/** write access.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-canary-gh-failure-detector"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"
esc_canary="$repo_root/bin/fleet-escalation-canary"
cred_canary="$repo_root/bin/fleet-credential-expiry-canary"
host="$here/escalation-coverage-canary.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "detector: bash syntax error"
bash -n "$tier1" || fail "tier1: bash syntax error"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t canary-gh-failure-detector.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
record() { printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"; }
record "$@"
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
    cat "${GH_OPEN_ISSUES}"
  else
    echo '[]'
  fi
  exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = close ]; then
  num=${3:-}
  if [[ -n "$num" && "$num" =~ ^[0-9]+$ ]]; then
    if [[ -f "${GH_CLOSED_ISSUES:-/dev/null}" ]]; then
      printf '%s\n' "$num" >>"${GH_CLOSED_ISSUES}"
    fi
    echo "https://github.com/Nishfleet/fleet-ops/issues/$num"
  fi
  exit 0
fi
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"

issue_log="$scratch/issue-file.log"
issue_file="$scratch/issue-file"
cat >"$issue_file" <<'FAKE'
#!/usr/bin/env bash
printf 'fleet-issue-file file %s\n' "$*" >>"${ISSUE_FILE_LOG:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
exit 0
FAKE
chmod +x "$issue_file"
export FLEET_ISSUE_FILE="$issue_file"
export ISSUE_FILE_LOG="$issue_log"

prom="$scratch/detector.prom"
marker_dir="$scratch/canary-gh-failures"
mkdir -p "$marker_dir"

write_warns() {
    # $1 = count of escalation-canary WARN lines, $2 = opt credential WARNs.
    local escc="${1:-0}" credc="${2:-0}" i
    : >"$scratch/journal.out"
    for (( i=0; i<escc; i++ )); do
        printf '[2026-08-31T10:00:00Z] [fleet-escalation-canary] 9.  WARN: could not list open issues for dedupe (gh rc=1)\n' >>"$scratch/journal.out"
    done
    for (( i=0; i<credc; i++ )); do
        printf '[2026-08-31T10:00:00Z] [fleet-credential-expiry-canary] WARN: could not list open issues for dedupe/observe-to-close (gh rc=1)\n' >>"$scratch/journal.out"
    done
}

run_detector() {
    set +e
    env_out=$(
        FLEET_CANARY_GH_FAILURE_JOURNAL="cat $scratch/journal.out" \
        FLEET_CANARY_GH_FAILURE_MARKER_DIR="$marker_dir" \
        FLEET_CANARY_GH_FAILURE_PROM="$prom" \
        FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE="${FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE:-0}" \
        FLEET_CANARY_GH_FAILURE_SENTINEL="${FLEET_CANARY_GH_FAILURE_SENTINEL:-}" \
        "${bin}" ${DRY_RUN:-} 2>&1
    )
    env_rc=$?
    set -e
}

strip_journal_warns() {
    # Simulate journal rotation: the WARN lines aged out of the 1h window,
    # so a fresh scan sees nothing.
    : >"$scratch/journal.out"
}

# --- Scenario 1: WARN=0 -> no ticket, streak 0, exit 0 ----------------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
write_warns 0
run_detector
[[ "$env_rc" -eq 0 ]] || fail "scenario1: clean window must exit 0, got $env_rc ($env_out)"
if grep -q 'fleet-issue-file file' "$issue_log"; then
  fail "scenario1: must not file on the clean window ($issue_log)"
fi
grep -q 'fleet_canary_gh_failure_streak{canary="fleet-escalation-canary"} 0' "$prom" \
  || fail "scenario1: prom must expose streak 0: $(cat "$prom")"
grep -q 'fleet_canary_gh_failure_streak{canary="fleet-credential-expiry-canary"} 0' "$prom" \
  || fail "scenario1: prom must expose credential streak 0"
ok "scenario1: WARN=0 -> no ticket, streak 0, exit 0"

# --- Scenario 2: WARN=2 in 1h -> under threshold, no ticket ----------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
write_warns 2
run_detector
[[ "$env_rc" -eq 0 ]] || fail "scenario2: must exit 0, got $env_rc ($env_out)"
if grep -q 'fleet-issue-file file' "$issue_log"; then
  fail "scenario2: WARN=2 must not file (under threshold)"
fi
grep -q 'fleet_canary_gh_failure_streak{canary="fleet-escalation-canary"} 2' "$prom" \
  || fail "scenario2: prom must expose streak 2: $(cat "$prom")"
ok "scenario2: WARN=2 in 1h -> under threshold, no ticket, streak=2 metric"

# --- Scenario 3: WARN=3 in 1h -> ticket filed + metric streak 3 ------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
write_warns 3
run_detector
[[ "$env_rc" -eq 0 ]] || fail "scenario3: must exit 0, got $env_rc ($env_out)"
grep -q 'fleet-issue-file file' "$issue_log" \
  || fail "scenario3: must file a blind-spot ticket ($issue_log)"
grep -q 'signal: canary-gh-failure/fleet-escalation-canary' "$issue_log" \
  || fail "scenario3: filed ticket must carry the signal ($issue_log)"
grep -q 'fleet_canary_gh_failure_streak{canary="fleet-escalation-canary"} 3' "$prom" \
  || fail "scenario3: prom must expose streak 3"
ok "scenario3: WARN=3 in 1h -> ticket filed + metric streak=3"

# --- Scenario 4: WARN=3 on two consecutive ticks -> one deduped ticket -----
: >"$gh_log"; : >"$issue_log"; : >"$triage"
write_warns 3
run_detector
first_file_count=$(grep -c 'fleet-issue-file file' "$issue_log" || true)
[[ "$first_file_count" == "1" ]] || fail "scenario4: first tick must file exactly 1, got $first_file_count"
# The filed ticket is now OPEN on GitHub (real life): plant it in the stub
# open-issues ledger so the second tick's dedupe sees it.
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n '[{number: 7000, body: "blind spot\n\nsignal: canary-gh-failure/fleet-escalation-canary"}]' \
  >"$scratch/open.json"
# Second consecutive tick, WARN still 3.
write_warns 3
run_detector
total=$(grep -c 'fleet-issue-file file' "$issue_log" || true)
[[ "$total" == "1" ]] || fail "scenario4: second tick must be deduped (total=$total)"
grep -q 'already has an open blind-spot ticket' <<<"$env_out" \
  || fail "scenario4: detector must log the dedupe (out=$env_out)"
grep -q 'signal: canary-gh-failure/fleet-escalation-canary' "$issue_log" \
  || fail "scenario4: ticket signal must be canary-gh-failure/<canary>"
grep -q 'canary-blind-spot' "$issue_log" || fail "scenario4: ticket title must name the blind spot ($issue_log)"
ok "scenario4: WARN=3 two ticks -> one ticket, signal: canary-gh-failure/<canary>, deduped"

# --- Scenario 5: streak cleared -> observe-to-close (comment + close) ------
# The ticket from scenario 3/4 is "open" in the stub open-issues ledger.
: >"$gh_log"; : >"$issue_log"; : >"$triage"
open_json="$scratch/open.json"
closed_json="$scratch/closed.log"
export GH_OPEN_ISSUES="$open_json"
export GH_CLOSED_ISSUES="$closed_json"
jq -n '[{number: 4242, body: "blind spot\n\nsignal: canary-gh-failure/fleet-escalation-canary"}]' \
  >"$open_json"
: >"$closed_json"
write_warns 0
sentinel="$scratch/sentinel"
: >"$sentinel"
export FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE=1
export FLEET_CANARY_GH_FAILURE_SENTINEL="$sentinel"
run_detector
[[ "$env_rc" -eq 0 ]] || fail "scenario5: clean tick must exit 0, got $env_rc ($env_out)"
grep -q '^4242$' "$closed_json" \
  || fail "scenario5: must close #4242 (closed=$(cat "$closed_json"))"
grep -q 'issue close 4242' "$gh_log" \
  || fail "scenario5: gh must receive the close"
grep -q 'canary-recovered' "$gh_log" \
  || fail "scenario5: close must carry the canary-recovered comment"
ok "scenario5: streak cleared -> observe-to-close comments + closes the ticket"
unset FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE FLEET_CANARY_GH_FAILURE_SENTINEL

# --- Scenario 6: under-threshold WARN keeps the ticket open ----------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
jq -n '[{number: 4243, body: "blind spot\n\nsignal: canary-gh-failure/fleet-escalation-canary"}]' \
  >"$open_json"
: >"$closed_json"
write_warns 2
: >"$scratch/sentinel2"
export FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE=1
export FLEET_CANARY_GH_FAILURE_SENTINEL="$scratch/sentinel2"
run_detector
[[ "$env_rc" -eq 0 ]] || fail "scenario6: must exit 0, got $env_rc ($env_out)"
if [[ -s "$closed_json" ]]; then
  fail "scenario6: under-threshold WARN must NOT close the ticket (closed=$(cat "$closed_json"))"
fi
grep -q 'WAIT' <<<"$env_out" \
  || fail "scenario6: detector must log the WAIT action (out=$env_out)"
ok "scenario6: WARN=2 keeps the ticket open (streak not fully clear)"
unset FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE FLEET_CANARY_GH_FAILURE_SENTINEL

# --- Scenario 7: journal rotated, markers carry the streak -----------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
# Fresh open-ledger: any prior planted tickets must not dedupe this detection.
unset GH_OPEN_ISSUES
strip_journal_warns
# Markers written by the canaries at WARN time (epoch timestamps now).
printf '%s %s\n' "$(date +%s)" "fleet-escalation-canary" >"$marker_dir/fleet-escalation-canary.marker"
printf '%s %s\n' "$(date +%s)" "fleet-escalation-canary" >>"$marker_dir/fleet-escalation-canary.marker"
printf '%s %s\n' "$(date +%s)" "fleet-escalation-canary" >>"$marker_dir/fleet-escalation-canary.marker"
run_detector
grep -q 'fleet-issue-file file' "$issue_log" \
  || fail "scenario7: marker fallback must file a blind-spot ticket"
grep -q 'signal: canary-gh-failure/fleet-escalation-canary' "$issue_log" \
  || fail "scenario7: marker-filed ticket must carry the signal"
grep -q 'fleet_canary_gh_failure_streak{canary="fleet-escalation-canary"} 3' "$prom" \
  || fail "scenario7: prom must expose the marker-derived streak 3"
ok "scenario7: journal rotated -> marker fallback still triggers detection"
rm -f "$marker_dir/fleet-escalation-canary.marker"

# --- Scenario 8: the two coverage canaries write/clear the markers ---------
grep -q 'mark_gh_failure' "$esc_canary" || fail "scenario8: escalation canary must mark gh failures"
grep -q 'clear_gh_failure' "$esc_canary" || fail "scenario8: escalation canary must clear on a clean tick"
grep -q 'mark_gh_failure' "$cred_canary" || fail "scenario8: credential canary must mark gh failures"
grep -q 'clear_gh_failure' "$cred_canary" || fail "scenario8: credential canary must clear on a clean tick"
grep -q 'canary-gh-failures' "$esc_canary" || fail "scenario8: escalation canary marker dir must exist"
grep -q 'canary-gh-failures' "$cred_canary" || fail "scenario8: credential canary marker dir must exist"
ok "scenario8: both coverage canaries write + clear the data-plane markers"

# --- Scenario 9: tier1 wiring + MANIFEST -----------------------------------
grep -q 'fleet-canary-gh-failure-detector' "$tier1" \
  || fail "scenario9: tier1 must invoke fleet-canary-gh-failure-detector"
grep -q 'CANARY_GH_FAILURE' "$tier1" \
  || fail "scenario9: tier1 must set the detector env"
grep -q 'FLEET_CANARY_GH_FAILURE_OK_TO_CLOSE=1' "$tier1" \
  || fail "scenario9: tier1 must opt in to observe-to-close per call"
grep -q 'FLEET_CANARY_GH_FAILURE_SENTINEL' "$tier1" \
  || fail "scenario9: tier1 must pass the close sentinel per call"
grep -q 'bin/fleet-canary-gh-failure-detector' "$manifest" \
  || fail "scenario9: MANIFEST must install the detector"
ok "scenario9: tier1 wires the detector with opt-in close + sentinel; MANIFEST installs it"

# --- Scenario 10: rule-enforcement matrix row ------------------------------
jq -e '.rules[] | select(.id == "led-escalation-coverage" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "scenario10: matrix must mark led-escalation-coverage enforced"
jq -e '.rules[] | select(.id == "led-escalation-coverage") | .mechanism | test("fleet-canary-gh-failure-detector|canary-gh-failure")' \
  "$matrix" >/dev/null \
  || fail "scenario10: matrix mechanism must name the detector"
jq -e '.rules[] | select(.id == "led-escalation-coverage") | .proof | test("fleet-canary-gh-failure-detector.test.sh")' \
  "$matrix" >/dev/null \
  || fail "scenario10: matrix proof must name the regression drill"
ok "scenario10: rule-enforcement matrix row covers the data-plane failure watch"

# --- Scenario 11: dry-run asserts would_file without filing ---------------
: >"$gh_log"; : >"$issue_log"; : >"$triage"
write_warns 3
DRY_RUN=--dry-run run_detector
grep -q 'would_file=1 signal=canary-gh-failure/fleet-escalation-canary' <<<"$env_out" \
  || fail "scenario11: dry-run must report would_file=1 with the signal (out=$env_out)"
if grep -q 'fleet-issue-file file' "$issue_log"; then
  fail "scenario11: dry-run must not file"
fi
ok "scenario11: --dry-run reports would_file=1 signal=canary-gh-failure/<canary>"

# --- Scenario 12: the default journal command evals --since as one token -----
# Regression (live 2026-08-31): the default JOURNAL_CMD lost the quotes around
# `1 hour ago`, so eval ran `journalctl --since 1 hour ago` as broken separate
# args (rc=1, empty) and the detector silently reported warn_count=0 from a
# journal that actually had WARNs. Guard it: eval the default command through a
# fake journalctl and assert --since gets a single `1 hour ago` token.
default_cmd=$(sed -n 's/^JOURNAL_CMD=.*:-\(journalctl[^}]*\)}.*/\1/p' "$bin")
[[ -n "$default_cmd" ]] || fail "scenario12: could not extract default journal command from $bin"
jtbin="$scratch/jtbin"
jtlog="$scratch/jt.log"
mkdir -p "$jtbin"
cat >"$jtbin/journalctl" <<FAKE_J
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$jtlog"
exit 0
FAKE_J
chmod +x "$jtbin/journalctl"
: >"$jtlog"
bash -c "PATH=\"$jtbin:\$PATH\"; eval \"$default_cmd\"" >/dev/null 2>&1
args=$(cat "$jtlog")
if ! grep -q -- '--since' <<<"$args"; then
  fail "scenario12: default journal command must include --since (got: $args)"
fi
if ! grep -q -- '--since 1 hour ago' <<<"$args"; then
  fail "scenario12: default journal command must pass --since \"1 hour ago\" as one token (got: $args)"
fi
ok "scenario12: default journal command evals --since \"1 hour ago\" as a single token"

echo "OK: fleet-canary-gh-failure-detector (fleet-ops#2538) — 12 scenarios green"