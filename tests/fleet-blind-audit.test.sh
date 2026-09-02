#!/usr/bin/env bash
# tests/fleet-blind-audit.test.sh
#
# Proves the mechanical blind audit:
#   - builds a packet from prompts/blind-audit.md
#   - dispatches a pi reviewer
#   - runs findings through the panel
#   - files gap-audit + agent-ready issues (up to the cap; fleet-ops#402)
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

# fleet-ops#367: the live auditor must inspect the deploy-clone. The
# products/fleet-ops default is the worktree parent; auditing it files
# 48 false MANIFEST DIFFs (the 2026-08-26T15:11Z run that opened #367).
grep -q 'AUDIT_REPO_ROOT=/home/nish/workspaces/tooling/fleet-ops-deploy-clone' \
    "$repo_root/systemd/fleet-blind-audit.service" \
    || fail "fleet-blind-audit.service must pin AUDIT_REPO_ROOT to the canonical deploy-clone"
if grep -Eq 'REPO_ROOT="\$\{AUDIT_REPO_ROOT:-/home/nish/workspaces/products/fleet-ops\}"' "$bin"; then
    fail "fleet-blind-audit default AUDIT_REPO_ROOT is still the worktree parent"
fi
grep -q 'AUDIT-NONCANONICAL' "$bin" \
    || fail "fleet-blind-audit must log AUDIT-NONCANONICAL when pointed at the worktree parent"
grep -q 'audit-target-noncanonical: fleet-ops#367' "$bin" \
    || fail "fleet-blind-audit must auto-file with the #367 marker"
grep -q 'fleet-ops-deploy-clone' "$repo_root/prompts/blind-audit.md" \
    || fail "blind-audit prompt must name the canonical deploy-clone so reviewers do not re-file #367"
# fleet-ops#619: P14 is an explicit list plus hosted tests. A grep of
# ci.yml alone re-files hosted tests (the auditor panel test) as missing.
grep -q 'p14-test-listing-gate.test.sh' "$repo_root/prompts/blind-audit.md" \
    || fail "blind-audit prompt must name p14-test-listing-gate.test.sh so reviewers do not re-file hosted tests as missing from P14 (fleet-ops#619)"
grep -q 'Do not file "test is not in the CI P14 list"' "$repo_root/prompts/blind-audit.md" \
    || fail "blind-audit prompt must forbid filing 'not in the CI P14 list' from a workflows grep alone (fleet-ops#619)"
# fleet-ops#402: panel-PASS findings must be filed with agent-ready or
# intake/pi-issue never see them. This grep is the class guard — a create
# that only stamps gap-audit is a failed run.
grep -E '"\$ISSUE_FILE" file .*--label agent-ready' "$bin" \
    || fail "fleet-blind-audit must file panel-PASS findings with --label agent-ready (fleet-ops#402)"

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
# fleet-ops#786: the assembler no longer in-place substitutes {{...}} placeholders
# in the prompt; the resolved values live in the trailing "Volatile values"
# section. The prompt body still has a schema line with the literal
# `{{FINDINGS_JSON}}` / `{{REPORT_MD}}` placeholders, so the test must pick
# the LAST matching "Where to save ..." line (the volatile value) rather
# than the FIRST (the literal placeholder).
mkdir -p "$scratch/fakebin"
cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
packet=$(cat)
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | tail -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | tail -1)
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

# fleet-ops#377: stub the recurrence and machinery-authorization gates so the
# harness does not pull live systemd state from the host. Those hunts are
# covered by their own tests; this test owns the audit harness mechanics.
cat > "$scratch/noop-gate.py" <<'NOOP_GATE'
#!/usr/bin/env python3
import sys
sys.stdin.read()
print('{"findings":[]}')
NOOP_GATE
chmod +x "$scratch/noop-gate.py"

plan="$scratch/plan.md"
cat > "$plan" <<'EOF'
last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)
EOF

mkdir -p "$scratch/state"
: > "$scratch/gh-create.log"
# fleet-ops#377: feed an empty seam-evidence fixture so the harness does not
# touch live memoryctl/actions-log sources, and prove the seam table still
# appears in the report with no seams in the window.
printf '%s\n' '{"candidates":[]}' >"$scratch/empty-seams.json"

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
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  AUDIT_MECHANISM_GATE="$scratch/noop-gate.py" \
  AUDIT_MACHINERY_GATE="$scratch/noop-gate.py" \
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
# fleet-ops#377: the harness writes the Manual-seam lens table into the
# report even when the window has no seams.
grep -q '## Manual-seam lens' "$report_dir/report.md" \
  || fail "report.md must contain the Manual-seam lens table even with no seams"

# Step 6 must write the filed URL into the durable report AND the verdict log.
# The 2026-08-26 live run filed #367-#371 but left report.md saying "no GitHub
# issues filed" (the reviewer is forbidden from filing). That is the bug.
grep -F '## Filing results' "$report_dir/report.md" >/dev/null \
  || fail "report.md missing Filing results section"
grep -F 'https://github.com/Nishfleet/fleet-ops/issues/9999' "$report_dir/report.md" >/dev/null \
  || fail "report.md does not link the filed issue"
[[ -n $(jq -R -c 'fromjson | select(.rank=="1" and .issue=="https://github.com/Nishfleet/fleet-ops/issues/9999")' "$verdicts") ]] \
  || fail "verdicts.jsonl rank 1 missing issue URL"

# gh issue create must use --body-file (not --body) and both labels.
# gap-audit alone is the #402 class: findings sit on the gap-board with
# no owner because intake lists agent-ready only.
grep -E 'CREATE .*--body-file ' "$scratch/gh-create.log" >/dev/null \
  || fail "gh issue create was not invoked with --body-file: $(cat "$scratch/gh-create.log")"
grep -E 'CREATE .*--label gap-audit' "$scratch/gh-create.log" >/dev/null \
  || fail "gh issue create missing --label gap-audit: $(cat "$scratch/gh-create.log")"
grep -E 'CREATE .*--label agent-ready' "$scratch/gh-create.log" >/dev/null \
  || fail "gh issue create missing --label agent-ready (fleet-ops#402): $(cat "$scratch/gh-create.log")"

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
grep -E 'CREATE .*--label agent-ready' "$drill_log" >/dev/null \
  || fail "drill gh create missing --label agent-ready (fleet-ops#402): $(cat "$drill_log")"
ok "drill: fixture finding filed as gap-audit + agent-ready issue with report linked"

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

# ============================================================================
# fleet-ops#367: auditing products/fleet-ops (worktree parent) retargets to
# the canonical deploy-clone and auto-files. Overlay FLEET_OPS_WORKSPACES_ROOT
# so this never touches the live box.
# ============================================================================
ws367="$scratch/ws367"
canon367="$ws367/tooling/fleet-ops-deploy-clone"
parent367="$ws367/tooling/fleet-ops"
products367="$ws367/products/fleet-ops"
mkdir -p "$canon367/docs" "$parent367" "$ws367/products"
ln -sfn "$parent367" "$products367"
printf '# overlay deliberate states\n' >"$canon367/docs/deliberate-states.md"

noncanon_state="$scratch/noncanon-state"
noncanon_plan="$scratch/noncanon-plan.md"
noncanon_log="$scratch/noncanon-create.log"
mkdir -p "$noncanon_state"
: > "$noncanon_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$noncanon_plan"

noncanon_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$noncanon_log" \
  FLEET_OPS_WORKSPACES_ROOT="$ws367" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon367" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$products367" \
  AUDIT_STATE_DIR="$noncanon_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$noncanon_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:23:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/noncanon.log" 2>&1 || noncanon_rc=$?
[[ $noncanon_rc == 0 ]] || { cat "$scratch/noncanon.log"; fail "noncanonical-root drill exited $noncanon_rc"; }
grep -F 'AUDIT-NONCANONICAL' "$scratch/noncanon.log" >/dev/null \
    || fail "noncanonical products/fleet-ops root did not log AUDIT-NONCANONICAL: $(cat "$scratch/noncanon.log")"
grep -F "$canon367" "$scratch/noncanon.log" >/dev/null \
    || fail "AUDIT-NONCANONICAL log did not name the canonical checkout"
grep -E 'CREATE .*--body-file ' "$noncanon_log" >/dev/null \
    || fail "noncanonical auto-file missing --body-file: $(cat "$noncanon_log")"
grep -F 'Blind audit targeted non-canonical' "$noncanon_log" >/dev/null \
    || fail "noncanonical auto-file missing detector title: $(cat "$noncanon_log")"
# fleet-ops#503: the noncanonical-checkout detector issue must be stamped
# gap-audit + agent-ready at create time, or intake (agent-ready only) cannot
# see it until lifecycle-label-sweep runs. Same class as the #402 create site.
# The grep pins the detector title so the drill finding's own labeled CREATE
# (fleet-ops#402) cannot satisfy this guard.
grep -E 'CREATE .*Blind audit targeted non-canonical.*--label gap-audit' "$noncanon_log" >/dev/null \
    || fail "noncanonical auto-file missing --label gap-audit (fleet-ops#503): $(cat "$noncanon_log")"
grep -E 'CREATE .*Blind audit targeted non-canonical.*--label agent-ready' "$noncanon_log" >/dev/null \
    || fail "noncanonical auto-file missing --label agent-ready (fleet-ops#503): $(cat "$noncanon_log")"
ok "noncanonical products/fleet-ops root retargets and auto-files"

# Same class via the worktree parent path (not the products symlink).
parent_state="$scratch/parent-state"
parent_plan="$scratch/parent-plan.md"
parent_log="$scratch/parent-create.log"
mkdir -p "$parent_state"
: > "$parent_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$parent_plan"
parent_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$parent_log" \
  FLEET_OPS_WORKSPACES_ROOT="$ws367" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon367" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$parent367" \
  AUDIT_STATE_DIR="$parent_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$parent_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:24:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/parent.log" 2>&1 || parent_rc=$?
[[ $parent_rc == 0 ]] || { cat "$scratch/parent.log"; fail "parent-root drill exited $parent_rc"; }
grep -F 'AUDIT-NONCANONICAL' "$scratch/parent.log" >/dev/null \
    || fail "worktree-parent root did not log AUDIT-NONCANONICAL"
# fleet-ops#503: parent-path auto-file must also stamp both labels.
grep -E 'CREATE .*Blind audit targeted non-canonical.*--label gap-audit' "$parent_log" >/dev/null \
    || fail "parent auto-file missing --label gap-audit (fleet-ops#503): $(cat "$parent_log")"
grep -E 'CREATE .*Blind audit targeted non-canonical.*--label agent-ready' "$parent_log" >/dev/null \
    || fail "parent auto-file missing --label agent-ready (fleet-ops#503): $(cat "$parent_log")"
ok "noncanonical tooling/fleet-ops parent retargets"

# AUDIT_ALLOW_NONCANONICAL=1 skips retarget (tests/auditors that mean it).
allow_state="$scratch/allow-state"
allow_plan="$scratch/allow-plan.md"
mkdir -p "$allow_state"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$allow_plan"
allow_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$scratch/allow-create.log" \
  FLEET_OPS_WORKSPACES_ROOT="$ws367" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon367" \
  AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$products367" \
  AUDIT_STATE_DIR="$allow_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$allow_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:25:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/allow.log" 2>&1 || allow_rc=$?
[[ $allow_rc == 0 ]] || { cat "$scratch/allow.log"; fail "allow-noncanonical drill exited $allow_rc"; }
if grep -F 'AUDIT-NONCANONICAL' "$scratch/allow.log" >/dev/null; then
    fail "AUDIT_ALLOW_NONCANONICAL=1 still retargeted: $(cat "$scratch/allow.log")"
fi
ok "AUDIT_ALLOW_NONCANONICAL=1 skips retarget"

# Dedup: an open issue already carrying the marker -> no second detector create.
dedup_gh="$scratch/dedupgh"
mkdir -p "$dedup_gh"
cat > "$dedup_gh/gh" <<'DEDUP_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true
case "$subcmd" in
  label) exit 0 ;;
  issue)
    case "${1:-}" in
      list)
        printf '%s\n' '[{"number":367,"title":"stale","body":"audit-target-noncanonical: fleet-ops#367\n"}]'
        ;;
      create)
        printf 'CREATE %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
    esac
    exit 0
    ;;
  pr) printf '%s\n' '[]'; exit 0 ;;
  *) exit 0 ;;
esac
DEDUP_GH
chmod +x "$dedup_gh/gh"

dedup_state="$scratch/dedup-state"
dedup_plan="$scratch/dedup-plan.md"
dedup_log="$scratch/dedup-create.log"
mkdir -p "$dedup_state"
: > "$dedup_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$dedup_plan"
dedup_rc=0
PATH="$dedup_gh:$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$dedup_log" \
  FLEET_OPS_WORKSPACES_ROOT="$ws367" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon367" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$products367" \
  AUDIT_STATE_DIR="$dedup_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$dedup_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:26:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/dedup.log" 2>&1 || dedup_rc=$?
[[ $dedup_rc == 0 ]] || { cat "$scratch/dedup.log"; fail "dedup drill exited $dedup_rc"; }
grep -F 'AUDIT-NONCANONICAL' "$scratch/dedup.log" >/dev/null \
    || fail "dedup run did not still retarget"
grep -F 'Blind audit targeted non-canonical' "$dedup_log" >/dev/null \
    && fail "dedup still filed a second detector issue: $(cat "$dedup_log")"
grep -F 'dedup:' "$scratch/dedup.log" >/dev/null \
    || fail "dedup run did not log dedup: $(cat "$scratch/dedup.log")"
ok "open #367-marker issue suppresses a second detector file"

# fleet-ops#377: host the seam-lens unit test from the listed blind-audit test
# so it runs in CI without a workflow-file edit (P14 hosted-test pattern).
bash "$here/manual-seam-lens.test.sh"

# fleet-ops#2771: host the deliberate-states registry regression test (a
# row with a passed expiry is a spurious gap-audit waiting to fire) from the
# listed blind-audit test so it runs in CI without a workflow-file edit.
bash "$here/deliberate-states-registry.test.sh"

# fleet-ops#838: no | head -N truncation pipes survive under set -o pipefail.
# grep -mN is the safe replacement; head -c on a file is fine.
if grep -nE '\| +head +-[0-9]' "$bin"; then
    fail "fleet-blind-audit contains | head -N pipe that risks SIGPIPE (fleet-ops#838)"
fi
ok "no head -N truncation pipes in fleet-blind-audit"

echo "OK: fleet-blind-audit.test.sh"

