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
  "issue list") [ -f "$GH_FAKE_ISSUES_JSON" ] && cat "$GH_FAKE_ISSUES_JSON" || printf '[]\n' ;;
  "issue create") echo "CREATE $*" >> "${GH_CREATE_LOG:-/dev/null}"; echo "https://github.com/Nishfleet/fleet-ops/issues/8001" ;;
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
  {"rank":4,"title":"manual seam: LADDER-WALLED hash=staleprefilter reason=unit-failure","body":"Hand-performed operation.","severity":"high","evidence":"ev-l"}
]}
JSON
  : > "$scratch/state/reports/$r/verdicts.jsonl"
  for t in "alpha breaker crash" "beta medium miss" "gamma carried" "manual seam: LADDER-WALLED hash=staleprefilter reason=unit-failure"; do
    printf '%s\n' "$(jq -cn --arg t "$t" '{timestamp:"2026-08-26T10:00:00Z", rank:"1", title:$t, verdict:"PASS", reason:"skipped: max findings 1 reached", issue:"", loud:false}')" >> "$scratch/state/reports/$r/verdicts.jsonl"
  done
done
# gamma already carried by open issue #4242 -> pre-filter drop.
printf '[{"number":4242,"title":"[gap-audit] gamma carried","labels":[]}]\n' > "$scratch/issues.json"

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
PATH="$scratch/fakebin:$PATH" \
  GH_TOKEN="test-no-real-gh" \
  GH_CREATE_LOG="$create_log" \
  AUDIT_REPO="Nishfleet/fleet-ops" \
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
[[ "$filed" -eq 2 ]] || { cat "$scratch/bf.log" "$create_log"; fail "expected 2 backfilled issues (alpha + beta), saw $filed"; }
# fleet-ops#5464: a stale (pre-filter) LADDER-WALLED seam in the persisted
# findings must be re-filtered at reconstruction, not re-filed.
grep -q "LADDER-WALLED" "$create_log" && fail "backfill re-filed an automated-escalation seam (LADDER-WALLED)"
grep -q "auto_escalation_dropped=1" "$scratch/bf.log" || { tail -20 "$scratch/bf.log"; fail "stats must report the auto_escalation drop"; }

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
