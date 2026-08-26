#!/usr/bin/env bash
# tests/fleet-blind-audit.test.sh
#
# Proves the mechanical blind audit:
#   - builds a packet from prompts/blind-audit.md
#   - dispatches a pi reviewer
#   - runs findings through the panel
#   - files gap-audit issues (up to the cap)
#   - writes a durable report and verdict log
#   - skips duplicates and active deliberate states
#   - treats expired deliberate states as loud findings
#   - stamps the plan file
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-blind-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch=$(mktemp -d -t fleet-blind-audit.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Custom deliberate-states: one active, one expired (for the loud finding).
cat > "$scratch/deliberate-states.md" <<'EOF'
# Deliberate-states registry

| state | reason | expiry | owner |
|---|---|---|---|
| active-pause | Fleet tuning pause. | 2026-09-02 | Nish |
| expired-pause | Old pause that should have been cleared. | 2026-08-20 | Nish |
EOF

# Fake pi: writes a findings file and a report file using the paths in the packet.
mkdir -p "$scratch/fakebin"
cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
packet=$(cat)
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | head -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | head -1)
mkdir -p "$(dirname "$findings_json")"
cat > "$findings_json" <<'JSON'
{
  "findings": [
    {"rank": 1, "title": "orphan systemd unit pi-issue@fleet-ops-99 is failed", "body": "A worker unit is failed with no live process.", "severity": "high", "evidence": "systemctl --user list-units --state=failed"},
    {"rank": 2, "title": "stale agent-state file", "body": "Duplicate of the open gap-audit issue.", "severity": "high", "evidence": "find /home/nish/workspaces/agent-state -mtime +1"},
    {"rank": 3, "title": "expired-pause deliberate state expired", "body": "The expired-pause entry in deliberate-states.md has expired and was not cleared.", "severity": "critical", "evidence": "docs/deliberate-states.md"}
  ]
}
JSON
cat > "$report_md" <<'MD'
# Test blind audit report
Report body.
MD
printf '%s\n' 'pi fake done'
FAKE_PI
chmod +x "$scratch/fakebin/pi"

# Fake gh: issue list returns pre-populated open issues so duplicate detection runs.
cat > "$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true

case "$subcmd" in
  label)
    if [ "${1:-}" = "view" ]; then
      exit 1
    fi
    exit 0
    ;;
  issue)
    case "${1:-}" in
      list)
        printf '%s\n' '[{"number":77,"title":"stale agent-state file","labels":[]}]'
        ;;
      create)
        printf 'CREATE %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
    esac
    exit 0
    ;;
  pr)
    if [ "${1:-}" = "list" ]; then
      printf '%s\n' '[]'
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

# Fake seat-lib: the real lib/seat-lib.sh reads ~/.pi/agent/models.json and
# ~/.local/state/pi-packet/seat-caps.json to pick a seat. Those exist on
# Nish's VPS (so the test passed locally) but NOT on a GitHub Actions hosted
# runner, where pick_seat returned empty and the bin exited 1 at the
# "no capable seat" guard — the fleet-ops#304 failure. Seat selection itself
# is covered by seat-lib.test.sh; this test owns the audit harness mechanics
# (panel, filing, dedupe, deliberate-state loud, stamp), so pick_seat is
# stubbed to a deterministic seat, matching the fake-pi/fake-gh pattern.
cat > "$scratch/seat-lib-fake.sh" <<'FAKE_SEAT_LIB'
# shellcheck shell=bash
pick_seat() {
    # Args: fail_p fail_m need_capable tried_file — all ignored for the stub.
    printf 'fakeprovider\tfakemodel'
}
FAKE_SEAT_LIB

plan="$scratch/plan.md"
cat > "$plan" <<'EOF'
last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)
EOF

mkdir -p "$scratch/state"
: > "$scratch/gh-create.log"

# Capture the binary's exit code without tripping set -e so the fail block
# below actually prints. Under set -e a failing bin would exit the test
# script silently before rc=$? runs (the fleet-ops#280 "no FAIL line" symptom).
rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$scratch/gh-create.log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$scratch/state" \
  AUDIT_PROMPT="$repo_root/prompts/blind-audit.md" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_SEAT_LIB="$scratch/seat-lib-fake.sh" \
  AUDIT_PLAN_FILE="$plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:20:00Z" \
  AUDIT_PI_BIN="$scratch/fakebin/pi" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/run.log" 2>&1 || rc=$?

[[ $rc == 0 ]] || { cat "$scratch/run.log"; fail "fleet-blind-audit exited $rc"; }

# Find the one report directory.
report_dir=$(find "$scratch/state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "$report_dir" ]] || fail "no report directory created"

# The panel should have logged verdicts for all three findings.
verdicts="$report_dir/verdicts.jsonl"
[[ -f "$verdicts" ]] || fail "verdicts log missing"

pass_count=$(jq -R -c 'fromjson | select(.verdict=="PASS")' "$verdicts" | wc -l)
fail_count=$(jq -R -c 'fromjson | select(.verdict=="FAIL")' "$verdicts" | wc -l)

[[ "$pass_count" == "2" ]] || fail "expected 2 PASS verdicts, got $pass_count"
[[ "$fail_count" == "1" ]] || fail "expected 1 FAIL verdict (duplicate), got $fail_count"

# The duplicate finding should be FAIL for the right reason.
[[ -n $(jq -R -c 'fromjson | select(.rank=="2" and .verdict=="FAIL")' "$verdicts") ]] || fail "rank 2 finding was not rejected as duplicate"

# The expired deliberate state should be a PASS (loud) finding.
[[ -n $(jq -R -c 'fromjson | select(.rank=="3" and .verdict=="PASS" and (.reason | contains("expired")))' "$verdicts") ]] || fail "rank 3 expired deliberate state was not accepted as loud finding"

# The two accepted findings should have been filed.
filed=$(grep -c 'FILED' "$scratch/run.log")
[[ "$filed" == "2" ]] || fail "expected 2 filed issues, saw $filed"

# Plan file should show the run stamp.
grep -qE '^last-blind-audit-run:' "$plan" || fail "plan file missing last-blind-audit-run stamp"

# Durable report and findings must exist.
[[ -f "$report_dir/report.md" ]] || fail "report.md missing"
[[ -f "$report_dir/findings.json" ]] || fail "findings.json missing"

# Step 6 must write the filed URL into the durable report AND the verdict log.
# The 2026-08-26 live run filed #367-#371 but left report.md saying "no GitHub
# issues filed" (the reviewer is forbidden from filing). That is the bug.
grep -F '## Filing results' "$report_dir/report.md" >/dev/null \
  || fail "report.md missing Filing results section"
grep -F 'https://github.com/Nishfleet/fleet-ops/issues/9999' "$report_dir/report.md" >/dev/null \
  || fail "report.md does not link the filed issue"
[[ -n $(jq -R -c 'fromjson | select(.rank=="1" and .issue=="https://github.com/Nishfleet/fleet-ops/issues/9999")' "$verdicts") ]] \
  || fail "verdicts.jsonl rank 1 missing issue URL"

# gh issue create must use --body-file (not --body) and the gap-audit label.
grep -E 'CREATE .*--body-file ' "$scratch/gh-create.log" >/dev/null \
  || fail "gh issue create was not invoked with --body-file: $(cat "$scratch/gh-create.log")"
grep -E 'CREATE .*--label gap-audit' "$scratch/gh-create.log" >/dev/null \
  || fail "gh issue create missing --label gap-audit: $(cat "$scratch/gh-create.log")"

ok "fleet-blind-audit: panel, filing, dedupe, deliberate-state loud, stamp, report ledger"

# ============================================================================
# Drill: fixture finding, no pi/seat. Proves step 6 files an issue.
# ============================================================================
drill_state="$scratch/drill-state"
drill_plan="$scratch/drill-plan.md"
drill_log="$scratch/drill-create.log"
mkdir -p "$drill_state"
: > "$drill_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$drill_plan"

# Capture the drill's exit code without tripping set -e.
drill_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$drill_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$drill_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$drill_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:21:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/drill.log" 2>&1 || drill_rc=$?
[[ $drill_rc == 0 ]] || { cat "$scratch/drill.log"; fail "drill exited $drill_rc"; }

drill_dir=$(find "$drill_state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "$drill_dir" ]] || fail "drill produced no report directory"
grep -c 'FILED' "$scratch/drill.log" | grep -qx 1 \
  || fail "drill did not file exactly one issue: $(cat "$scratch/drill.log")"
grep -F 'https://github.com/Nishfleet/fleet-ops/issues/9999' "$drill_dir/report.md" >/dev/null \
  || fail "drill report.md does not link the filed issue"
[[ -n $(jq -R -c 'fromjson | select(.verdict=="PASS" and (.issue|test("issues/9999")))' "$drill_dir/verdicts.jsonl") ]] \
  || fail "drill verdicts.jsonl missing filed issue URL"
grep -E 'CREATE .*--body-file ' "$drill_log" >/dev/null \
  || fail "drill gh create missing --body-file"
ok "drill: fixture finding filed as gap-audit issue with report linked"

# ============================================================================
# Fail-loud: PASS finding + gh create failure must exit 1 (not silent success).
# ============================================================================
fail_gh="$scratch/failgh"
mkdir -p "$fail_gh"
cat > "$fail_gh/gh" <<'FAIL_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true
case "$subcmd" in
  label) exit 0 ;;
  issue)
    case "${1:-}" in
      list) printf '%s\n' '[]' ;;
      create) echo "HTTP 401: requires authentication" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  pr) printf '%s\n' '[]'; exit 0 ;;
  *) exit 0 ;;
esac
FAIL_GH
chmod +x "$fail_gh/gh"

fail_state="$scratch/fail-state"
fail_plan="$scratch/fail-plan.md"
mkdir -p "$fail_state"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$fail_plan"

# Capture the fail-loud run's exit code without tripping set -e.
fail_rc=0
PATH="$fail_gh:$scratch/fakebin:$PATH" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$fail_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$fail_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:22:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/fail.log" 2>&1 || fail_rc=$?
[[ $fail_rc == 1 ]] || { cat "$scratch/fail.log"; fail "expected exit 1 when gh create fails, got $fail_rc"; }
grep -F 'FATAL:' "$scratch/fail.log" >/dev/null \
  || fail "fail-loud run did not log FATAL"
fail_dir=$(find "$fail_state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
grep -F 'Unfiled PASS findings: 1' "$fail_dir/report.md" >/dev/null \
  || fail "fail-loud report.md did not record unfiled PASS"

ok "fail-loud: unfiled PASS finding exits 1 and is recorded in the report"

