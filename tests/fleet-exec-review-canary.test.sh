#!/usr/bin/env bash
# tests/fleet-exec-review-canary.test.sh
#
# fleet-ops#537: journal/proof receipt check for Execution IS the review.
# Offline. Live gh is stubbed. Proves:
#   1. --body with Verification: + journalctl -> exit 0.
#   2. --body with run-proof: line -> exit 0.
#   3. --body with Verification: but no run-cue -> exit 1.
#   4. --body with no Verification: -> exit 1 (the skip).
#   5. Scan: worker PR with receipt -> exit 0, EXEC-REVIEW-OK, no file.
#   6. Scan: worker PR without receipt -> exit 0 (observe-to-open), files.
#   7. Scan: human PR without receipt -> exit 0, no file.
#   8. Scan: worker PR outside the window -> quiet.
#   9. Auto-file dedupes the signal key on a second run.
#  10. Broken watch (missing helper / bad fixture) fails loud.
#  11. Contracts: worker.md, heartbeat wiring, MANIFEST, nested CI host,
#      matrix enforced, no bin/exec-review dispatcher.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-exec-review-canary"
lib="$repo_root/lib/exec-review-receipt.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$worker" ]] || fail "missing $worker"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t exec-review-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_EXEC_REVIEW_LIB="$lib"
export FLEET_EXEC_REVIEW_ISSUE_REPO="Nishfleet/fleet-ops"
export FLEET_EXEC_REVIEW_WINDOW_HOURS=24
export FLEET_EXEC_REVIEW_NOW="2026-08-27T00:00:00Z"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"
export GH="$scratch/gh"
export GH_MOCK_STORE="$gh_store"

run_body() {
  local rc
  set +e
  FLEET_EXEC_REVIEW_LIB="$lib" "$bin" --body "$1" >"$scratch/body.out" 2>"$scratch/body.err"
  rc=$?
  set -e
  return "$rc"
}

# --- 1. --body with Verification: + journalctl ------------------------------
printf '%s\n' '## Summary
changed

## Verification:
- journalctl -u fleet-heartbeat.service --since "5 min ago"
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "1: Verification + journalctl must accept ($(cat "$scratch/body.err"))"
grep -q '^OK:' "$scratch/body.out" || fail "1: expected OK line"
ok "1: --body Verification + journalctl accepted"

# --- 2. --body with run-proof: ---------------------------------------------
printf '%s\n' '## Summary
changed
run-proof: journal fleet-heartbeat.service lines below
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "2: run-proof: must accept"
ok "2: --body run-proof: accepted"

# --- 3. --body Verification: without a run-cue ------------------------------
printf '%s\n' '## Summary
changed

## Verification:
- I did the thing.
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "3: Verification without a run-cue must reject"
fi
ok "3: --body Verification without run-cue rejected"

# --- 4. --body with no receipt (the skip) ----------------------------------
printf '%s\n' '## Summary
- changed some files

Closes #537
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "4: missing receipt must reject — gate is broken"
fi
grep -q 'REJECT:' "$scratch/body.err" || fail "4: REJECT missing from stderr"
ok "4: --body with no receipt rejected (the skip drill)"

run_scan() {
  local fixture="$1"
  set +e
  FLEET_EXEC_REVIEW_LIB="$lib" \
  FLEET_EXEC_REVIEW_PR_LIST="$fixture" \
  FLEET_EXEC_REVIEW_FILE="${FLEET_EXEC_REVIEW_FILE:-1}" \
  FLEET_EXEC_REVIEW_NOW="2026-08-27T00:00:00Z" \
  FLEET_EXEC_REVIEW_WINDOW_HOURS=24 \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
    "$bin" >"$scratch/scan.out" 2>"$scratch/scan.err"
  rc=$?
  set -e
  return "$rc"
}

# --- 5. worker PR with receipt -> OK, no file -------------------------------
cat >"$scratch/prs-ok.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 700,
    "title": "feat: with receipt",
    "body": "## Summary\nchanged\n\n## Verification:\n- exit 0\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/700",
    "headRefName": "claim/issue-700",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-ok.json" || fail "5: receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "5: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "5: must not file on a receipt PR"
ok "5: worker PR with receipt is OK, no file"

# --- 6. worker PR without receipt -> observe-to-open, files -----------------
cat >"$scratch/prs-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 701,
    "title": "feat: skipped the run",
    "body": "## Summary\nchanged\n\nCloses #701\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/701",
    "headRefName": "claim/issue-701",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "6: skip PR must stay exit 0 (observe-to-open) ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-SKIP' "$scratch/scan.err" || fail "6: expected EXEC-REVIEW-SKIP"
grep -q 'FILED' "$scratch/scan.err" || fail "6: expected auto-file FILED ($(cat "$scratch/scan.err"))"
grep -rq "signal: exec-review-receipt/Nishfleet/fleet-ops#701" "$gh_store" \
  || fail "6: filed issue missing signal key"
ok "6: worker PR without receipt files (observe-to-open)"

# --- 7. human PR without receipt -> no file ---------------------------------
cat >"$scratch/prs-human.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 702,
    "title": "docs: human",
    "body": "no receipt here",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/702",
    "headRefName": "docs/human",
    "author": {"login": "nish3451", "is_bot": false}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-human.json" || fail "7: human PR must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "7: human PR should be OK (not a worker skip)"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "7: must not file on a human PR"
ok "7: human PR without receipt is ignored"

# --- 8. worker PR outside the window -> quiet -------------------------------
cat >"$scratch/prs-old.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 703,
    "title": "old skip",
    "body": "no receipt",
    "createdAt": "2026-08-20T00:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/703",
    "headRefName": "claim/issue-703",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-old.json" || fail "8: old PR must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "8: old skip should age out"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "8: must not file on an aged-out PR"
ok "8: worker PR outside the window is quiet"

# --- 9. dedup ---------------------------------------------------------------
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "9a: first skip run must exit 0"
grep -q 'FILED' "$scratch/scan.err" || fail "9a: first skip run must file ($(cat "$scratch/scan.err"))"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "9b: second skip run must exit 0"
grep -q 'deduped' "$scratch/scan.err" || fail "9b: second run did not dedupe ($(cat "$scratch/scan.err"))"
grep -rl "signal: exec-review-receipt/" "$gh_store" | wc -l | grep -q "^1$" \
  || fail "9: signal key filed more than once"
ok "9: auto-file dedupes the signal key"

# --- 10. broken watch fails loud -------------------------------------------
set +e
FLEET_EXEC_REVIEW_LIB="$scratch/no-such.py" \
FLEET_EXEC_REVIEW_PR_LIST="$scratch/prs-ok.json" \
FLEET_EXEC_REVIEW_FILE=0 \
FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" >/dev/null 2>"$scratch/broken.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "10a: missing helper should exit 1 (got $rc)"
grep -q "EXEC-REVIEW-BROKEN" "$scratch/broken.err" || fail "10a: missing helper must be LOUD"
ok "10a: missing helper fails loud"

printf 'not-json\n' >"$scratch/bad.json"
set +e
FLEET_EXEC_REVIEW_LIB="$lib" \
FLEET_EXEC_REVIEW_PR_LIST="$scratch/bad.json" \
FLEET_EXEC_REVIEW_FILE=0 \
FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" >/dev/null 2>"$scratch/bad.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "10b: bad fixture should exit 1 (got $rc)"
grep -q "EXEC-REVIEW-BROKEN" "$scratch/bad.err" || fail "10b: bad fixture must be LOUD"
ok "10b: unparseable fixture fails loud"

# --- 11. contracts ----------------------------------------------------------
grep -F -- 'fleet-exec-review-canary' "$worker" >/dev/null \
  || fail "worker.md must tell authors to run bin/fleet-exec-review-canary"
grep -q 'fleet-exec-review-canary' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-exec-review-canary"
grep -q 'exec_review_canary_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate exec_review_canary_rc"
grep -F -- 'exit "$exec_review_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the exec-review watch is broken"
grep -q 'bin/fleet-exec-review-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-exec-review-canary"
grep -q 'lib/exec-review-receipt.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/exec-review-receipt.py"
grep -Fq 'bash "$here/fleet-exec-review-canary.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-execution-is-review" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-execution-is-review must be status=enforced in the matrix"
[[ ! -e "$repo_root/bin/exec-review" ]] \
  || fail "bin/exec-review must not exist (inner loop stays agentic)"
ok "11: contracts: worker.md, heartbeat, MANIFEST, nested CI, matrix enforced, no dispatcher"

echo "OK: fleet-exec-review-canary: receipt gate, skip drill, observe-to-open, dedupe, broken watch"
