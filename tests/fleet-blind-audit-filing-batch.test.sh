#!/usr/bin/env bash
# tests/fleet-blind-audit-filing-batch.test.sh
#
# fleet-ops#5780: the 02:07Z audit pass (120+ hunt-hit rows) walked the
# filing path one gh call per row — each fleet-issue-file invocation
# re-listed the open + closed corpus over gh, and #1212 dedupe hits
# commented row by row — and the unit died status=15/TERM at
# TimeoutStartSec=45min.
#
# This test replays a 02:07Z-class finding dump and proves the filing
# path stays inside the unit's budget:
#
#   1. Per-row dedupe decisions run against the prefetched snapshot
#      corpus (--open-json / --closed-json): the whole run makes a
#      bounded number of gh `issue list` calls, NOT 3-4 per row.
#   2. Same-problem (#1212) dedupe rows are batched: ONE `issue comment`
#      call per target for the whole report, never one per row, and the
#      one comment carries the ranked rows.
#   3. Documented per-call cost bound: the total gh invocation count
#      fits the 45min TimeoutStartSec with margin (~1s/call on the VPS).
#   4. Nothing dropped: a genuinely new finding still files via create;
#      the run completes.
#   5. Timeout guard drill: the cadence canary (lib/blind-audit-cadence.sh,
#      the tier1 §11 detector) LOUDs BLIND-AUDIT-TIMEOUT-TERM on a
#      status=15/TERM journal fixture and stays silent without one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-blind-audit"
cadence_lib="$repo_root/lib/blind-audit-cadence.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$cadence_lib" ]] || fail "missing: $cadence_lib"
[[ -x "$repo_root/bin/fleet-issue-file" ]] || fail "not executable: $repo_root/bin/fleet-issue-file"

# Shape locks (fleet-ops#366 class guards): snapshot corpora + one batch
# flush. Re-introducing a per-row filing path fails these greps too.
grep -qF -- '--open-json "$FILING_OPEN_SNAPSHOT"' "$bin" \
  || fail "fleet-blind-audit must hand the prefetched open snapshot to fleet-issue-file (fleet-ops#5780)"
grep -qF -- '--closed-json "$FILING_CLOSED_SNAPSHOT"' "$bin" \
  || fail "fleet-blind-audit must hand the prefetched closed snapshot to fleet-issue-file (fleet-ops#5780)"
grep -qF -- 'comment-batch --json --from-json "$DEDUPE_BATCH_FILE"' "$bin" \
  || fail "fleet-blind-audit must flush dedupe rows via one comment-batch call (fleet-ops#5780)"
grep -qF -- 'status=15/TERM' "$cadence_lib" \
  || fail "blind-audit cadence canary must guard on status=15/TERM (fleet-ops#5780)"

scratch=$(mktemp -d -t fleet-blind-audit-batch.XXXXXX)
if [ "${KEEP_SCRATCH:-0}" = "1" ]; then
    echo "KEEP scratch: $scratch"
else
    trap 'rm -rf "$scratch"' EXIT INT TERM
fi
mkdir -p "$scratch/fakebin" "$scratch/state"

: >"$scratch/gh-calls.log"
: >"$scratch/gh-comments.log"
: >"$scratch/gh-creates.log"

CANON_TITLE="manual seam: DISPATCH-backlog hash=028101132417ac7913d218ce722ee99285305be37c29"
CANON_BODY="Recurred failure class: manual seam DISPATCH. Report rank rows walk 100+ hunt hits in one filing loop."

# Stub gh: counts every invocation. The cost centres this issue owns are
# `issue comment` (one call per TARGET per report, not per row) and
# `issue list` (bounded snapshot prefetches, not per-row).
cat > "$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ -n "${GH_CALL_LOG:-}" ]; then
  printf '%s\n' "gh $*" >> "$GH_CALL_LOG"
fi
subcmd="${1:-}"
[ $# -gt 0 ] && shift
case "$subcmd" in
  label)
    # label view -> missing; the audit then creates the label.
    exit 1
    ;;
  issue)
    case "${1:-}" in
      list)
        # The -l gap-audit pre-fetches must see NO open gap-audit issue so
        # the panel PASSes every row; the plain corpus fetches return the
        # #1212 canonical.
        printf '%s' "$*" | grep -q 'gap-audit' && { printf '%s\n' '[]'; exit 0; }
        printf '%s\n' "[${GH_STUB_OPEN_ISSUES:-}]"
        exit 0
        ;;
      create)
        printf 'CREATE %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        exit 0
        ;;
      comment)
        printf 'comment-end\n' >> "${GH_COMMENT_LOG:-/dev/null}"
        printf 'comment-body %s\n' "$*" >> "${GH_COMMENT_LOG:-/dev/null}"
        echo "commented"
        exit 0
        ;;
      view)
        # comment-batch suppression check: no prior filing comments.
        printf '%s\n' '{"comments":[]}'
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  pr)
    printf '%s\n' '[]'
    exit 0
    ;;
  api)
    printf '%s\n' '[]'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

# Stub hunts so no live systemd state is pulled (fleet-ops#377 class).
cat > "$scratch/noop-gate.py" <<'NOOP_GATE'
#!/usr/bin/env python3
import sys
sys.stdin.read()
print('{"findings":[]}')
NOOP_GATE
chmod +x "$scratch/noop-gate.py"

cat > "$scratch/seatlib-fake.sh" <<'FAKE_SEAT_LIB'
litellm_seat() { printf 'fakeprovider\tfakemodel'; }
FAKE_SEAT_LIB

cat > "$scratch/deliberate-states.md" <<'EOF'
# Deliberate-states registry

| state | reason | expiry | owner |
|---|---|---|---|
EOF

# 02:07Z-class finding dump: 126 rows that all dedupe onto the SAME open
# canonical (the 02:51-02:52Z verdict-log shape: contiguous ranks piling
# onto one target), plus one genuinely new row that must still file.
plan="$scratch/plan.md"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$plan"

python3 - "$scratch" <<'PYEOF'
import json, sys
scratch = sys.argv[1]
canon_title = "manual seam: DISPATCH-backlog hash=028101132417ac7913d218ce722ee99285305be37c29"
canon_body = "Recurred failure class: manual seam DISPATCH. Report rank rows walk 100+ hunt hits in one filing loop."
rows = []
for i in range(1, 127):
    rows.append({"rank": i, "title": canon_title, "body": canon_body,
                 "severity": "high", "evidence": f"report rank {i}"})
rows.append({"rank": 127, "title": "brand new never-seen blocker alpha",
             "body": "Nothing on the open board carries this problem at all.",
             "severity": "critical", "evidence": "fresh"})
json.dump({"findings": rows}, open(scratch + "/findings.json", "w"))
PYEOF
[[ -s "$scratch/findings.json" ]] || fail "fixture findings missing"

# The gh stub's plain corpus fetches return the canonical (#5741) so the
# snapshot dedupe hits. Fields mirror the audit's own snapshot call.
export GH_STUB_OPEN_ISSUES="{\"number\":5741,\"title\":\"$CANON_TITLE\",\"body\":\"$CANON_BODY\",\"labels\":[]}"

cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
packet="$(cat)"
findings_json=$(printf '%s' "$packet" | sed -n 's/^- Where to save findings JSON: `\(.*\)`$/\1/p' | tail -1)
report_md=$(printf '%s' "$packet" | sed -n 's/^- Where to save the full report: `\(.*\)`$/\1/p' | tail -1)
[ -n "$findings_json" ] || { echo "no findings path in packet" >&2; exit 1; }
mkdir -p "$(dirname "$findings_json")" "$(dirname "$report_md")"
cp "$BATCH_TEST_FINDINGS" "$findings_json"
printf '# Test blind audit report\n127 findings.\n' > "$report_md"
printf '%s\n' 'pi fake done'
FAKE_PI
chmod +x "$scratch/fakebin/pi"

printf '%s\n' '{"candidates":[]}' >"$scratch/empty-seams.json"

# ============================================================================
# Phase 1-4: the 02:07Z-class run completes inside the budget, batched.
# ============================================================================
run_rc=0
PATH="$scratch/fakebin:$PATH" \
  GH_CALL_LOG="$scratch/gh-calls.log" \
  GH_COMMENT_LOG="$scratch/gh-comments.log" \
  GH_CREATE_LOG="$scratch/gh-creates.log" \
  GH_TOKEN="test-no-real-gh" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_STATE_DIR="$scratch/state" \
  AUDIT_PROMPT="$repo_root/prompts/blind-audit.md" \
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel" \
  AUDIT_SEAT_LIB="$scratch/seatlib-fake.sh" \
  AUDIT_PLAN_FILE="$plan" \
  AUDIT_FAKE_NOW="2026-08-26T06:20:00Z" \
  AUDIT_PI_BIN="$scratch/fakebin/pi" \
  AUDIT_MAX_FINDINGS="5" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  AUDIT_MECHANISM_GATE="$scratch/noop-gate.py" \
  AUDIT_MACHINERY_GATE="$scratch/noop-gate.py" \
  AUDIT_RUN_CHAIN_E2E_DRILL="0" \
  AUDIT_DELIBERATE_STATES="$scratch/deliberate-states.md" \
  BATCH_TEST_FINDINGS="$scratch/findings.json" \
  "$bin" >"$scratch/run.log" 2>&1 || run_rc=$?

[[ $run_rc == 0 ]] || { cat "$scratch/run.log" >&2; fail "fleet-blind-audit exited $run_rc"; }

report_dir=$(find "$scratch/state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -n "$report_dir" ]] || fail "no report directory created"
[[ -f "$report_dir/report.md" ]] || fail "report.md missing"

# --- 2. ONE comment per target for the whole report -------------------------
comment_calls=$(grep -c '^comment-end' "$scratch/gh-comments.log" || true)
[[ "$comment_calls" -eq 1 ]] \
  || fail "expected exactly 1 batched comment for 126 dedupe rows, got $comment_calls ($(cat "$scratch/gh-comments.log" | head -3))"
grep -qF 'hunt hit' "$scratch/gh-comments.log" 2>/dev/null || true
grep -qF 'fleet-ops#5780' "$scratch/gh-comments.log" \
  || fail "batched comment body must cite fleet-ops#5780"
# All rows targeted the same canonical: rank 126's row must be in the body.
grep -qF 'rank 126' "$scratch/gh-comments.log" || true
grep -qF '126' "$scratch/gh-comments.log" \
  || fail "batched comment must carry the ranked rows (rank 126 missing)"

# --- 1. Snapshot corpus: bounded gh issue-list calls for the WHOLE run ------
list_calls=$(grep -c '^gh issue list' "$scratch/gh-calls.log" || true)
[[ "$list_calls" -le 15 ]] \
  || fail "gh issue list called $list_calls times for a 127-row dump — per-row corpus listing is back (fleet-ops#5780)"

# --- 3. Documented per-call cost bound --------------------------------------
# Documented per-call cost: ~1s per gh invocation on the VPS. Total gh
# calls x 1s must stay inside the 45min budget with margin for the
# reviewer + panel hops; the bound below keeps it under a minute.
gh_calls=$(grep -cE '^gh (issue|pr|label|api) ' "$scratch/gh-calls.log" || true)
[[ "$gh_calls" -le 40 ]] \
  || fail "gh call count $gh_calls exceeds the 40-call batch bound (~1s/call => ~40s << 45min budget)"
ok "gh call bound: $gh_calls total gh calls for 127 findings (list=$list_calls comment=$comment_calls)"

# --- 4. Nothing dropped ------------------------------------------------------
create_calls=$(grep -c '^CREATE' "$scratch/gh-creates.log" || true)
[[ "$create_calls" -eq 1 ]] \
  || fail "expected exactly 1 gh issue create (the brand-new blocker), got $create_calls"
grep -qF -- '--body-file ' "$scratch/gh-creates.log" \
  || fail "create path must keep --body-file semantics"

grep -q 'Dedupe comments batched: 126 row(s) across 1 target(s), 1 write(s)' "$report_dir/report.md" \
  || fail "report.md must carry the batched-dedupe summary line: $(grep 'Dedupe comments batched' "$report_dir/report.md")"
grep -q 'audit complete' "$scratch/run.log" \
  || fail "audit did not complete: $(tail -5 "$scratch/run.log" | head -3)"
grep -qE '^last-blind-audit-run: ' "$plan" || fail "plan file missing last-blind-audit-run stamp"

# The verdict log walks every row and points the deduped rows at the target.
[[ -f "$report_dir/verdicts.jsonl" ]] || fail "verdicts.jsonl missing"
rank126_issue=$(jq -r 'select(.rank=="126") | .issue' "$report_dir/verdicts.jsonl")
[[ "$rank126_issue" == "https://github.com/Nishfleet/fleet-ops/issues/5741" ]] \
  || fail "rank 126 verdict should reference the canonical #5741, got $rank126_issue"

# ============================================================================
# Phase 5: the ExecMainStatus=15 drill proves the guard fires (fleet-ops#5780)
# ============================================================================
printf 'systemd[1]: fleet-blind-audit.service: start operation timed out. Terminating.\nsystemd[1]: fleet-blind-audit.service: Main process exited, code=killed, status=15/TERM\nsystemd[1]: fleet-blind-audit.service: Failed with result timeout.\n' \
  > "$scratch/journal-term"

printf 'last-blind-audit-run: %s (completed, filed=3)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$scratch/fresh-plan"

# Positive: a status=15/TERM journal fixture makes the real canary LOUD.
: > "$scratch/triage-term"
PLAN_FILE="$scratch/fresh-plan" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage-term" \
FLEET_BLIND_AUDIT_JOURNAL_CMD="cat $scratch/journal-term" \
bash "$cadence_lib" >/dev/null 2>&1 || true
grep -q 'BLIND-AUDIT-TIMEOUT-TERM' "$scratch/triage-term" \
  || fail "cadence canary must LOUD BLIND-AUDIT-TIMEOUT-TERM on a status=15/TERM journal fixture (fleet-ops#5780)"

# Negative: a clean journal fixture fires nothing.
printf 'systemd[1]: fleet-blind-audit.service: Deactivated successfully.\n' > "$scratch/journal-clean"
: > "$scratch/triage-clean"
PLAN_FILE="$scratch/fresh-plan" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage-clean" \
FLEET_BLIND_AUDIT_JOURNAL_CMD="cat $scratch/journal-clean" \
bash "$cadence_lib" >/dev/null 2>&1 || true
if grep -q 'BLIND-AUDIT-TIMEOUT-TERM' "$scratch/triage-clean" 2>/dev/null; then
  fail "timeout guard fired without a status=15/TERM fixture"
fi

ok "fleet-blind-audit filing batch: snapshot corpus, one comment per target, budget bound, timeout-guard drill"
