#!/usr/bin/env bash
# tests/fleet-blind-audit-carryover-resume.test.sh
#
# fleet-ops#5611 wake: a run killed mid-loop (TimeoutStartSec=45min) used to
# lose every in-loop carry-over resolution because the ledger rewrite only
# ran post-loop. An oversized backlog could then never drain: every run
# re-processed the same entries and timed out again (unit failed daily).
# The fix persists each resolution to a $STATE_DIR sidecar the moment it
# happens and prunes the ledger with it at startup (crash recovery).
#
# This test simulates that killed run: run A fills the ledger (cap), the
# sidecar is then seeded with one resolved signature (the state a killed
# run leaves behind), and run B must (a) prune that entry at startup, (b)
# file only the remaining entries, (c) not re-process the resolved one,
# and (d) reset the sidecar after completing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t fleet-blind-audit-resume.XXXXXX)
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

mkdir -p "$scratch/fakebin"

# Fake gh: empty issue lists (nothing to dedupe against), stub issue create.
cat > "$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
subcmd="${1:-}"
shift || true
case "$subcmd" in
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
        echo "https://github.com/Nishfleet/fleet-ops/issues/910$n"
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

# Fake pi (never dispatched in drill mode) + fake seat-lib for preflight.
cat > "$scratch/fakebin/pi" <<'FAKE_PI'
#!/usr/bin/env bash
cat >/dev/null
FAKE_PI
chmod +x "$scratch/fakebin/pi"
cat > "$scratch/seat-lib-fake.sh" <<'FAKE_SEAT_LIB'
# shellcheck shell=bash
pick_seat() {
    printf 'fakeprovider\tfakemodel'
}
FAKE_SEAT_LIB

printf '%s\n' '{"candidates":[]}' > "$scratch/empty-seams.json"

# 12 distinct findings, cap 8: 8 filed, 4 carried over (probes 9-12).
findings_file="$scratch/findings-12.json"
{
    printf '{"findings":['
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        [ "$i" -gt 1 ] && printf ','
        printf '{"rank":%d,"title":"resume probe finding number %d","body":"Body for finding %d.","severity":"high","evidence":"ev-%d"}' "$i" "$i" "$i" "$i"
    done
    printf ']}\n'
} > "$findings_file"

empty_findings="$scratch/findings-empty.json"
printf '{"findings":[]}\n' > "$empty_findings"

printf '[]\n' > "$scratch/issues.json"
printf 'last-heartbeat: 2026-08-26T05:43:00Z\n' > "$scratch/plan.md"
: > "$scratch/triage.md"
printf '0\n' > "$scratch/num"

common_env=(
  PATH="$scratch/fakebin:$PATH"
  GH_TOKEN="test-no-real-gh"
  GH_FAKE_ISSUES_JSON="$scratch/issues.json"
  GH_FAKE_NUM_FILE="$scratch/num"
  AUDIT_REPO="Nishfleet/fleet-ops"
  AUDIT_REPO_ROOT="$repo_root"
  AUDIT_PANEL_BIN="$repo_root/bin/fleet-blind-audit-panel"
  AUDIT_STATE_DIR="$scratch/state"
  AUDIT_PLAN_FILE="$scratch/plan.md"
  AUDIT_SEAM_LIB="$repo_root/lib/manual-seam-lens.py"
  AUDIT_TRIAGE="$scratch/triage.md"
  AUDIT_DRILL=1
  AUDIT_DRILL_GH_STUB_DIR="$scratch/fakebin"
  AUDIT_CARRYOVER_FILE="$scratch/carryover.jsonl"
  AUDIT_ALLOW_NONCANONICAL=1
  FINDINGS_LEDGER_FILE="$scratch/ledger.jsonl"
)

# ------------------------------------------------------------- run A -------
# 12 findings, cap 8 -> 8 filed, 4 carry-over entries with real signatures.
rc=0
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-a.log" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-08-26T06:20:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRILL_FINDINGS="$findings_file" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run-a.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run-a.log"; fail "run A exited $rc"; }

co_a=$(grep -c . "$scratch/carryover.jsonl" 2>/dev/null; true)
[[ "$co_a" == "4" ]] || { cat "$scratch/run-a.log"; fail "run A: expected 4 carry-over entries, saw $co_a"; }

# A completed run resets the sidecar and files the evidence copy.
[[ ! -s "$scratch/state/carryover-resolved.txt" ]] || fail "run A: sidecar should be reset after a completed run"
report_a=$(find "$scratch/state/reports" -mindepth 2 -maxdepth 2 -name carryover-resolved.txt | head -1)
[[ -n "$report_a" ]] || fail "run A: no evidence copy of resolved signatures in the report dir"

# ------------------------------------------------ simulate a killed run ----
# The sidecar a killed run leaves behind: one resolution appended, the
# ledger NOT yet pruned (rewrite only ran post-loop, pre-fix).
sig1=$(jq -r '.signature' "$scratch/carryover.jsonl" | head -1)
[[ -n "$sig1" ]] || fail "could not read a signature from the seeded ledger"
title1=$(jq -r '.finding.title' "$scratch/carryover.jsonl" | head -1)
printf '%s\n' "$sig1" > "$scratch/state/carryover-resolved.txt"

# ------------------------------------------------------------- run B -------
# Startup recovery must prune the resolved entry before the loop; the run
# then files only the 3 remaining entries (not 4).
rc=0
env "${common_env[@]}" \
  GH_CREATE_LOG="$scratch/create-b.log" \
  AUDIT_DELIBERATE_STATES="$repo_root/docs/deliberate-states.md" \
  AUDIT_FAKE_NOW="2026-08-26T06:25:00Z" \
  AUDIT_MAX_FINDINGS="8" \
  AUDIT_DRILL_FINDINGS="$empty_findings" \
  AUDIT_SEAM_EVIDENCE="$scratch/empty-seams.json" \
  "$repo_root/bin/fleet-blind-audit" >"$scratch/run-b.log" 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat "$scratch/run-b.log"; fail "run B exited $rc"; }

grep -q 'crash-recovery prune applied (4 -> 3 entries' "$scratch/run-b.log" \
  || { cat "$scratch/run-b.log"; fail "run B: startup crash-recovery prune did not run (expected 4 -> 3)"; }

filed_b=$(grep -c . "$scratch/create-b.log" 2>/dev/null; true)
[[ "$filed_b" == "3" ]] || { cat "$scratch/run-b.log"; fail "run B: expected only the 3 un-resolved entries filed, saw $filed_b"; }

if grep -qF "$title1" "$scratch/create-b.log"; then
  fail "run B: re-filed '$title1' although a prior (killed) run already resolved it"
fi

co_b=$(grep -c . "$scratch/carryover.jsonl" 2>/dev/null; true)
[[ "$co_b" == "0" ]] || fail "run B: carry-over ledger should be empty after filing the backlog, saw $co_b"

[[ ! -s "$scratch/state/carryover-resolved.txt" ]] || fail "run B: sidecar should be reset after a completed run"

ok "resume: killed run's resolution survives — ledger pruned 4->3, only 3 re-filed, resolved entry never re-processed"
ok "fleet-blind-audit-carryover-resume.test.sh"
