#!/usr/bin/env bash
# tests/manual-seam-lens.test.sh
#
# fleet-ops#377: standing manual-seam lens.
#   1. The blind-audit prompt carries the lens section and output contract.
#   2. Gap-closure cycle criteria (#180) name the lens as a CLEAN gate.
#   3. The enumerator classifies fixtures: matched / filed / accepted-as-manual.
#   4. fleet-blind-audit writes the seam table even when the reviewer omits it.
#   5. An unmatched seam is queued as a gap-audit finding.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/blind-audit.md"
criteria="$repo_root/config/gap-closure-cycle-criteria.md"
lens="$repo_root/lib/manual-seam-lens.py"
audit="$repo_root/bin/fleet-blind-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$criteria" ]] || fail "missing $criteria"
[[ -f "$lens" ]] || fail "missing $lens"
[[ -x "$audit" ]] || fail "not executable: $audit"

# --- 1. Prompt contract ----------------------------------------------------
grep -q '## Manual-seam lens' "$prompt" \
  || fail "prompts/blind-audit.md must have a Manual-seam lens section"
grep -q '{{SEAM_EVIDENCE_JSON}}' "$prompt" \
  || fail "prompt must take {{SEAM_EVIDENCE_JSON}} from the harness"
grep -q 'accepted-as-manual' "$prompt" \
  || fail "prompt must name accepted-as-manual"
grep -q 'dated reason' "$prompt" \
  || fail "prompt must require a dated reason for Nish-only seams"
ok "prompt carries the manual-seam lens"

# --- 2. Cycle criteria (#180) ----------------------------------------------
grep -q 'Manual-seam lens' "$criteria" \
  || fail "cycle criteria must name the Manual-seam lens"
grep -q 'No unmatched seams' "$criteria" \
  || fail "cycle criteria must refuse CLEAN while unmatched seams remain"
grep -q 'accepted-as-manual' "$criteria" \
  || fail "cycle criteria must name accepted-as-manual"
ok "gap-closure cycle criteria include the seam hunt"

# --- 3. Enumerator against fixtures ----------------------------------------
scratch=$(mktemp -d -t seam-lens.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/candidates.json" <<'JSON'
{
  "since": "2026-08-26T12:00:00Z",
  "now": "2026-08-26T16:00:00Z",
  "candidates": [
    {"seam": "hand-started fleet-blind-audit.service", "source": "systemctl-start", "when": "2026-08-26T15:11:58Z", "evidence": "journal: Starting fleet-blind-audit.service (no TriggeredBy)"},
    {"seam": "hand-filed twelve issues from the first audit report", "source": "github", "when": "2026-08-26T15:20:00Z", "evidence": "gh issue create by flagship"},
    {"seam": "approve a paid Hostinger refund", "source": "actions-log", "when": "2026-08-26T15:30:00Z", "evidence": "actions.log: money"}
  ]
}
JSON

cat >"$scratch/open-issues.json" <<'JSON'
[{"number":358,"title":"hand-started the first blind-audit run / fleet-blind-audit.service"}]
JSON

cat >"$scratch/findings.json" <<'JSON'
{
  "findings": [],
  "seams": [
    {"seam": "approve a paid Hostinger refund", "disposition": "accepted-as-manual", "reason": "money is Nish-only"}
  ]
}
JSON

: >"$scratch/report.md"

python3 "$lens" close \
  --candidates "$scratch/candidates.json" \
  --findings "$scratch/findings.json" \
  --open-issues "$scratch/open-issues.json" \
  --report "$scratch/report.md" \
  --seams-out "$scratch/seams.json" \
  --now "2026-08-26T16:00:00Z" >"$scratch/close.json"

jq -e '.added == 1 and .matched == 1 and .accepted == 1 and .filed == 1' "$scratch/close.json" >/dev/null \
  || fail "close counts wrong: $(cat "$scratch/close.json")"

grep -q '## Manual-seam lens' "$scratch/report.md" \
  || fail "close must write ## Manual-seam lens into the report"
grep -q 'accepted-as-manual' "$scratch/report.md" \
  || fail "report table missing accepted-as-manual row"
grep -q 'matched' "$scratch/report.md" \
  || fail "report table missing matched row"
grep -q 'manual seam: hand-filed twelve issues' "$scratch/findings.json" \
  || fail "unmatched seam was not queued as a finding"
ok "enumerator matches, files, and accepts-as-manual"

# Worker-claim comments and timer-parent starts must not become seams.
mkdir -p "$scratch/mem"
cat >"$scratch/actions.log" <<'LOG'
2026-08-26T15:00:00Z hand-repaired a /tmp symlink
2026-08-26T15:01:00Z claimed by pi-issue-fleet-ops-1 at 2026-08-26T15:01:00Z
LOG
cat >"$scratch/gh.json" <<'JSON'
[
  {"kind":"comment","body":"claimed by pi-issue-fleet-ops-99","created_at":"2026-08-26T15:02:00Z","number":99},
  {"kind":"issue","title":"[gap-audit] silent timer","body":"Filed by fleet-blind-audit","created_at":"2026-08-26T15:03:00Z","number":367},
  {"kind":"issue","title":"hand-labeled five invisible issues","body":"flagship","created_at":"2026-08-26T15:04:00Z","number":376}
]
JSON
cat >"$scratch/starts.json" <<'JSON'
[
  {"unit":"fleet-heartbeat.service","when":"2026-08-26T15:10:00Z","triggered_by":["fleet-heartbeat.timer"]},
  {"unit":"fleet-blind-audit.service","when":"2026-08-26T15:11:58Z","triggered_by":[]}
]
JSON

python3 "$lens" collect \
  --since "2026-08-26T14:00:00Z" \
  --now "2026-08-26T16:00:00Z" \
  --actions-log "$scratch/actions.log" \
  --gh-events "$scratch/gh.json" \
  --systemctl-starts "$scratch/starts.json" >"$scratch/collected.json"

jq -e '.candidates | length == 3' "$scratch/collected.json" >/dev/null \
  || fail "collect should keep 3 hand seams, got $(jq '.candidates | length' "$scratch/collected.json"): $(cat "$scratch/collected.json")"
jq -e '[.candidates[].seam] | index("hand-repaired a /tmp symlink")' "$scratch/collected.json" >/dev/null \
  || fail "actions-log hand line dropped"
jq -e '[.candidates[].seam] | index("hand-labeled five invisible issues")' "$scratch/collected.json" >/dev/null \
  || fail "hand-filed github issue dropped"
jq -e '[.candidates[].seam] | index("hand-started fleet-blind-audit.service")' "$scratch/collected.json" >/dev/null \
  || fail "untriggered systemctl start dropped"
ok "collect drops worker claims, gap-audit filings, and timer-parent starts"

# --- 4+5. Harness writes the table when the reviewer omits it --------------
mkdir -p "$scratch/fakebin" "$scratch/state"
cat >"$scratch/deliberate-states.md" <<'EOF'
# Deliberate-states registry

| state | reason | expiry | owner |
|---|---|---|---|
| active-pause | Fleet tuning pause. | 2026-09-02 | Nish |
EOF

cat >"$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
packet=$(cat)
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | head -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | head -1)
mkdir -p "$(dirname "$findings_json")"
printf '%s\n' '{"findings":[]}' >"$findings_json"
printf '%s\n' '# Reviewer report
Reviewer wrote no seam table.' >"$report_md"
printf '%s\n' 'pi fake done'
FAKE_PI
chmod +x "$scratch/fakebin/pi"

cat >"$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true
case "$subcmd" in
  label) exit 0 ;;
  issue)
    case "${1:-}" in
      list) printf '%s\n' '[]' ;;
      create) echo "https://github.com/Nishfleet/fleet-ops/issues/9001" ;;
    esac
    exit 0
    ;;
  pr) printf '%s\n' '[]'; exit 0 ;;
  *) exit 0 ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

cat >"$scratch/plan.md" <<'EOF'
last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)
last-blind-audit-run: 2026-08-26T12:00:00Z (completed, filed=4)
EOF

cat >"$scratch/seams-in.json" <<'JSON'
{
  "candidates": [
    {"seam": "hand-verified four closed-but-undelivered deliveries", "source": "actions-log", "when": "2026-08-26T15:40:00Z", "evidence": "actions.log"}
  ]
}
JSON

PATH="$scratch/fakebin:$PATH" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$scratch/state" \
  AUDIT_PROMPT="$prompt" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_SEAT_LIB="$repo_root/lib/seat-lib.sh" \
  AUDIT_PLAN_FILE="$scratch/plan.md" \
  AUDIT_FAKE_NOW="2026-08-26T16:00:00Z" \
  AUDIT_PI_BIN="$scratch/fakebin/pi" \
  AUDIT_MAX_FINDINGS="5" \
  AUDIT_SEAM_EVIDENCE="$scratch/seams-in.json" \
  "$audit" >"$scratch/run.log" 2>&1 || rc=$?
rc=${rc:-0}
[[ $rc == 0 ]] || { cat "$scratch/run.log"; fail "fleet-blind-audit exited $rc"; }

report_dir=$(find "$scratch/state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "$report_dir" ]] || fail "no report directory"
grep -q '## Manual-seam lens' "$report_dir/report.md" \
  || fail "harness did not write the seam table into report.md"
grep -q 'hand-verified four closed-but-undelivered deliveries' "$report_dir/report.md" \
  || fail "seam table missing the unmatched seam"
[[ -f "$report_dir/seams.json" ]] || fail "seams.json missing"
filed=$(grep -c 'FILED' "$scratch/run.log" || true)
[[ "$filed" == "1" ]] || { cat "$scratch/run.log"; fail "expected unmatched seam to be filed, saw $filed"; }
ok "harness writes the seam table and files unmatched seams"

echo "OK: manual-seam lens (fleet-ops#377)"
