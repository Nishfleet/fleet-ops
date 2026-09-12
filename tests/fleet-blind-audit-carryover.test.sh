#!/usr/bin/env bash
# tests/fleet-blind-audit-carryover.test.sh
#
# Nish 2026-09-11: a panel-PASS finding must never be dropped again.
#  (a) 12 PASS findings with cap 8 -> 8 filed, 4 carried over, LOUD line
#  (b) next run with 0 new findings -> the 4 carry-over entries filed first
#  (c) a carry-over whose signature matches an open issue is dropped via the
#      fleet-ops#1212 gate (DEDUPED log line), not filed
#  (d) the reviewer packet no longer contains "Max findings to return"
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t fleet-blind-audit-co.XXXXXX)
keep_scratch() { # debug helper without KEEP_SCRATCH the scratch is removed
    if [ "${KEEP_SCRATCH:-}" != 1 ]; then
        rm -rf "$scratch"
    fi
}
trap keep_scratch EXIT INT TERM

mkdir -p "$scratch/fakebin"

# Fake gh: reads the open-issue list from GH_FAKE_ISSUES_JSON if set.
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
        if [ -n "${GH_FAKE_ISSUES_JSON:-}" ] && [ -f "$GH_FAKE_ISSUES_JSON" ]; then
          cat "$GH_FAKE_ISSUES_JSON"
        else
          printf '[]\n'
        fi
        ;;
      create)
        printf 'CREATE %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
        n=$(cat "${GH_FAKE_NUM_FILE:-/dev/null}" 2>/dev/null || echo 0)
        n=$((n + 1))
        [[ -n "${GH_FAKE_NUM_FILE:-}" ]] && printf '%s\n' "$n" > "$GH_FAKE_NUM_FILE"
        echo "https://github.com/Nishfleet/fleet-ops/issues/900$n"
        ;;
      *)
        exit 0
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
  label)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

# Fake pi + fake seatlib so run 0 can take the real reviewer path and build
# an actual packet: a drill run never writes packet.md, so (d) must NOT use
# AUDIT_DRILL. pi is never dispatched (AUDIT_DRY_RUN=1) but preflight needs
# it executable.
cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
cat >/dev/null
FAKE_PI
chmod +x "$scratch/fakebin/pi"
cat > "$scratch/seatlib-fake.sh" <<'FAKE_SEAT_LIB'
# shellcheck shell=bash
litellm_seat() {
    # Args: fail_p fail_m need_capable tried_file — all ignored for the stub.
    printf 'fakeprovider\tfakemodel'
}
FAKE_SEAT_LIB

# Empty seam-evidence fixture (created before run 0, which needs it).
printf '%s\n' '{"candidates":[]}' > "$scratch/empty-seams.json"

# 12 distinct fixture findings, all expected panel-PASS.
findings_file="$scratch/findings-12.json"
{
    printf '{"findings":['
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        [ "$i" -gt 1 ] && printf ','
        printf '{"rank":%d,"title":"carryover probe finding number %d","body":"Body for finding %d.","severity":"high","evidence":"ev-%d"}' "$i" "$i" "$i" "$i"
    done
    printf ']}\n'
} > "$findings_file"

empty_findings="$scratch/findings-empty.json"
printf '{"findings":[]}\n' > "$empty_findings"

# Seed the canonical ledger the way the #5466 backfill seeding did: probe 5
# already sits there as carried_over from an OLD run (2026-08-20 era). When
# run 1 files probe 5, the filed row must reuse THIS finding_id (--match-title
# upsert), not fork a new one from run 1 (fleet-ops#5475).
seed_id=$(python3 -c 'import hashlib; print(hashlib.sha256("fleet-blind-audit|20260101T000000Z|carryover probe finding number 5".encode()).hexdigest()[:16])')
printf '%s\n' "$(jq -cn --arg id "$seed_id" \
  '{ts:"2026-08-20T00:00:00Z", source_organ:"fleet-blind-audit", run_id:"20260101T000000Z", finding_id:$id, severity:"high", title:"carryover probe finding number 5", evidence_ref:"file:///seeded", disposition:"carried_over", ref:"audit_fix_pending:blind-audit-cap", reason:"#5466 seeding"}')" \
  > "$scratch/ledger.jsonl"

plan="$scratch/plan.md"
triage="$scratch/triage.md"
issues_json="$scratch/issues.json"
printf '[]\n' > "$issues_json"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$plan"
: > "$triage"
: > "$scratch/create.log"
printf '0\n' > "$scratch/num"

common_env=(
  PATH="$scratch/fakebin:$PATH"
  GH_TOKEN="test-no-real-gh"
  GH_FAKE_ISSUES_JSON="$issues_json"
  GH_FAKE_NUM_FILE="$scratch/num"
  AUDIT_REPO="Nishfleet/fleet-ops"
  AUDIT_REPO_ROOT="$repo_root"
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel"
  AUDIT_STATE_DIR="$scratch/state"
  AUDIT_PLAN_FILE="$plan"
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py"
  AUDIT_TRIAGE="$triage"
  AUDIT_DRILL=1
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin"
  AUDIT_CARRYOVER_FILE="$scratch/carryover.jsonl"
  AUDIT_ALLOW_NONCANONICAL=1
  # Canonical findings-ledger mirror lands in a scratch ledger so the upsert
  # assertions below are hermetic (fleet-ops#5475).
  FINDINGS_LEDGER_FILE="$scratch/ledger.jsonl"
)

# (d) the reviewer packet no longer says "Max findings to return" —
# proved with a REAL reviewer-path dry run (AUDIT_DRILL=0, fake pi + fake
# seatlib), which builds packet.md without dispatching pi.
rc=0
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-0.log" \
  AUDIT_DRILL=0 \
  AUDIT_PI_BIN="$scratch/fakebin/pi" \
  AUDIT_SEAT_LIB="$scratch/seatlib-fake.sh" \
  AUDIT_PROMPT="$repo_root/prompts/blind-audit.md" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-08-26T06:15:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRY_RUN=1 \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run0.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run0.log"; fail "dry run exited $rc"; }

pkt0=$(find "$scratch/state/reports" -mindepth 2 -maxdepth 2 -name packet.md | head -1)
[[ -n "$pkt0" ]] || { cat "$scratch/run0.log"; fail "reviewer dry run produced no packet.md"; }
if grep -q 'Max findings to return' "$pkt0"; then
  fail "packet still contains 'Max findings to return'"
fi
# The packet must not carry any max-findings instruction at all.
if grep -qiE 'max[- ]findings' "$pkt0"; then
  fail "packet still tells the reviewer a max-findings count"
fi

# ---------------------------------------------------------------- run 1 -----
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-1.log" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-08-26T06:20:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRILL_FINDINGS="$findings_file" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run1.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run1.log"; fail "run 1 exited $rc"; }

[[ -s "$scratch/create-1.log" ]] || fail "run 1 filed nothing"
filed1=$(grep -c CREATE "$scratch/create-1.log"; true)
[[ "$filed1" == "8" ]] || fail "run 1: cap failed; expected 8 filed, saw $filed1"

# (a) 4 carry-over entries in the ledger, oldest run recorded.
co1=$(grep -c . "$scratch/carryover.jsonl"; true)
[[ "$co1" == "4" ]] || fail "run 1: expected 4 carry-over entries, saw $co1"

# (a) LOUD line present in the triage file the heartbeat reads.
grep -q 'LOUD \[AUDIT-BACKLOG\] unfiled_pass=0 carryover_total=4' "$triage" \
  || fail "run 1 triage missing LOUD AUDIT-BACKLOG line: $(cat "$triage")"

# (fleet-ops#5475) canonical-ledger upsert: probe 5 was seeded carried_over
# from an old run; run 1 FILED it, so the ledger must hold a filed row with
# the SEEDED finding_id and an issue URL — never a second id forked from run 1.
jq -r --arg id "$seed_id" \
  'select(.disposition=="filed" and .finding_id==$id) | .ref' "$scratch/ledger.jsonl" \
  | grep -q '^https://github.com/' \
  || fail "run 1: seeded carried_over row (probe 5) was not upserted to filed by stable finding_id"
# The 4 cap-skips were mirrored as carried_over rows of run 1 (the seeded
# row shares the same ref — exclude it by finding_id).
[[ "$(jq -r --arg id "$seed_id" 'select(.disposition=="carried_over" and .ref=="audit_fix_pending:blind-audit-cap" and .finding_id != $id) | .title' "$scratch/ledger.jsonl" | wc -l)" == "4" ]] \
  || fail "run 1: expected 4 mirrored carried_over ledger rows"

# (d) the reviewer packet no longer says "Max findings to return".
d1="$scratch/state/reports/2026_08_26T06_20_00Z"
[ -d "$d1" ] || d1=$(find "$scratch/state/reports" -mindepth 1 -maxdepth 1 -type d | head -1)
# (d) covered above with the dry-run packet: assert no packet remnants here.
if ls "$d1"/packet.md >/dev/null 2>&1 && grep -q 'Max findings to return' "$d1/packet.md"; then
  fail "packet still contains 'Max findings to return'"
fi

# ---------------------------------------------------------------- run 2 -----
# 0 new findings: the 4 carry-over entries are filed first.
rc=0
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-2.log" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-8-26T06:25:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRILL_FINDINGS="$empty_findings" \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run2.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run2.log"; fail "run 2 exited $rc"; }

filed2=$(grep -c . "$scratch/create-2.log" 2>/dev/null; true)
[[ "$filed2" == "4" ]] || { cat "$scratch/run2.log"; fail "run 2: expected the 4 carried-over findings filed, saw $filed2"; }
co2=$(grep -c . "$scratch/carryover.jsonl" 2>/dev/null; true)
[[ "$co2" == "0" ]] || fail "run 2: carry-over ledger should be empty, saw $co2"

# (fleet-ops#5475) each of the 4 carried_over rows must have gained a filed
# row with the SAME finding_id and the ORIGIN run (run 1), i.e. the backlog
# filing upserts the seeded row instead of double-filing a second identity.
run1_dir=$(jq -r 'select(.disposition=="carried_over" and (.title|contains("number 9"))) | .run_id' "$scratch/ledger.jsonl" | head -1)
[[ -n "$run1_dir" ]] || fail "run 2: no carried_over ledger row for probe 9"
for n in 9 10 11 12; do
  cid=$(jq -r --arg t "carryover probe finding number $n" \
    'select(.disposition=="carried_over") | select(.title==$t) | .finding_id' "$scratch/ledger.jsonl" | head -1)
  [[ -n "$cid" ]] || fail "run 2: no carried_over ledger row for probe $n"
  got_run=$(jq -r --arg id "$cid" \
    'select(.disposition=="filed" and .finding_id==$id) | .run_id' "$scratch/ledger.jsonl" | head -1)
  [[ "$got_run" == "$run1_dir" ]] \
    || fail "run 2: probe $n filed row did not upsert carried_over finding_id $cid at origin run $run1_dir (got run_id=$got_run)"
done
# No forked identities: carried_over rows still come from exactly the seeded
# old run and run 1 — run 2 must not have added carried_over rows.
[[ "$(jq -r 'select(.disposition=="carried_over") | .run_id' "$scratch/ledger.jsonl" | sort -u | wc -l)" == "2" ]] \
  || fail "run 2: carried_over ledger rows forked new run identities"
ok "carryover: 12 PASS findings cap 8 -> 8 filed 4 carried, next run 0 new -> 4 carried filed first"

# ---------------------------------------------------------------- run 3 -----
# (c) A carry-over entry whose title matches an open issue is dropped by the
# #1212 gate (commented, not a second issue), with a log line and no CREATE.
printf '[{"number":77,"title":"stale agent-state file","labels":[]}]\n' > "$issues_json"
# Seed the ledger by hand: oldest form of the same problem.
sig_seed=$(python3 -c '
import hashlib, json, re, sys
t = re.sub(r"[^a-z0-9]+", " ", "stale agent-state file".lower()).strip()
print(hashlib.sha256(t.encode()).hexdigest())
')
printf '%s\n' "$(jq -cn --arg s "$sig_seed" '{first_seen:"2026-08-26T00:00:00Z", run:"0000", signature:$s, finding:{rank:"CO",title:"stale agent-state file",body:"Body text.","severity":"high","evidence":"ev-open"}}')" > "$scratch/carryover.jsonl"

rc=0
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-3.log" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-08-26T06:30:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRILL_FINDINGS="$empty_findings" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run3.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run3.log"; fail "run 3 exited $rc"; }

# The same problem is dropped (deduped/resolved) with a log line, never filed.
if grep -q '\[gap-audit\] stale agent-state file' "$scratch/create-3.log" 2>/dev/null; then
  fail "run 3: filed a duplicate the gate should have suppressed"
fi
grep -q 'DEDUPED\|carry-over: resolved' "$scratch/run3.log" \
  || fail "run 3: missing drop log line: $(cat "$scratch/run3.log")"
co3=$(grep -c . "$scratch/carryover.jsonl" 2>/dev/null; true)
[[ "$co3" -eq 0 ]] || fail "run 3: deduped carry-over entry must be removed from the ledger, saw $co3"
# (fleet-ops#5475) the dedupe is mirrored as duplicate_of, never a filed row.
jq -r 'select(.disposition=="duplicate_of") | .title' "$scratch/ledger.jsonl" \
  | grep -qx "stale agent-state file" \
  || fail "run 3: dedupe not mirrored as duplicate_of in the canonical ledger"
ok "carryover: signature carried by an open issue is dropped with a log line, not filed"

# (d) global guard: packet must not cap the reviewer.
if grep -q 'Max findings to return' "$repo_root/prompts/blind-audit.md" "$repo_root/bin/fleet-blind-audit"; then
  fail "the reviewer is still told a Max findings to return cap"
fi

ok "fleet-blind-audit carry-over + cap + backfill-away from packet"
