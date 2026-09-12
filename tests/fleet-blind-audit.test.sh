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

# Pin the seam lens to the repo copy under test; otherwise the harness picks
# up the installed ~/.local/lib/pi-packet copy, which lags the repo's CLI
# (fleet-ops#5477 added --closed-issues).
export AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py"

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
# fleet-ops#5037: a drill files a synthetic fixture, so it may file only
# through a declared stub gh. The mint block must also not put the canonical
# bin dir ahead of an inherited stub: that reorder is how a drill run with no
# GH_TOKEN resolved the real gh and filed the fixture as live issue #5037.
grep -q 'command -v gh >/dev/null 2>&1 || export PATH=/home/nish/.local/bin' "$bin" \
    || fail "fleet-blind-audit must extend PATH only when gh is already missing (fleet-ops#5037)"
grep -q 'AUDIT_DRILL_GH_STUB_DIR' "$bin" \
    || fail "fleet-blind-audit must gate drill filing on a declared stub gh dir (fleet-ops#5037)"

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
# fleet-ops#5611: when BIG_ISSUES_FILE is set the list is padded past 128KB
# (MAX_ARG_STRLEN) so the hunt exercises the file-based --slurpfile path; the
# old --argjson invocation died 126 "Argument list too long" at that size.
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
        # fleet-ops#5611: pad the BODY-carrying issue lists (--state
        # open/closed, no -l filter) past 128KB; the -l gap-audit panel
        # pre-fetch is number+title only and stays small in production.
        if [ -n "${BIG_ISSUES_FILE:-}" ] && [ -f "$BIG_ISSUES_FILE" ] \
            && [[ "$*" != *gap-audit* ]]; then
          cat "$BIG_ISSUES_FILE"
        else
          printf '%s\n' '[{"number":77,"title":"stale agent-state file","labels":[]}]'
        fi
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

# fleet-ops#5611: pad the issue list past the ~128KB MAX_ARG_STRLEN that
# E2BIG'd the old --argjson hunt. 100 extra issues x 2KB body + issue 77.
python3 - >"$scratch/big-issues.json" <<'PY'
import json
issues = [{"number": 77, "title": "stale agent-state file", "labels": []}]
for i in range(100):
    issues.append({"number": 1000 + i, "title": "pad finding %04d" % i,
                   "labels": [], "body": "x" * 2000})
print(json.dumps(issues))
PY
[[ $(wc -c <"$scratch/big-issues.json") -gt 131072 ]] || fail "padded issue list not past 128KB MAX_ARG_STRLEN"
# fleet-ops#5654: assert the class, not just the size — replaying the old
# argv pattern (jq --argjson closed <~206KB blob>) dies 126 "Argument list
# too long" on this host, matching the 2026-09-12 03:30 IST unit signature.
# The harness run below must fail before / pass after the --slurpfile class
# of change; this replay proves the padding is big enough to have killed the
# old code, so the regression test cannot pass vacuously.
replay_rc=0
jq -n --argjson closed "$(cat "$scratch/big-issues.json")" '.' >/dev/null 2>&1 \
  || replay_rc=$?
[[ $replay_rc == 126 ]] \
  || fail "old --argjson replay must die 126 (E2BIG) on this host, got $replay_rc"
# fleet-ops#377: feed an empty seam-evidence fixture so the harness does not
# touch live memoryctl/actions-log sources, and prove the seam table still
# appears in the report with no seams in the window.
printf '%s\n' '{"candidates":[]}' >"$scratch/empty-seams.json"

# Capture the binary's exit code without tripping set -e so the fail block
# below actually prints. Under set -e a failing bin would exit the test
# script silently before rc=$? runs (the fleet-ops#280 "no FAIL line" symptom).
rc=0
# fleet-ops#3618: set a dummy GH_TOKEN so bin/fleet-blind-audit and
# bin/fleet-issue-file skip their worker-token mint + PATH rewrite (the
# block guarded by `-z GH_TOKEN && GITHUB_ACTIONS != true && GH == gh`).
# Without this, a VPS run shadows $scratch/fakebin/gh behind the real gh
# and files real gap-audit issues from the test fixtures (#3617/#3618).
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$scratch/gh-create.log" \
  GH_TOKEN="test-no-real-gh" \
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
  BIG_ISSUES_FILE="$scratch/big-issues.json" \
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

grep -q 'recurrence hunt merged' "$scratch/run.log" \
  || fail "run.log missing 'recurrence hunt merged' — the hunt jq never ran"
if grep -q 'Argument list too long' "$scratch/run.log"; then
  fail "hunt jq still hit E2BIG: $(grep 'Argument list' "$scratch/run.log")"
fi

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
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin" \
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
# fleet-ops#5037: a drill files a SYNTHETIC fixture, so it must never reach the
# live tracker. It may file only through a declared stub gh. No stub declared,
# or a declared stub that is not the gh that resolves, refuses and exits 1.
# ============================================================================
refuse_state="$scratch/refuse-state"
refuse_plan="$scratch/refuse-plan.md"
refuse_log="$scratch/refuse-create.log"
mkdir -p "$refuse_state" "$scratch/emptybin"
: > "$refuse_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$refuse_plan"

refuse_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$refuse_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$refuse_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$refuse_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:27:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/refuse.log" 2>&1 || refuse_rc=$?
[[ $refuse_rc == 1 ]] || { cat "$scratch/refuse.log"; fail "drill with no stub gh declared must exit 1, got $refuse_rc"; }
grep -F 'REFUSED' "$scratch/refuse.log" >/dev/null \
  || fail "drill without a declared stub gh did not log REFUSED: $(cat "$scratch/refuse.log")"
[[ ! -s "$refuse_log" ]] \
  || fail "drill filed without a declared stub gh: $(cat "$refuse_log")"
ok "drill refuses to file when no stub gh is declared (fleet-ops#5037)"

# The #5037 mechanism itself: the declared stub dir is NOT where gh resolves
# from, because something reordered PATH (the mint block used to put
# /home/nish/.local/bin ahead of the stub). Refuse rather than file.
shadow_state="$scratch/shadow-state"
shadow_plan="$scratch/shadow-plan.md"
shadow_log="$scratch/shadow-create.log"
mkdir -p "$shadow_state"
: > "$shadow_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$shadow_plan"

shadow_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CREATE_LOG="$shadow_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$shadow_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$shadow_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:28:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_GH_STUB_DIR="$scratch/emptybin" \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/shadow.log" 2>&1 || shadow_rc=$?
[[ $shadow_rc == 1 ]] || { cat "$scratch/shadow.log"; fail "drill whose declared stub is not the resolved gh must exit 1, got $shadow_rc"; }
grep -F 'REFUSED' "$scratch/shadow.log" >/dev/null \
  || fail "shadowed-stub drill did not log REFUSED: $(cat "$scratch/shadow.log")"
[[ ! -s "$shadow_log" ]] \
  || fail "drill filed while its stub gh was shadowed: $(cat "$shadow_log")"
ok "drill refuses to file when its declared stub gh is not the resolved gh (fleet-ops#5037)"

# ============================================================================
# The #5037 scenario end to end: a drill run from a shell with NO GH_TOKEN
# mints a token, and the mint block must not reorder PATH ahead of the stub gh.
# If it did, gh resolves to the real binary; the stub-dir guard is then the
# backstop that refuses the write. This run is hermetic: PATH keeps the stub
# first, so even a mutated guard cannot reach the live tracker.
# ============================================================================
cat > "$scratch/fakebin/worker-token" <<'FAKE_WT'
#!/usr/bin/env bash
printf 'export GH_TOKEN=stub-token\n'
FAKE_WT
chmod +x "$scratch/fakebin/worker-token"

mint_state="$scratch/mint-state"
mint_plan="$scratch/mint-plan.md"
mint_log="$scratch/mint-create.log"
mkdir -p "$mint_state"
: > "$mint_log"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$mint_plan"

mint_rc=0
env -u GH_TOKEN \
  PATH="$scratch/fakebin:$PATH" \
  NISHFLEET_WORKER_TOKEN_BIN="$scratch/fakebin/worker-token" \
  GH_CREATE_LOG="$mint_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$mint_state" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_PLAN_FILE="$mint_plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:29:00Z" \
  AUDIT_DRILL=1 \
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin" \
  AUDIT_DRILL_FINDINGS="$repo_root/tests/fixtures/blind-audit-drill-finding.json" \
  AUDIT_MAX_FINDINGS="5" \
  "$bin" >"$scratch/mint.log" 2>&1 || mint_rc=$?
[[ $mint_rc == 0 ]] || { cat "$scratch/mint.log"; fail "token-less drill must still file through the stub gh, got rc=$mint_rc"; }
grep -E 'CREATE .*--label agent-ready' "$mint_log" >/dev/null \
  || fail "token-less drill did not file through the stub gh (mint block reordered PATH ahead of the stub): $(cat "$scratch/mint.log")"
ok "token-less drill keeps the stub gh first and files through it (fleet-ops#5037)"

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
  AUDIT_DRILL_GH_STUB_DIR="$fail_gh" \
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
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin" \
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
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin" \
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
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin" \
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
  AUDIT_DRILL_GH_STUB_DIR="$dedup_gh" \
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

# fleet-ops#3683: host the closed-but-undelivered detector drill (flags an
# issue closed after a PR tried to deliver it but no referencing PR merged)
# from the listed blind-audit test so it runs in CI without a workflow-file
# edit (the nishfleet-worker App token has no Workflows permission).
bash "$here/closed-undelivered-detector.test.sh"

# fleet-ops#838: no | head -N truncation pipes survive under set -o pipefail.
# grep -mN is the safe replacement; head -c on a file is fine.
if grep -nE '\| +head +-[0-9]' "$bin"; then
    fail "fleet-blind-audit contains | head -N pipe that risks SIGPIPE (fleet-ops#838)"
fi
ok "no head -N truncation pipes in fleet-blind-audit"

# ============================================================================
# fleet-ops#3680: panel evidence-quality gate. A "stale file" freshness
# finding whose evidence is a bare `find ... -mtime` enumeration of a
# directory (naming no specific decision-driving file) must be FAILed even
# when no duplicate open issue exists — otherwise it files non-actionable
# worker issues that catch reports/logs/backups which are supposed to be old.
# A finding that names the specific file (with an extension) is actionable
# and passes the gate.
# ============================================================================
panel_lib="$repo_root/lib/blind-audit-panel.py"

run_panel() {
    printf '%s' "$1" | python3 "$panel_lib"
}

# Case 1: bare `find -mtime`, no file path with extension anywhere -> FAIL.
case1='{"finding":{"rank":1,"title":"stale agent-state file","body":"Duplicate of the open gap-audit issue.","severity":"high","evidence":"find /home/nish/workspaces/agent-state -mtime +1"},"open_issues":[],"recent_merges":[],"deliberate_states":[]}'
case1_v=$(run_panel "$case1" | jq -r '.verdict')
case1_r=$(run_panel "$case1" | jq -r '.reason')
[[ "$case1_v" == "FAIL" ]] \
    || fail "#3680 gate: bare find -mtime finding should FAIL, got $case1_v"
[[ "$case1_r" == *"overly-broad freshness finding"* ]] \
    || fail "#3680 gate: FAIL reason should name the gate, got: $case1_r"

# Case 2: `find -mtime` evidence BUT the body names a specific file -> PASS
# (actionable: the finding tells a worker exactly which file to check).
case2='{"finding":{"rank":1,"title":"fleet-repos.json stale","body":"~/.local/state/fleet-heartbeat/fleet-repos.json drives the heartbeat queue and is never freshness-checked; find -mtime +1 shows it stale","severity":"high","evidence":"find /home/nish/.local/state/fleet-heartbeat -mtime +1"},"open_issues":[],"recent_merges":[],"deliberate_states":[]}'
case2_v=$(run_panel "$case2" | jq -r '.verdict')
[[ "$case2_v" == "PASS" ]] \
    || fail "#3680 gate: find -mtime finding that names a specific file should PASS, got $case2_v"

# Case 3: stat-based evidence (no find -mtime) is unaffected -> PASS.
case3='{"finding":{"rank":1,"title":"visual-quality-waves.md stale 6 days","body":"auditor prompt reads it as program status","severity":"low","evidence":"stat -c %y /home/nish/workspaces/agent-state/visual-quality-waves.md = 2026-08-28; prompts/auditor.md line 4"},"open_issues":[],"recent_merges":[],"deliberate_states":[]}'
case3_v=$(run_panel "$case3" | jq -r '.verdict')
[[ "$case3_v" == "PASS" ]] \
    || fail "#3680 gate: stat-based freshness finding should PASS (gate only targets find -mtime), got $case3_v"

ok "panel #3680 gate: rejects bare find -mtime freshness findings, passes named-file findings"

echo "OK: fleet-blind-audit.test.sh"


# fleet-ops#5101: the class fix for the shared App-token mint header PATH
# guard is exercised by its own drill; hosted here because workers cannot
# push .github/workflows/** (P14 listing gate).
bash "$here/app-token-mint-stub-respect.test.sh"
