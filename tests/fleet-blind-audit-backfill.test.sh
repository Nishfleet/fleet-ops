#!/usr/bin/env bash
# tests/fleet-blind-audit-backfill.test.sh
#
# Backfill mode (deliverable B, hermetic): reconstruct unfiled PASS findings
# from report dirs, dedupe by signature across runs, pre-drop a finding whose
# signature an open issue already carries, re-panel, and file the survivors.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-blind-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t fleet-blind-audit-bf.XXXXXX)
keepit() { if [ "${KEEP_SCRATCH:-}" != 1 ]; then rm -rf "$scratch"; fi; }
trap keepit EXIT INT TERM

mkdir -p "$scratch/fakebin" "$scratch/state/reports/20260826T100000Z" "$scratch/state/reports/20260826T110000Z"

# Stub gh.
cat > "$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$1 $2" in
  "label view") exit 1 ;;
  "issue list")
    case "$*" in
      *"--state closed"*) [ -f "${GH_FAKE_CLOSED_JSON:-}" ] && cat "$GH_FAKE_CLOSED_JSON" || printf '[]\n' ;;
      *) [ -f "${GH_FAKE_ISSUES_JSON:-}" ] && cat "$GH_FAKE_ISSUES_JSON" || printf '[]\n' ;;
    esac ;;
  "issue create") if [ "${GH_FAKE_FAIL:-0}" = "1" ]; then
                    # fleet-ops#5497: simulated gh outage — issue-file.py
                    # must surface this line via its own stderr, and the
                    # backfill must lift it into the summary.
                    echo "gh: simulated API outage (GH_FAKE_FAIL)" >&2; exit 1
                  fi
                  echo "CREATE $*" >> "${GH_CREATE_LOG:-/dev/null}"; echo "https://github.com/Nishfleet/fleet-ops/issues/8001" ;;
  "pr list") [ -f "${GH_FAKE_MERGED_JSON:-}" ] && cat "$GH_FAKE_MERGED_JSON" || printf '[]\n' ;;
  *) exit 0 ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

# Stub panel: PASSes everything.
cat > "$scratch/fakebin/fleet-blind-audit-panel" <<'FAKE_PANEL'
printf '{"verdict":"PASS","reason":"stub pass","loud":false}\n'
FAKE_PANEL
chmod +x "$scratch/fakebin/fleet-blind-audit-panel"

for r in 20260826T100000Z 20260826T110000Z; do
  cat > "$scratch/state/reports/$r/findings.json" <<'JSON'
{"findings":[
  {"rank":1,"title":"alpha breaker crash","body":"Body alpha.","severity":"critical","evidence":"ev-a"},
  {"rank":2,"title":"beta medium miss","body":"Body b.","severity":"medium","evidence":"ev-b"},
  {"rank":3,"title":"gamma carried","body":"Body g.","severity":"low","evidence":"ev-g"},
  {"rank":4,"title":"manual seam: LADDER-WALLED hash=staleprefilter reason=unit-failure","body":"Hand-performed operation.","severity":"high","evidence":"ev-l"},
  {"rank":5,"title":"closed-but-undelivered: issue #4896 closed with no merged PR (#4897)","body":"Body cud-stale.","severity":"high","evidence":"ev-cud-stale"},
  {"rank":6,"title":"closed-but-undelivered: issue #5000 closed with no merged PR (#5001)","body":"Body cud-live.","severity":"high","evidence":"ev-cud-live"}
]}
JSON
  : > "$scratch/state/reports/$r/verdicts.jsonl"
  for t in "alpha breaker crash" "beta medium miss" "gamma carried" "manual seam: LADDER-WALLED hash=staleprefilter reason=unit-failure" "closed-but-undelivered: issue #4896 closed with no merged PR (#4897)" "closed-but-undelivered: issue #5000 closed with no merged PR (#5001)"; do
    printf '%s\n' "$(jq -cn --arg t "$t" '{timestamp:"2026-08-26T10:00:00Z", rank:"1", title:$t, verdict:"PASS", reason:"skipped: max findings 1 reached", issue:"", loud:false}')" >> "$scratch/state/reports/$r/verdicts.jsonl"
  done
done
# gamma already carried by open issue #4242 -> pre-filter drop.
printf '[{"number":4242,"title":"[gap-audit] gamma carried","labels":[]}]\n' > "$scratch/issues.json"
# fleet-ops#5479: the closed list the live gate re-checks — #4896's
# referencing PR #4897 has since merged (stale finding -> drop); #5000's
# referencing PR never merged (still undelivered -> re-file).
cat > "$scratch/closed.json" <<'JSON'
[{"number":4896,"title":"delivered after audit","labels":[],"closedAt":"2026-09-10T08:48:14Z","closedByPullRequestsReferences":[{"number":4897}]},
 {"number":5000,"title":"still dropped","labels":[],"closedAt":"2026-09-10T09:00:00Z","closedByPullRequestsReferences":[{"number":5001}]}]
JSON
printf '[{"number":4897,"mergedAt":"2026-09-10T10:42:09Z"}]\n' > "$scratch/merged.json"

create_log="$scratch/create.log"
: > "$create_log"

# fleet-ops#5475: the canonical-ledger mirror is pointed at a scratch ledger,
# seeded the way the #5466 backfill seeding did — "beta medium miss" already
# sits there as carried_over from an OLD run. The backfill must upsert THAT
# finding_id when it files beta (title-matched, run-independent).
ledger="$scratch/ledger.jsonl"
seed_id=$(python3 -c 'import hashlib; print(hashlib.sha256("fleet-blind-audit|20260820T000000Z|beta medium miss".encode()).hexdigest()[:16])')
printf '%s\n' "$(jq -cn --arg id "$seed_id" \
  '{ts:"2026-08-20T00:00:00Z", source_organ:"fleet-blind-audit", run_id:"20260820T000000Z", finding_id:$id, severity:"medium", title:"beta medium miss", evidence_ref:"file:///seeded", disposition:"carried_over", ref:"audit_fix_pending:blind-audit-cap", reason:"#5466 seeding"}')" \
  > "$ledger"

rc=0
GH_FAKE_ISSUES_JSON="$scratch/issues.json" \
GH_FAKE_CLOSED_JSON="$scratch/closed.json" \
GH_FAKE_MERGED_JSON="$scratch/merged.json" \
PATH="$scratch/fakebin:$PATH" \
  GH_TOKEN="test-no-real-gh" \
  GH_CREATE_LOG="$create_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_REPO_ROOT="$repo_root" \
  AUDIT_PANEL_BIN="$scratch/fakebin/fleet-blind-audit-panel" \
  AUDIT_STATE_DIR="$scratch/state" \
  AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_TRIAGE="$scratch/triage.md" \
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py" \
  FINDINGS_LEDGER_FILE="$ledger" \
  "$bin" --backfill 2026-08-20 >"$scratch/bf.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/bf.log"; fail "backfill exited $rc"; }

s=$(grep -Rl "Backfill summary" "$scratch/state/backfill" 2>/dev/null | head -1; true)
[[ -n "$s" ]] || { grep -c . "$scratch/bf.log" 2>/dev/null; tail -20 "$scratch/bf.log"; fail "no backfill summary written"; }

filed=$(grep -c CREATE "$create_log" 2>/dev/null; true)
[[ "$filed" -eq 3 ]] || { cat "$scratch/bf.log" "$create_log"; fail "expected 3 backfilled issues (alpha + beta + cud-#5000), saw $filed"; }
# fleet-ops#5464: a stale (pre-filter) LADDER-WALLED seam in the persisted
# findings must be re-filtered at reconstruction, not re-filed.
grep -q "LADDER-WALLED" "$create_log" && fail "backfill re-filed an automated-escalation seam (LADDER-WALLED)"
grep -q "auto_escalation_dropped=1" "$scratch/bf.log" || { tail -20 "$scratch/bf.log"; fail "stats must report the auto_escalation drop"; }
# fleet-ops#5479: a closed-but-undelivered finding whose PR has since merged
# must be re-verified out, while a still-undelivered one is re-filed.
grep -q "4896" "$create_log" && fail "backfill re-filed a resolved closed-but-undelivered finding (#4896)"
grep -q "5000" "$create_log" || { cat "$create_log"; fail "still-undelivered finding (#5000) should have been filed"; }
grep -q "cud_resolved_dropped=1" "$scratch/bf.log" || { tail -20 "$scratch/bf.log"; fail "stats must report the resolved cud drop"; }

# (fleet-ops#5475) beta was seeded carried_over from 2026-08-20; the backfill
# filed row must reuse the seeded finding_id (upsert), not fork a new one.
jq -r --arg id "$seed_id" \
  'select(.disposition=="filed" and .finding_id==$id) | .ref' "$ledger" \
  | grep -q '^https://github.com/' \
  || { cat "$scratch/bf.log"; cat "$ledger"; fail "seeded carried_over row (beta) was not upserted to filed by stable finding_id"; }
# alpha had no earlier row: its filed row keeps the FIRST-SIGHTING run.
got_run=$(jq -r 'select(.disposition=="filed" and .title=="alpha breaker crash") | .run_id' "$ledger" | head -1)
[[ "$got_run" == "20260826T100000Z" ]] \
  || fail "alpha filed row should carry first-sighting run 20260826T100000Z (got $got_run)"
# gamma was pre-dropped (open issue #4242 carries it): no filed row for gamma.
[[ -z "$(jq -r 'select(.title=="gamma carried" and .disposition=="filed") | .finding_id' "$ledger")" ]] \
  || fail "gamma was deduped against open issue #4242 but got a filed ledger row"

ok "backfill: reconstruct + dedupe + predrop + file (hermetic)"

# --- fleet-ops#5497 proof 1: the run mutex covers backfill ---------------
# Hold the audit lock, then run --backfill: it must exit 0 fast with the
# no-op log line, WITHOUT reaching the dispatch (no backfill/ dir at all).
rm -rf "$scratch/state2"
mkdir -p "$scratch/state2"
exec 8>>"$scratch/state2/audit.lock"
flock -n 8 || fail "could not hold the audit lock for the mutex proof"
rc2=0
PATH="$scratch/fakebin:$PATH" GH_TOKEN="test-no-real-gh" \
  AUDIT_STATE_DIR="$scratch/state2" AUDIT_PANEL_BIN="$scratch/fakebin/fleet-blind-audit-panel" \
  AUDIT_ALLOW_NONCANONICAL=1 AUDIT_TRIAGE="$scratch/triage2.md" \
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py" \
  "$bin" --backfill 2026-08-20 >"$scratch/lock.log" 2>&1 || rc2=$?
[[ $rc2 == 0 ]] || { cat "$scratch/lock.log"; flock -u 8; fail "locked backfill exited $rc2 (expected fast no-op 0)"; }
grep -q "audit already running (no-op)" "$scratch/lock.log" \
  || { cat "$scratch/lock.log"; flock -u 8; fail "no-op lock line missing from backfill log"; }
[[ ! -d "$scratch/state2/backfill" ]] \
  || { flock -u 8; fail "lock taken after dispatch: backfill dir created while the lock was held"; }
flock -u 8 2>/dev/null || true
exec 8>&-
ok "backfill: second invocation exits fast on the audit.lock mutex"

# --- fleet-ops#5497 proof 2: file-gate failure stderr surfaces -------------
rm -rf "$scratch/stateF"
mkdir -p "$scratch/stateF/reports/20260826T100000Z"
cat > "$scratch/stateF/reports/20260826T100000Z/findings.json" <<'JSON'
{"findings":[
  {"rank":1,"title":"alpha breaker crash","body":"Body alpha.","severity":"critical","evidence":"ev-a"},
  {"rank":2,"title":"beta medium miss","body":"Body b.","severity":"medium","evidence":"ev-b"}
]}
JSON
for t in "alpha breaker crash" "beta medium miss"; do
  printf '%s\n' "$(jq -cn --arg t "$t" '{timestamp:"2026-08-26T10:00:00Z", rank:"1", title:$t, verdict:"PASS", reason:"skipped: cap", issue:"", loud:false}')" >> "$scratch/stateF/reports/20260826T100000Z/verdicts.jsonl"
done
createF="$scratch/createF.log"; : > "$createF"
rcF=1
GH_FAKE_FAIL=1 PATH="$scratch/fakebin:$PATH" GH_TOKEN="test-no-real-gh" \
  GH_CREATE_LOG="$createF" AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_PANEL_BIN="$scratch/fakebin/fleet-blind-audit-panel" \
  AUDIT_STATE_DIR="$scratch/stateF" AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_TRIAGE="$scratch/triageF.md" AUDIT_CARRYOVER_FILE="$scratch/stateF/carryover.jsonl" \
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py" \
  "$bin" --backfill 2026-08-20 >"$scratch/bfF.log" 2>&1 || rcF=$?
[[ $rcF == 1 ]] || fail "failed-file backfill must exit 1 (unfiled>0), saw $rcF"
sF="$(grep -Rl 'Backfill summary' "$scratch/stateF/backfill" 2>/dev/null | head -1; true)"
[[ -n "$sF" ]] || { tail -20 "$scratch/bfF.log"; fail "no summary for failed-file run"; }
grep -q 'File-gate failures: 2' "$sF" || { cat "$sF"; fail "summary must carry the failure COUNT"; }
grep -q 'create failed' "$sF" || { cat "$sF"; fail "summary must carry the first failure stderr (issue-file create failed)"; }
grep -q 'file-fail-stderr(1st of N):' "$scratch/bfF.log" || { tail -30 "$scratch/bfF.log"; fail "log must carry the first failure stderr line"; }
[[ "$(grep -c . "$scratch/stateF/carryover.jsonl" 2>/dev/null || echo 0)" -eq 2 ]] || fail "both failures must land in carry-over"
ok "backfill: failed file-gate surfaces first stderr + count in log/summary"

# --- fleet-ops#5497 proof 3: outage fail-fast (empty open list) ------------
rm -rf "$scratch/state3"
mkdir -p "$scratch/state3/reports/20260826T100000Z" "$scratch/state3/backfill"
cat > "$scratch/state3/reports/20260826T100000Z/findings.json" <<'JSON'
{"findings":[
  {"rank":1,"title":"delta outage proof","body":"Body d.","severity":"high","evidence":"ev-d"},
  {"rank":2,"title":"epsilon outage miss","body":"Body e.","severity":"medium","evidence":"ev-e"}
]}
JSON
for t in "delta outage proof" "epsilon outage miss"; do
  printf '%s\n' "$(jq -cn --arg t "$t" '{timestamp:"2026-08-26T10:00:00Z", rank:"1", title:$t, verdict:"PASS", reason:"skipped: cap", issue:"", loud:false}')" >> "$scratch/state3/reports/20260826T100000Z/verdicts.jsonl"
done
# A previous NON-EMPTY open snapshot (the pre-outage 32KB); today's fetch
# returns [] (unset GH_FAKE_ISSUES_JSON -> the stub prints []).
printf '[{"number":4242,"title":"[gap-audit] earlier finding","labels":[]}]\n' > "$scratch/state3/backfill/open-20260826T090000Z.json"
create3="$scratch/create3.log"; : > "$create3"
rc3=9
PATH="$scratch/fakebin:$PATH" GH_TOKEN="test-no-real-gh" \
  GH_CREATE_LOG="$create3" AUDIT_REPO="Nishfleet/fleet-ops" \
  AUDIT_PANEL_BIN="$scratch/fakebin/fleet-blind-audit-panel" \
  AUDIT_STATE_DIR="$scratch/state3" AUDIT_ALLOW_NONCANONICAL=1 \
  AUDIT_TRIAGE="$scratch/triage3.md" AUDIT_CARRYOVER_FILE="$scratch/state3/carryover3.jsonl" \
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py" \
  "$bin" --backfill 2026-08-20 >"$scratch/bf3.log" 2>&1 || rc3=$?
[[ $rc3 == 1 ]] || { tail -20 "$scratch/bf3.log"; fail "outage backfill must exit 1 (unfiled), saw $rc3"; }
grep -qF 'LOUD [AUDIT-BACKFILL-OUTAGE]' "$scratch/bf3.log" || { tail -20 "$scratch/bf3.log"; fail 'missing LOUD outage line'; }
[[ ! -s "$create3" ]] || { cat "$create3"; fail 'outage must abort filing: no gh issue create calls'; }
s3="$(grep -Rl 'Backfill summary' "$scratch/state3/backfill" 2>/dev/null | head -1; true)"
[[ -n "$s3" ]] && grep -q 'Outage fail-fast' "$s3" || fail 'summary must record the outage abort'
[[ "$(grep -c . "$scratch/state3/carryover3.jsonl" 2>/dev/null || echo 0)" -eq 2 ]] || { tail -20 "$scratch/bf3.log"; fail 'both survivors must go to carry-over'; }
ok "backfill: empty open-issue list after a non-empty snapshot aborts the loop (fail-fast)"
