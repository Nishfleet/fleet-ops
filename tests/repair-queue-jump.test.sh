#!/usr/bin/env bash
# tests/repair-queue-jump.test.sh
#
# fleet-ops#5810: a red-main repair PR must not self-deadlock at the tail
# of a merge queue whose group builds fail on the bug it fixes. Offline.
# Proves:
#
#   1. Label gate: isRepairPr matches ONLY the `repair:` prefix; a bare
#      `repair` label, `Repair:` case, and unrelated labels never qualify.
#      isJumpBlocked refuses blocked-by-judge / no-auto-merge even on a
#      repair-labelled PR.
#   2. The 2026-09-12 queue-snapshot unit test: selectRepairJumps over the
#      incident fixture selects #3191 — the repair PR tail-queued behind 13
#      entries whose group builds could not merge — and nothing else.
#   3. Sweep guards: a fresh head -> nothing; a repair PR AT the head ->
#      nothing; an UNMERGEABLE repair entry -> nothing (it needs code work,
#      not a jump); a blocked repair entry -> nothing.
#   4. Mutation shape: the jump mutation carries `jump:true` and the
#      dequeue input field is `id` (verified against the live schema —
#      DequeuePullRequestInput has no pullRequestId).
#   5. CLI drill (stubbed gh, no live writes): `enqueue` on a queued
#      repair PR dequeues then re-enqueues with jump:true and exits 0;
#      `enqueue` on a non-repair PR exits 3 and mutates nothing; `sweep`
#      on a green-but-unqueued repair PR enqueues it with jump:true.
#   6. Heartbeat wiring shape: bin/fleet-heartbeat-tier1 block 2 labels
#      revert/* heads, entry-jumps repair-labelled arms, and block 2b runs
#      the sweep.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/repair-queue-jump.mjs"
fixtures="$here/fixtures/repair-queue-jump"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "helper not found: $script"
node --check "$script" || fail "helper failed node --check"

cd "$repo_root"

# --- 1-3. pure-function unit tests -------------------------------------------
node --input-type=module -e '
import { readFileSync } from "node:fs";
import {
  isRepairPr,
  isJumpBlocked,
  selectRepairJumps,
  HEAD_WAIT_MS_DEFAULT,
  REPAIR_JUMP_MUTATION,
  REPAIR_DEQUEUE_MUTATION,
} from "./.github/scripts/repair-queue-jump.mjs";

const lab = (...names) => ({ nodes: names.map((name) => ({ name })) });

// --- 1. label gate -----------------------------------------------------------
if (!isRepairPr(lab("repair:main-red"))) throw new Error("repair:main-red must qualify");
if (!isRepairPr(lab("dependencies", "repair:alert"))) throw new Error("repair:* among others must qualify");
if (isRepairPr(lab("repair"))) throw new Error("bare `repair` (no colon) must NOT qualify");
if (isRepairPr(lab("Repair:main-red"))) throw new Error("`Repair:` case must NOT qualify — gate is exact");
if (isRepairPr(lab("repair"))) throw new Error("bare repair must NOT qualify");
if (isRepairPr(lab("ci-green"))) throw new Error("unrelated label must NOT qualify");
if (isRepairPr(lab())) throw new Error("no labels must NOT qualify");
if (isRepairPr(null)) throw new Error("null labels must NOT qualify");
if (!isRepairPr([{ name: "repair:main-red" }])) throw new Error("array-of-objects shape must qualify");

if (!isJumpBlocked(lab("blocked-by-judge"))) throw new Error("blocked-by-judge must block");
if (!isJumpBlocked(lab("no-auto-merge"))) throw new Error("no-auto-merge must block");
if (isJumpBlocked(lab("repair:main-red"))) throw new Error("repair label alone must not block");
if (HEAD_WAIT_MS_DEFAULT !== 30 * 60_000) throw new Error("head-wait budget must be 30 min");

// --- 2. the 2026-09-12 incident snapshot selects #3191 -----------------------
const fixture = JSON.parse(readFileSync("tests/fixtures/repair-queue-jump/queue-2026-09-12.json", "utf8"));
const NOW = Date.parse("2026-09-12T05:55:00Z"); // the moment the human jumped it
const sel = selectRepairJumps(fixture, { nowMs: NOW });
if (sel.jumped.length !== 1 || sel.jumped[0].number !== 3191)
  throw new Error(`incident snapshot must select exactly #3191, got ${JSON.stringify(sel.jumped)}`);
if (sel.reason !== "head-stale-jumping-repair") throw new Error(`unexpected reason ${sel.reason}`);
if (sel.waitedMs < 57 * 60_000) throw new Error("head waited ~57min in the incident");

// --- 3. sweep guards ---------------------------------------------------------
// Fresh head -> nothing even though a repair PR is queued behind it.
const fresh = selectRepairJumps(fixture, { nowMs: Date.parse("2026-09-12T05:10:00Z") });
if (fresh.jumped.length !== 0 || fresh.reason !== "head-wait-within-budget")
  throw new Error("fresh head must not jump anything");

// Repair PR AT the head -> nothing (jumping the head is a no-op that burns
// a mutation).
const headRepair = { nodes: [
  { state: "QUEUED", enqueuedAt: "2026-09-12T04:00:00Z", position: 1,
    pullRequest: { id: "PR_r", number: 7, state: "OPEN", labels: lab("repair:main-red") } },
  { state: "QUEUED", enqueuedAt: "2026-09-12T04:05:00Z", position: 2,
    pullRequest: { id: "PR_x", number: 8, state: "OPEN", labels: lab() } },
] };
const hr = selectRepairJumps(headRepair, { nowMs: NOW });
if (hr.jumped.length !== 0) throw new Error("repair PR at head must not be jumped");

// UNMERGEABLE repair entry -> nothing: a jump does not fix unmergeable.
const unmergeable = { nodes: [
  { state: "QUEUED", enqueuedAt: "2026-09-12T04:00:00Z", position: 1,
    pullRequest: { id: "PR_h", number: 1, state: "OPEN", labels: lab() } },
  { state: "UNMERGEABLE", enqueuedAt: "2026-09-12T04:05:00Z", position: 2,
    pullRequest: { id: "PR_r", number: 7, state: "OPEN", labels: lab("repair:main-red") } },
] };
const um = selectRepairJumps(unmergeable, { nowMs: NOW });
if (um.jumped.length !== 0) throw new Error("UNMERGEABLE repair entry must not be jumped");

// Blocked repair entry -> nothing even behind a stale head.
const blocked = { nodes: [
  { state: "QUEUED", enqueuedAt: "2026-09-12T04:00:00Z", position: 1,
    pullRequest: { id: "PR_h", number: 1, state: "OPEN", labels: lab() } },
  { state: "QUEUED", enqueuedAt: "2026-09-12T04:05:00Z", position: 2,
    pullRequest: { id: "PR_r", number: 7, state: "OPEN", labels: lab("repair:main-red", "blocked-by-judge") } },
] };
const bl = selectRepairJumps(blocked, { nowMs: NOW });
if (bl.jumped.length !== 0) throw new Error("blocked-by-judge repair entry must not be jumped");

// Empty queue -> nothing.
if (selectRepairJumps({ nodes: [] }, { nowMs: NOW }).reason !== "queue-empty")
  throw new Error("empty queue must report queue-empty");

// --- 4. mutation shape -------------------------------------------------------
if (!REPAIR_JUMP_MUTATION.includes("jump:true") || !REPAIR_JUMP_MUTATION.includes("enqueuePullRequest"))
  throw new Error("jump mutation must be enqueuePullRequest(jump:true)");
if (!REPAIR_DEQUEUE_MUTATION.includes("input:{id:$prId}") || !REPAIR_DEQUEUE_MUTATION.includes("dequeuePullRequest"))
  throw new Error("dequeue mutation must take input:{id:$prId} — pullRequestId is not a field on DequeuePullRequestInput");
' || fail "pure-function unit tests"
ok "pure functions: label gate, #3191 incident selection, sweep guards, mutation shape"

# --- 5. CLI drills (stubbed gh — no live writes) ------------------------------
scratch="$(mktemp -d -t repair-queue-jump.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
fake="$scratch/fake"
mkdir -p "$fake"

# Fake gh: answers the helper's reads from fixtures, records every call to
# $LOG, and captures mutations. Distinguishes query vs mutation by the
# `query=` arg content.
cat >"$fake/gh" <<'FAKE'
#!/usr/bin/env bash
echo "CALL $*" >>"$GH_CALL_LOG"
for a in "$@"; do
  if [[ "$a" == query=* ]]; then q="${a#query=}"; fi
done
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  if [[ "$q" == mutation* ]]; then
    echo "MUTATION $q" >>"$GH_MUTATION_LOG"
    echo '{}'; exit 0
  fi
  if [[ "$q" == *pullRequest\(number* ]]; then
    cat "$GH_PR_AND_QUEUE_FIXTURE"; exit 0
  fi
  cat "$GH_QUEUE_FIXTURE"; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  cat "$GH_PR_LIST_FIXTURE"; exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  cat "$GH_PR_VIEW_FIXTURE"; exit 0
fi
if [[ "$1" == "pr" && "$2" == "checks" ]]; then
  cat "$GH_CHECKS_FIXTURE"; exit 0
fi
echo "unhandled gh call: $*" >&2; exit 1
FAKE
chmod +x "$fake/gh"

export GH_CALL_LOG="$scratch/calls.log"
export GH_MUTATION_LOG="$scratch/mutations.log"
export GH="$fake/gh"
: >"$GH_CALL_LOG"; : >"$GH_MUTATION_LOG"

# Drill 1: `enqueue` on a repair-labelled PR already queued mid-queue —
# must dequeue(id) then enqueuePullRequest(jump:true) and exit 0.
cat >"$scratch/prq.json" <<'EOF'
{ "data": { "repository": {
  "mergeQueue": { "entries": { "nodes": [
    { "state": "QUEUED", "enqueuedAt": "2026-09-12T04:58:00Z", "position": 1,
      "pullRequest": { "id": "PR_head", "number": 3180, "state": "OPEN", "labels": { "nodes": [] } } },
    { "state": "QUEUED", "enqueuedAt": "2026-09-12T05:52:00Z", "position": 5,
      "pullRequest": { "id": "PR_3191", "number": 3191, "state": "OPEN",
        "labels": { "nodes": [{ "name": "repair:main-red" }] } } }
  ] } },
  "pullRequest": { "id": "PR_3191", "state": "OPEN",
    "labels": { "nodes": [{ "name": "repair:main-red" }] } }
} } }
EOF
export GH_PR_AND_QUEUE_FIXTURE="$scratch/prq.json"

node "$script" enqueue --repo Nishfleet/drill --pr 3191 --apply >/dev/null 2>&1 \
  || fail "enqueue on queued repair PR must exit 0"
grep -q 'dequeuePullRequest(input:{id:$prId})' "$GH_MUTATION_LOG" \
  || fail "queued repair PR must be dequeued first"
grep -q 'enqueuePullRequest(input:{pullRequestId:$prId, jump:true})' "$GH_MUTATION_LOG" \
  || fail "repair PR must be re-enqueued with jump:true"
mut_order="$(cat "$GH_MUTATION_LOG")"
[[ "$mut_order" == *dequeuePullRequest*enqueuePullRequest* ]] \
  || fail "dequeue must precede the jump enqueue"
ok "drill: queued repair PR dequeued + re-enqueued at head (jump:true)"

# Drill 2: `enqueue` on a NON-repair PR — exit 3, zero mutations.
cat >"$scratch/prq-nonrepair.json" <<'EOF'
{ "data": { "repository": {
  "mergeQueue": { "entries": { "nodes": [] } },
  "pullRequest": { "id": "PR_9", "state": "OPEN", "labels": { "nodes": [] } }
} } }
EOF
export GH_PR_AND_QUEUE_FIXTURE="$scratch/prq-nonrepair.json"
: >"$GH_MUTATION_LOG"
rc=0
node "$script" enqueue --repo Nishfleet/drill --pr 9 --apply >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "non-repair PR must exit 3 (got $rc)"
[ ! -s "$GH_MUTATION_LOG" ] || fail "non-repair PR must not mutate"
ok "drill: non-repair PR falls back (rc=3), no mutations"

# Drill 3: `sweep` — green repair PR NOT yet in the queue on a repo whose
# queue head is stale -> direct enqueue(jump:true).
cat >"$scratch/list.json" <<'EOF'
[ { "number": 42, "title": "revert: auto-restore green main", "isDraft": false,
    "labels": [{ "name": "repair:main-red" }] } ]
EOF
cat >"$scratch/view.json" <<'EOF'
{ "id": "PR_42", "state": "OPEN" }
EOF
cat >"$scratch/checks.json" <<'EOF'
[ { "name": "ci", "bucket": "pass", "state": "SUCCESS" } ]
EOF
cat >"$scratch/queue.json" <<'EOF'
{ "data": { "repository": { "mergeQueue": { "entries": { "nodes": [
  { "state": "AWAITING_CHECKS", "enqueuedAt": "2026-09-12T04:58:00Z", "position": 1,
    "pullRequest": { "id": "PR_head", "number": 3180, "state": "OPEN", "labels": { "nodes": [] } } }
] } } } } }
EOF
export GH_PR_LIST_FIXTURE="$scratch/list.json"
export GH_PR_VIEW_FIXTURE="$scratch/view.json"
export GH_CHECKS_FIXTURE="$scratch/checks.json"
export GH_QUEUE_FIXTURE="$scratch/queue.json"
: >"$GH_MUTATION_LOG"
REPAIR_JUMP_NOW_MS="$(date -d '2026-09-12T05:55:00Z' +%s)000" \
  node "$script" sweep --repo Nishfleet/drill --apply >/dev/null 2>&1 \
  || fail "sweep must exit 0"
grep -q 'enqueuePullRequest(input:{pullRequestId:$prId, jump:true})' "$GH_MUTATION_LOG" \
  || fail "green unqueued repair PR must be enqueued with jump:true"
if grep -q 'dequeuePullRequest' "$GH_MUTATION_LOG"; then
  fail "unqueued PR must not be dequeued"
fi
ok "drill: sweep enqueues green unqueued repair PR at head (jump:true)"

# Drill 4: `sweep` — repair PR queued behind a stale head -> dequeue+jump.
cat >"$scratch/queue-queued.json" <<'EOF'
{ "data": { "repository": { "mergeQueue": { "entries": { "nodes": [
  { "state": "AWAITING_CHECKS", "enqueuedAt": "2026-09-12T04:58:00Z", "position": 1,
    "pullRequest": { "id": "PR_head", "number": 3180, "state": "OPEN", "labels": { "nodes": [] } } },
  { "state": "QUEUED", "enqueuedAt": "2026-09-12T05:52:00Z", "position": 3,
    "pullRequest": { "id": "PR_42", "number": 42, "state": "OPEN",
      "labels": { "nodes": [{ "name": "repair:main-red" }] } } }
] } } } } }
EOF
export GH_QUEUE_FIXTURE="$scratch/queue-queued.json"
: >"$GH_MUTATION_LOG"
REPAIR_JUMP_NOW_MS="$(date -d '2026-09-12T05:55:00Z' +%s)000" \
  node "$script" sweep --repo Nishfleet/drill --apply >/dev/null 2>&1 \
  || fail "sweep on queued repair PR must exit 0"
grep -q 'dequeuePullRequest(input:{id:$prId})' "$GH_MUTATION_LOG" \
  || fail "queued repair PR must be dequeued"
grep -q 'jump:true' "$GH_MUTATION_LOG" \
  || fail "queued repair PR must be re-enqueued with jump:true"
ok "drill: sweep jumps repair PR queued behind a stale head"

# Drill 5: `sweep` — no repair PRs -> zero queue queries (budget guard).
cat >"$scratch/list-empty.json" <<'EOF'
[]
EOF
export GH_PR_LIST_FIXTURE="$scratch/list-empty.json"
: >"$GH_CALL_LOG"
node "$script" sweep --repo Nishfleet/drill --apply >/dev/null 2>&1 \
  || fail "sweep with no repair PRs must exit 0"
if grep -q 'api graphql' "$GH_CALL_LOG"; then
  fail "sweep with no repair PRs must not touch the queue endpoint"
fi
ok "drill: no repair PRs -> no merge-queue API spend"

# --- 6. heartbeat wiring shape ------------------------------------------------
hb="$repo_root/bin/fleet-heartbeat-tier1"
grep -q 'repair:main-red' "$hb" || fail "heartbeat must label revert/* heads repair:main-red"
grep -q 'repair-queue-jump.mjs' "$hb" || fail "heartbeat must resolve the repair-jump helper"
grep -q 'REPAIR_JUMP_MJS' "$hb" || fail "heartbeat must define REPAIR_JUMP_MJS"
grep -q '2b. repair-queue-jump sweep' "$hb" || fail "heartbeat must run the 2b sweep"
grep -q 'REPAIR-JUMP at head' "$hb" || fail "heartbeat must entry-jump repair arms"
grep -q 'repair-queue-jump.mjs' libexec/alert-repair-dispatch \
  || fail "alert-repair packet must instruct workers to run the jump helper"
grep -q 'repair:main-red' libexec/alert-repair-dispatch \
  || fail "alert-repair packet must instruct workers to label repair PRs"
grep -q 'repair:main-red' .github/scripts/auto-revert.sh \
  || fail "auto-revert.sh must label its PRs repair:main-red"
ok "wiring: heartbeat label+jump+sweep, alert-repair packet, auto-revert.sh"

echo "ALL TESTS PASSED"
