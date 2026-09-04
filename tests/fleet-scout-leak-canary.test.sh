#!/usr/bin/env bash
# tests/fleet-scout-leak-canary.test.sh
#
# Proves the scout leak canary (fleet-ops#3123) offline:
#   1. .prom missing -> exit 1 (watcher broken), LOUD.
#   2. .prom unparseable (missing gauge) -> exit 1 (watcher broken).
#   3. Clean tick (ratio >= 0.1) -> exit 0, no filing, no closing.
#   4. Fire met but no dominant intra-pipeline leak -> exit 0, NO-DOMINANT
#      LOUD, no phantom filing.
#   5. Fire met + dominant leak -> exit 0, files `fix(scout-leak):` ticket
#      for the stage with the stage marker + evidence body.
#   6. Data-not-ready (pre-#3123 exporter, no claimed line) -> exit 0,
#      LOUD DATA-NOT-READY, no filing.
#   7. Dedup: second tick with same dominant stage + open ticket -> no
#      second filing.
#   8. Observe-to-close on alert resolution: ratio >= 0.1 closes any open
#      canary-filed ticket with a resolved-at note.
#   9. Observe-to-close on drained stage: fire still met but a ticket's
#      stage leak hit 0 -> that ticket closes; the new dominant stage
#      files fresh.
#  10. Dominant flip keeps a non-dominant stage's ticket while its leak
#      is still > 0 (separate mechanism tickets).
#  11. Heartbeat-tier1 wires the canary + MANIFEST installs it +
#      ci-standards-audit hosts this test.
#  12. The live /var/lib/prometheus/node-exporter
#      fleet-scout-effectiveness.prom (present on netcup-rs2000) parses
#      under the canary's metric reader (regression check).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-scout-leak-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"
host_audit="$repo_root/tests/ci-standards-audit.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$manifest" ]] || fail "missing: $manifest"
[[ -f "$host_audit" ]] || fail "missing: $host_audit"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t scout-leak-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"

export HOME="$scratch/home"
mkdir -p "$HOME"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_SCOUT_LEAK_REPO="Nishfleet/fleet-ops"
export FLEET_SCOUT_LEAK_FILE=1
export FLEET_OPS_REPO="$repo_root"

# Stub gh to log calls and return canned JSON for issue list / close.
gh_log="$scratch/gh.log"
gh_close_log="$scratch/gh.close.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue close"*)
    printf '%s\n' "$*" >>"${GH_CLOSE_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export GH_CLOSE_LOG="$gh_close_log"
export PATH="$scratch:$PATH"

# Stub fleet-issue-file to log create calls so we can assert title/body.
issue_file_log="$scratch/issue-file.log"
issue_file="$scratch/fleet-issue-file"
cat >"$issue_file" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "ARGS=$*" >>"${ISSUE_FILE_LOG:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/999"
exit 0
FAKE
chmod +x "$issue_file"
export FLEET_ISSUE_FILE="$issue_file"
export ISSUE_FILE_LOG="$issue_file_log"

# open_issue num marker — GH_OPEN_ISSUES fixture with one issue whose body
# carries the canary marker (or a plain body when marker empty).
open_issue() {
    local num="$1" marker="$2"
    if [[ -n "$marker" ]]; then
        printf '[{"number": %s, "body": "some body\\n%s %s\\n"}]' \
            "$num" "fleet-scout-leak-canary:" "$marker"
    else
        printf '[{"number": %s, "body": "unrelated"}]' "$num"
    fi
}

# prom fixture writer: args runs filed survive ready claimed merged ratio.
write_prom() {
    local runs="$1" filed="$2" survive="$3" ready="$4" claimed="$5" merged="$6" ratio="$7"
    cat >"$scratch/eff.prom" <<PROM
# HELP fleet_scout_runs_total ...
# TYPE fleet_scout_runs_total gauge
fleet_scout_runs_total{repo="0509"} $runs
# HELP fleet_scout_issues_filed ...
# TYPE fleet_scout_issues_filed gauge
fleet_scout_issues_filed{repo="0509"} $filed
# HELP fleet_scout_issues_survive_intake ...
# TYPE fleet_scout_issues_survive_intake gauge
fleet_scout_issues_survive_intake{repo="0509"} $survive
# HELP fleet_scout_issues_agent_ready ...
# TYPE fleet_scout_issues_agent_ready gauge
fleet_scout_issues_agent_ready{repo="0509"} $ready
# HELP fleet_scout_issues_claimed ...
# TYPE fleet_scout_issues_claimed gauge
fleet_scout_issues_claimed{repo="0509"} $claimed
# HELP fleet_scout_issues_merged_14d ...
# TYPE fleet_scout_issues_merged_14d gauge
fleet_scout_issues_merged_14d{repo="0509"} $merged
# HELP fleet_scout_effectiveness_ratio ...
# TYPE fleet_scout_effectiveness_ratio gauge
fleet_scout_effectiveness_ratio{repo="0509"} $ratio
# HELP fleet_scout_effectiveness_last_run_seconds ...
# TYPE fleet_scout_effectiveness_last_run_seconds gauge
fleet_scout_effectiveness_last_run_seconds 1788350400
PROM
    export FLEET_SCOUT_LEAK_PROM="$scratch/eff.prom"
}

run_canary() {
    local rc2
    set +e
    "$bin" 2>&1
    rc2=$?
    set -e
    echo "RC=$rc2"
}

# =========================================================================
# 1. .prom missing -> exit 1 (watcher broken)
# =========================================================================
export FLEET_SCOUT_LEAK_PROM="$scratch/nope.prom"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "1" ]] || fail "scenario 1: missing .prom should exit 1, got $rc"
printf '%s\n' "$out" | grep -q 'SCOUT-LEAK-WATCHER-BROKEN' \
  || fail "scenario 1: must LOUD WATCHER-BROKEN"
ok "scenario 1: .prom missing -> exit 1 + LOUD"

# =========================================================================
# 2. .prom unparseable (missing gauge) -> exit 1
# =========================================================================
printf 'junk\n' >"$scratch/eff.prom"
export FLEET_SCOUT_LEAK_PROM="$scratch/eff.prom"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "1" ]] || fail "scenario 2: unparseable .prom should exit 1, got $rc"
printf '%s\n' "$out" | grep -q 'SCOUT-LEAK-WATCHER-BROKEN' \
  || fail "scenario 2: must LOUD WATCHER-BROKEN"
ok "scenario 2: unparseable .prom -> exit 1 + LOUD"

# =========================================================================
# 3. Clean tick (ratio >= 0.1) -> exit 0, no filing, no closing
# =========================================================================
write_prom 20 10 10 10 10 10 0.500000
rm -f "$issue_file_log" "$gh_close_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 3: clean tick should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'no ScoutEffectivenessLow' \
  || fail "scenario 3: clean tick must say no ScoutEffectivenessLow: $out"
[[ ! -s "$issue_file_log" ]] || fail "scenario 3: clean tick must not file: $(cat "$issue_file_log")"
[[ ! -s "$gh_close_log" ]] || fail "scenario 3: clean tick must not close: $(cat "$gh_close_log")"
ok "scenario 3: clean tick -> exit 0, no file, no close"

# =========================================================================
# 4. Fire met but no dominant intra-pipeline leak -> exit 0, NO-DOMINANT
# =========================================================================
write_prom 1000 10 10 10 10 10 0.010000
: >"$triage"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 4: no-dominant should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'SCOUT-LEAK-NO-DOMINANT' \
  || fail "scenario 4: must LOUD NO-DOMINANT"
[[ ! -s "$issue_file_log" ]] || fail "scenario 4: must not file a phantom ticket"
ok "scenario 4: fire met + no dominant leak -> NO-DOMINANT, no phantom filing"

# =========================================================================
# 5. Fire met + dominant leak (live shape) -> files targeted ticket
# =========================================================================
write_prom 220 117 117 1 1 6 0.027273
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 5: dominant leak should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'dominant=never-ready(116)' \
  || fail "scenario 5: must isolate never-ready 116: $out"
[[ -s "$issue_file_log" ]] || fail "scenario 5: must file a ticket"
grep -q 'fix(scout-leak): scout leak: filed issues never reach agent-ready (survived=117 agent_ready=1)' "$issue_file_log" \
  || fail "scenario 5: title must name the stage + evidence: $(cat "$issue_file_log")"
grep -q 'fleet-scout-leak-canary: never-ready' "$issue_file_log" \
  || fail "scenario 5: body must carry the stage marker"
grep -q 'Mechanism hypothesis' "$issue_file_log" \
  || fail "scenario 5: body must carry the mechanism hypothesis"
grep -q 'run-proof: canary tick' "$issue_file_log" \
  || fail "scenario 5: body must carry run-proof"
ok "scenario 5: live shape -> isolate never-ready(116), file targeted ticket"

# =========================================================================
# 6. Data-not-ready (pre-#3123 exporter: no claimed line) -> exit 0
# =========================================================================
write_prom 220 117 117 1 1 6 0.027273
grep -v '^fleet_scout_issues_claimed' "$scratch/eff.prom" >"$scratch/old.prom"
export FLEET_SCOUT_LEAK_PROM="$scratch/old.prom"
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 6: data-not-ready should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'SCOUT-LEAK-DATA-NOT-READY' \
  || fail "scenario 6: must LOUD DATA-NOT-READY"
[[ ! -s "$issue_file_log" ]] || fail "scenario 6: must not file without claimed data"
ok "scenario 6: missing claimed gauge -> DATA-NOT-READY, no filing"

# =========================================================================
# 7. Dedup: second tick with same dominant stage + open ticket
# =========================================================================
write_prom 220 117 117 1 1 6 0.027273
export GH_OPEN_ISSUES="$scratch/open.json"
open_issue 4242 never-ready >"$GH_OPEN_ISSUES"
rm -f "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 7: dedup should exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'dedup: open Nishfleet/fleet-ops#4242 already carries marker for never-ready' \
  || fail "scenario 7: must dedup against open ticket: $out"
[[ ! -s "$issue_file_log" ]] || fail "scenario 7: must not file a duplicate"
ok "scenario 7: open ticket for the stage -> dedup, no second filing"

# =========================================================================
# 8. Observe-to-close on alert resolution (ratio >= 0.1)
# =========================================================================
write_prom 20 10 10 10 10 10 0.500000
open_issue 4321 never-ready >"$GH_OPEN_ISSUES"
rm -f "$gh_close_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 8: resolved tick should exit 0, got $rc"
[[ -s "$gh_close_log" ]] || fail "scenario 8: must close the open ticket"
grep -q 'issue close 4321' "$gh_close_log" || fail "scenario 8: must close #4321: $(cat "$gh_close_log")"
grep -q 'ScoutEffectivenessLow resolved' "$gh_close_log" || fail "scenario 8: close comment must say resolved"
ok "scenario 8: alert resolved -> observe-to-close with resolved note"

# =========================================================================
# 9. Observe-to-close on drained stage; new dominant files fresh
# =========================================================================
# never-ready=0 (survive==ready), unmerged=6 dominant (claimed=8, merged=2).
write_prom 100 10 10 10 8 2 0.020000
open_issue 4343 never-ready >"$GH_OPEN_ISSUES"
rm -f "$gh_close_log" "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 9: drained-stage tick should exit 0, got $rc"
grep -q 'issue close 4343' "$gh_close_log" || fail "scenario 9: drained never-ready ticket must close: $(cat "$gh_close_log")"
grep -q 'drained to 0' "$gh_close_log" || fail "scenario 9: close comment must say drained"
grep -q 'fleet-scout-leak-canary: unmerged' "$issue_file_log" \
  || fail "scenario 9: dominant unmerged must file fresh: $(cat "$issue_file_log")"
ok "scenario 9: drained stage close + fresh dominant ticket"

# =========================================================================
# 10. Dominant flip keeps a non-dominant stage ticket while leak > 0
# =========================================================================
# never-ready=2 (survive=12, ready=10), unmerged=6 dominant (claimed=8, merged=2).
write_prom 100 12 12 10 8 2 0.020000
open_issue 4344 never-ready >"$GH_OPEN_ISSUES"
rm -f "$gh_close_log" "$issue_file_log"
out=$(run_canary)
rc=$(printf '%s\n' "$out" | grep -o 'RC=.*' | tr -d 'RC=')
[[ "$rc" == "0" ]] || fail "scenario 10: flip tick should exit 0, got $rc"
[[ ! -s "$gh_close_log" ]] || fail "scenario 10: never-ready leak still > 0, must NOT close: $(cat "$gh_close_log")"
grep -q 'fleet-scout-leak-canary: unmerged' "$issue_file_log" \
  || fail "scenario 10: dominant unmerged must file fresh"
ok "scenario 10: non-dominant ticket with live leak stays open; dominant files"

# =========================================================================
# 11. Wiring: heartbeat-tier1 block 45 + MANIFEST + ci-standards-audit
# =========================================================================
grep -q 'SCOUT_LEAK_CANARY_BIN' "$tier1" || fail "scenario 11: tier-1 must wire the canary"
grep -q 'fleet-scout-leak-canary' "$tier1" || fail "scenario 11: tier-1 must name the canary"
grep -q '^bin/fleet-scout-leak-canary' "$manifest" || fail "scenario 11: MANIFEST must install the canary"
grep -q 'bash "$here/fleet-scout-leak-canary.test.sh"' "$host_audit" \
  || fail "scenario 11: ci-standards-audit must host the test"
ok "scenario 11: tier-1 + MANIFEST + audit host wiring"

# =========================================================================
# 12. Live .prom parses under the canary's metric reader (if present)
# =========================================================================
live=/var/lib/prometheus/node-exporter/fleet-scout-effectiveness.prom
if [[ -f "$live" ]]; then
    parse_metric() {
        local name="$1"
        grep -v '^#' "$live" 2>/dev/null \
            | grep -F "$name{repo=\"0509\"}" \
            | head -n 1 \
            | awk '{print $NF}' \
            || true
    }
    for m in fleet_scout_runs_total fleet_scout_issues_filed \
             fleet_scout_issues_survive_intake fleet_scout_issues_agent_ready \
             fleet_scout_issues_merged_14d fleet_scout_effectiveness_ratio; do
        v=$(parse_metric "$m")
        [[ -n "$v" ]] || fail "scenario 12: live metric $m unparseable"
    done
    ok "scenario 12: live .prom metrics all parse"
else
    echo "SKIP: scenario 12 — live .prom not present"
fi

echo "OK: fleet-scout-leak-canary — 12 scenarios"