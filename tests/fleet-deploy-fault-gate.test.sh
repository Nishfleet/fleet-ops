#!/usr/bin/env bash
# tests/fleet-deploy-fault-gate.test.sh
#
# fleet-ops#5785: a deploy-fault issue (deploy-fault label, or a body citing
# a failed `Deploy production` run) must not close — and must not STAY
# closed — without a green production-deploy run whose SHA contains the fix.
#
# The replay this test exists for (accept criterion 1): 0509#2662 was closed
# the moment PR #2949 (head claim/issue-2662, merge 150e9101...) merged at
# 2026-09-11T14:49:43Z — GitHub auto-close on the merge — while every
# `Deploy production` run since 2026-09-09T17:03Z was still failing Gate C.
# No organ prevented it and nothing reopened it; production stayed red
# ~2.5 days while halt issues piled up.
#
# Proven here, hermetically (mocked gh, no network, no systemd):
#   1. REPLAY: the #2662 shape (closed, claim-branch delivery merged, every
#      run red) -> lifecycle-label-sweep reopens it + applies deploy-fault.
#   2. A closed deploy-fault issue WITH a green run containing the merge SHA
#      stays closed.
#   3. A green run whose SHA does NOT contain the fix is not proof -> reopen.
#   4. stateReason NOT_PLANNED -> never reopened.
#   5. An open issue whose body cites a failed run gets the deploy-fault
#      label (class legibility, orthogonal to lifecycle labels).
#   6. CLOSE GATE: observe-to-close leaves a delivered deploy-fault issue
#      OPEN while no green run contains the fix (deduped gate note), and
#      closes it once a green run contains the merge SHA — with the run URL
#      in the closing comment.
#   7. A green run not containing the fix -> gate holds (no close).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
sweep="$repo_root/bin/lifecycle-label-sweep"
closer="$repo_root/bin/fleet-merged-pr-close"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$sweep" ]] || fail "not executable: $sweep"
[[ -x "$closer" ]] || fail "not executable: $closer"
bash -n "$sweep" "$closer" "$repo_root/lib/deploy-fault-gate.sh" \
    || fail "bash -n failed"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/bin"

# --- shared fake gh --------------------------------------------------------
# Serves fixtures from $FAKE_DIR:
#   open.json / closed.json        issue list --state open|closed
#   comments-<num>.txt             issue view --json comments -> {"comments":[{"body":...}]}
#   merged.json                    pr list --state merged (all fields)
#   merged-head-<num>.json         pr list --head claim/issue-<num> --state merged
#   open-head-<num>.json           pr list --head claim/issue-<num> --state open
#   runs-green.json                run list --status success
#   run-<id>.json                  run view <id>
#   compare-status                 api repos/*/compare/<a>...<b> -> {"status": X}
#   ahead-by                       api ...compare/...claim/issue-* -> {"ahead_by": N}
#   ref-exists                     when present, git/refs/heads/claim/* exists
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
state=""
prev=""
head=""
for a in "$@"; do
  case "$prev" in
    --state) state="$a" ;;
    --head)  head="$a" ;;
  esac
  prev="$a"
done
case "$1" in
  issue)
    case "$2" in
      list)
        if [ "$state" = "closed" ]; then
          cat "$FAKE_DIR/closed.json" 2>/dev/null || echo '[]'
        else
          cat "$FAKE_DIR/open.json" 2>/dev/null || echo '[]'
        fi
        exit 0
        ;;
      view)
        num="$3"
        f="$FAKE_DIR/comments-${num}.json"
        if [ -f "$f" ]; then cat "$f"; else echo '{"comments":[]}'; fi
        exit 0
        ;;
      close)   printf '%s\n' "$*" >>"$FAKE_DIR/closes.log";   exit 0 ;;
      reopen)  printf '%s\n' "$*" >>"$FAKE_DIR/reopens.log";  exit 0 ;;
      comment) printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"; exit 0 ;;
      edit)    printf '%s\n' "$*" >>"$FAKE_DIR/edits.log";    exit 0 ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  label)
    printf '%s\n' "$*" >>"$FAKE_DIR/labels.log"
    exit 0
    ;;
  pr)
    case "$2" in
      list)
        if [ -n "$head" ]; then
          num="${head#claim/issue-}"
          if [ "$state" = "open" ]; then
            cat "$FAKE_DIR/open-head-${num}.json" 2>/dev/null || echo '[]'
          else
            cat "$FAKE_DIR/merged-head-${num}.json" 2>/dev/null || echo '[]'
          fi
        else
          cat "$FAKE_DIR/merged.json" 2>/dev/null || echo '[]'
        fi
        exit 0
        ;;
      *) echo "unexpected gh pr $*" >&2; exit 1 ;;
    esac
    ;;
  run)
    case "$2" in
      list) cat "$FAKE_DIR/runs-green.json" 2>/dev/null || echo '[]'; exit 0 ;;
      view)
        f="$FAKE_DIR/run-$3.json"
        if [ -f "$f" ]; then cat "$f"; else echo "run $3 not found" >&2; exit 1; fi
        exit 0
        ;;
      *) echo "unexpected gh run $*" >&2; exit 1 ;;
    esac
    ;;
  api)
    endpoint="$2"
    case "$endpoint" in
      *git/refs*)
        if [ -f "$FAKE_DIR/ref-exists" ]; then echo '{"ref":"x"}'; else exit 1; fi
        ;;
      *compare/*claim/issue-*)
        printf '{"ahead_by":%s}\n' "$(cat "$FAKE_DIR/ahead-by" 2>/dev/null || echo 0)"
        ;;
      *compare/*)
        printf '{"status":"%s"}\n' "$(cat "$FAKE_DIR/compare-status" 2>/dev/null || echo diverged)"
        ;;
      repos/*)
        echo '{"default_branch":"main"}'
        ;;
      *) echo "unexpected gh api $endpoint" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# systemctl stub: no live workers.
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$scratch/bin/systemctl"

export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
export GH_TOKEN="test-stub"          # fleet-ops#3445: skip the App mint
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"
export LIFECYCLE_SWEEP_NOW="2026-09-12T00:00:00Z"
export LIFECYCLE_SWEEP_SUMMARY="$scratch/lifecycle-sweep.json"
export MERGED_PR_CLOSE_REPOS="Nishfleet/0509"
export MERGED_PR_CLOSE_NOW="2026-09-12T00:00:00Z"
export MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md"
export MERGED_PR_CLOSE_SUMMARY="$scratch/merged-pr-close.json"
export ATTEMPTS_DIR="$scratch/attempts"
unset LIFECYCLE_SWEEP_DRILL || true

# The 0509#2662 body, abridged to the cited-failure shape (deploy-production
# workflow name + failure wording + run IDs).
BODY_2662='Every release run since 2026-09-09T17:03Z has failed, so no release can be reported green and every release auto-rolls the Worker back.

**Observed (2026-09-10T18:28Z run 34514527796, main 8fb670b8):** the `Deploy` step is the failing step. The Gate C evidence object is not in R2 and the post-deploy release verifier exits non-zero; the release is rolled back.

$ gh run list -R Nishfleet/0509 --workflow deploy-production.yml --status success --limit 1
2026-09-09T17:03:16Z success d16b1f00'

reset_fake() {
    : >"$scratch/gh.log"; : >"$scratch/closes.log"; : >"$scratch/reopens.log"
    : >"$scratch/comments.log"; : >"$scratch/edits.log"; : >"$scratch/labels.log"
    echo '[]' >"$scratch/open.json"; echo '[]' >"$scratch/closed.json"
    echo '[]' >"$scratch/merged.json"; echo '[]' >"$scratch/runs-green.json"
    rm -f "$scratch"/comments-*.json "$scratch"/merged-head-*.json \
          "$scratch"/open-head-*.json "$scratch"/run-*.json \
          "$scratch"/compare-status "$scratch"/ahead-by "$scratch"/ref-exists
}

# =========================================================================
# 1. REPLAY 0509#2662/#2949 — closed deploy-fault, delivery merged, all runs
#    red -> lifecycle sweep REOPENS it and applies deploy-fault.
# =========================================================================
reset_fake
python3 - "$BODY_2662" <<'PY' >"$scratch/closed.json"
import json, sys
print(json.dumps([{
    "number": 2662,
    "title": "release pipeline has failed on every run since 2026-09-09T17:03Z",
    "state": "CLOSED", "stateReason": "COMPLETED",
    "closedAt": "2026-09-11T14:49:45Z",
    "author": {"login": "app/nishfleet-worker"},
    "labels": [{"name": "bug"}, {"name": "agent-in-progress"},
               {"name": "priority"}, {"name": "critical-path"}],
    "body": sys.argv[1],
}]))
PY
# Delivery: PR #2949 on claim/issue-2662, merge commit 150e9101...
cat >"$scratch/merged-head-2662.json" <<'JSON'
[{"number": 2949, "mergeCommit": {"oid": "150e9101d1ee2abddd680d02aa1d03ce1838471f"}}]
JSON
# Every post-merge Deploy production run is still red -> no green runs at all.
echo '[]' >"$scratch/runs-green.json"

out=$("$sweep" 2>"$scratch/err1.txt")
grep -q 'deploy_fault_reopened=1' <<<"$out" \
    || fail "replay: expected deploy_fault_reopened=1, got: $out"
grep -q 'reopen 2662' "$scratch/reopens.log" \
    || fail "replay: gh issue reopen 2662 not called: $(cat "$scratch/reopens.log")"
grep -q 'deploy-fault-gate (fleet-ops#5785)' "$scratch/reopens.log" \
    || fail "replay: reopen comment must carry the deploy-fault-gate marker"
grep -q 'add-label deploy-fault' "$scratch/edits.log" \
    || fail "replay: deploy-fault label not applied: $(cat "$scratch/edits.log")"
python3 -c "import json,sys; d=json.load(open('$scratch/lifecycle-sweep.json')); assert d['deploy_fault_closed_without_green']==1, d" \
    || fail "replay: summary deploy_fault_closed_without_green must be 1"
ok "REPLAY 0509#2662/#2949: closed-without-green deploy-fault issue reopened + labelled"

# =========================================================================
# 2. Green run containing the merge SHA -> stays closed.
# =========================================================================
reset_fake
python3 - "$BODY_2662" <<'PY' >"$scratch/closed.json"
import json, sys
print(json.dumps([{
    "number": 2662, "title": "release pipeline failed", "state": "CLOSED",
    "stateReason": "COMPLETED", "closedAt": "2026-09-11T14:49:45Z",
    "author": {"login": "app/nishfleet-worker"},
    "labels": [{"name": "deploy-fault"}],
    "body": sys.argv[1],
}]))
PY
cat >"$scratch/merged-head-2662.json" <<'JSON'
[{"number": 2949, "mergeCommit": {"oid": "150e9101d1ee2abddd680d02aa1d03ce1838471f"}}]
JSON
cat >"$scratch/runs-green.json" <<'JSON'
[{"databaseId": 9999, "headSha": "beef9999", "createdAt": "2026-09-11T16:00:00Z",
  "url": "https://github.com/Nishfleet/0509/actions/runs/9999"}]
JSON
echo "ahead" >"$scratch/compare-status"   # 150e9101 is an ancestor of beef9999

out=$("$sweep" 2>"$scratch/err2.txt")
grep -q 'deploy_fault_reopened=0' <<<"$out" \
    || fail "proven: must not reopen when a green run contains the fix: $out"
[ ! -s "$scratch/reopens.log" ] \
    || fail "proven: reopen must not fire: $(cat "$scratch/reopens.log")"
ok "green run containing the delivery merge -> close stands"

# =========================================================================
# 3. Green run NOT containing the fix -> still reopened.
# =========================================================================
reset_fake
python3 - "$BODY_2662" <<'PY' >"$scratch/closed.json"
import json, sys
print(json.dumps([{
    "number": 2662, "title": "release pipeline failed", "state": "CLOSED",
    "stateReason": "COMPLETED", "closedAt": "2026-09-11T14:49:45Z",
    "author": {"login": "app/nishfleet-worker"},
    "labels": [{"name": "deploy-fault"}],
    "body": sys.argv[1],
}]))
PY
cat >"$scratch/merged-head-2662.json" <<'JSON'
[{"number": 2949, "mergeCommit": {"oid": "150e9101d1ee2abddd680d02aa1d03ce1838471f"}}]
JSON
cat >"$scratch/runs-green.json" <<'JSON'
[{"databaseId": 8888, "headSha": "cafe0000", "createdAt": "2026-09-11T16:00:00Z",
  "url": "https://github.com/Nishfleet/0509/actions/runs/8888"}]
JSON
echo "behind" >"$scratch/compare-status"  # the green run predates the fix

out=$("$sweep" 2>"$scratch/err3.txt")
grep -q 'deploy_fault_reopened=1' <<<"$out" \
    || fail "non-containing green run is not proof — must reopen: $out"
ok "green run NOT containing the fix -> reopened (SHA must contain the fix)"

# =========================================================================
# 4. stateReason NOT_PLANNED -> never reopened.
# =========================================================================
reset_fake
python3 - "$BODY_2662" <<'PY' >"$scratch/closed.json"
import json, sys
print(json.dumps([{
    "number": 2662, "title": "release pipeline failed", "state": "CLOSED",
    "stateReason": "NOT_PLANNED", "closedAt": "2026-09-11T14:49:45Z",
    "author": {"login": "app/nishfleet-worker"},
    "labels": [{"name": "deploy-fault"}],
    "body": sys.argv[1],
}]))
PY
out=$("$sweep" 2>"$scratch/err4.txt")
grep -q 'deploy_fault_reopened=0' <<<"$out" \
    || fail "not-planned must never be reopened: $out"
ok "stateReason=NOT_PLANNED -> untouched (deliberate non-fix is legal)"

# =========================================================================
# 5. Open issue citing a failed run -> deploy-fault label applied.
# =========================================================================
reset_fake
python3 - "$BODY_2662" <<'PY' >"$scratch/open.json"
import json, sys
print(json.dumps([{
    "number": 3000, "title": "release pipeline red again",
    "labels": [{"name": "agent-in-progress"}],
    "createdAt": "2026-09-11T00:00:00Z",
    "body": sys.argv[1],
}]))
PY
out=$("$sweep" 2>"$scratch/err5.txt")
grep -q 'deploy_fault_labeled=1' <<<"$out" \
    || fail "label pass: expected deploy_fault_labeled=1, got: $out"
grep -q 'add-label deploy-fault' "$scratch/edits.log" \
    || fail "label pass: --add-label deploy-fault not issued"
ok "open issue citing a failed production run -> deploy-fault label applied"

# =========================================================================
# 6. CLOSE GATE: delivered deploy-fault issue, no green run -> stays open.
# =========================================================================
reset_fake
python3 - <<'PY' >"$scratch/open.json"
import json
print(json.dumps([{
    "number": 4001, "title": "deploy-fault issue",
    "labels": [{"name": "deploy-fault"}, {"name": "agent-in-progress"}],
    "author": {"login": "app/nishfleet-worker"},
    "body": "tracking the failed Deploy production runs",
}]))
PY
cat >"$scratch/merged.json" <<'JSON'
[{"number": 77, "title": "fix it", "body": "work",
  "mergedAt": "2026-09-11T20:00:00Z",
  "url": "https://github.com/Nishfleet/0509/pull/77",
  "headRefName": "claim/issue-4001",
  "mergeCommit": {"oid": "deadbeef01"}}]
JSON
cat >"$scratch/merged-head-4001.json" <<'JSON'
[{"number": 77, "mergeCommit": {"oid": "deadbeef01"}}]
JSON
echo '[]' >"$scratch/runs-green.json"

out=$(env FLEET_MERGED_PR_CLOSE_OK=1 "$closer" 2>&1)
grep -q 'skipped_deploy_fault=1' <<<"$out" \
    || fail "gate: expected skipped_deploy_fault=1, got: $out"
[ ! -s "$scratch/closes.log" ] \
    || fail "gate: issue must NOT close without green proof: $(cat "$scratch/closes.log")"
grep -q 'deploy-fault-gate (fleet-ops#5785)' "$scratch/comments.log" \
    || fail "gate: deduped gate note must be posted: $(cat "$scratch/comments.log")"
ok "close gate: delivered deploy-fault issue stays open while production red"

# =========================================================================
# 7. Green run containing the fix SHA -> gate passes, closing comment cites
#    the run URL.
# =========================================================================
reset_fake
python3 - <<'PY' >"$scratch/open.json"
import json
print(json.dumps([{
    "number": 4001, "title": "deploy-fault issue",
    "labels": [{"name": "deploy-fault"}, {"name": "agent-in-progress"}],
    "author": {"login": "app/nishfleet-worker"},
    "body": "tracking the failed Deploy production runs",
}]))
PY
cat >"$scratch/merged.json" <<'JSON'
[{"number": 77, "title": "fix it", "body": "work",
  "mergedAt": "2026-09-11T20:00:00Z",
  "url": "https://github.com/Nishfleet/0509/pull/77",
  "headRefName": "claim/issue-4001",
  "mergeCommit": {"oid": "deadbeef01"}}]
JSON
cat >"$scratch/merged-head-4001.json" <<'JSON'
[{"number": 77, "mergeCommit": {"oid": "deadbeef01"}}]
JSON
cat >"$scratch/runs-green.json" <<'JSON'
[{"databaseId": 9999, "headSha": "deadbeef99", "createdAt": "2026-09-11T21:00:00Z",
  "url": "https://github.com/Nishfleet/0509/actions/runs/9999"}]
JSON
echo "ahead" >"$scratch/compare-status"   # deadbeef01 is in deadbeef99's history

out=$(env FLEET_MERGED_PR_CLOSE_OK=1 "$closer" 2>&1)
grep -q 'skipped_deploy_fault=0' <<<"$out" \
    || fail "gate: green run containing fix must pass the gate: $out"
grep -q 'close 4001' "$scratch/closes.log" \
    || fail "gate: issue must close once production is green: $(cat "$scratch/closes.log")"
grep -q 'actions/runs/9999' "$scratch/closes.log" \
    || fail "gate: closing comment must cite the green run URL: $(cat "$scratch/closes.log")"
ok "close gate: green run containing the fix -> closes with run URL in the comment"

echo
echo "all fleet-deploy-fault-gate tests passed"
