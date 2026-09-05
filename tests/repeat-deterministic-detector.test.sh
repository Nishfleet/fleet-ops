#!/usr/bin/env bash
# tests/repeat-deterministic-detector.test.sh
#
# Proves the REPEAT-DETERMINISTIC detector without reaching GitHub.
# Replay fixtures: the two loops that burned CI on 2026-08-25 must both
# fire —
#   - "Deploy production" retried an identical hard wrangler error 6x
#     (11:09 -> 14:06).
#   - PR #994 re-entered the 0509 merge queue 6x (19:51 -> 22:21) failing
#     the same assertion every time.
# A quiet fixture (below threshold, outside the 6h window, and same step
# with three DIFFERENT assertions) must stay silent.
# The 0509 split fixture exercises the new top-signatures and event-split
# views — the headline number without decomposition cannot drive action
# (fleet-ops#21).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/repeat-deterministic-detector.mjs"
fixtures="$here/fixtures/repeat-deterministic-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import {
  normalizeAssertion,
  signature,
  extractPrNumber,
  detectRepeatDeterministic,
  selectBlockingRepeats,
  summarizeSignatures,
  summarizeEventSplit,
  renderAlert,
} from "./.github/scripts/repeat-deterministic-detector.mjs";

// normalizeAssertion strips the annotation wrapper and a leading log
// timestamp (in either order) and collapses whitespace, without touching
// the message text. The wrapper regex must handle BOTH `##[error]` (the
// real GitHub format, used by vitest and most actions) and `##error`
// (the bracketless shorthand). fleet-ops#21 names the bracket form
// verbatim; missing it kept the headline diagnostic invisible.
if (normalizeAssertion("##error 2026-08-25T11:09:00.123Z wrangler: ERROR: x") !== "wrangler: ERROR: x") {
  throw new Error("annotation-then-timestamp must normalize");
}
if (normalizeAssertion("11:09:00.123  ##error  some  spaced   msg ") !== "some spaced msg") {
  throw new Error("timestamp-then-annotation must normalize");
}
if (normalizeAssertion("##error plain error") !== "plain error") {
  throw new Error("annotation-only must normalize");
}
if (normalizeAssertion("##[error] AssertionError: expected x to be y") !== "AssertionError: expected x to be y") {
  throw new Error("bracket form ##[error] must normalize — fleet-ops#21 cites it verbatim");
}
if (normalizeAssertion("2026-08-25T17:50:34.8294926Z ##[error]AssertionError: ratchet violations") !== "AssertionError: ratchet violations") {
  throw new Error("timestamp-then-bracket-form must normalize");
}
if (normalizeAssertion("##[warning] deploy warning msg") !== "deploy warning msg") {
  throw new Error("bracket form ##[warning] must normalize");
}
if (normalizeAssertion(null) !== "") throw new Error("null assertion must be empty");

// extractPrNumber: merge-queue head_branch, embedded pull_requests, and
// a plain main branch.
if (extractPrNumber({ head_branch: "gh-readonly-queue/main/pr-994-abc" }) !== 994) {
  throw new Error("queue head_branch must yield 994");
}
if (extractPrNumber({ pull_request_numbers: [7] }) !== 7) {
  throw new Error("pull_request_numbers must yield 7");
}
if (extractPrNumber({ head_branch: "main" }) !== null) {
  throw new Error("main branch must yield null");
}

// signature is the full (repo, workflow, job, step, assertion, event) tuple.
const f = {
  repo: "Nishfleet/0509", workflow: "CI", job: "j", step: "s",
  assertion: "a", run_id: 0, run_url: "u", job_id: null, job_url: "u",
  created_at: "2026-08-25T00:00:00Z", head_sha: "h", event: "pull_request",
};
if (!signature(f).includes("CI") || !signature(f).includes("a")) {
  throw new Error("signature must contain workflow and assertion");
}
if (!signature(f).includes("pull_request")) {
  throw new Error("signature must contain event (issue #21 headline decomposition)");
}
// Same workflow+job+step+assertion, different event -> DIFFERENT signatures
// (so the pull_request vs merge_group split is preserved).
const fPr = { ...f, event: "pull_request" };
const fQ  = { ...f, event: "merge_group" };
if (signature(fPr) === signature(fQ)) {
  throw new Error("signature must split on event (pull_request vs merge_group)");
}
// Null event coerces to "(unknown)" so fixtures without an event still group.
const fNull = { ...f, event: null };
if (!signature(fNull).endsWith("\u241F(unknown)")) {
  throw new Error("null event must coerce to (unknown) so grouping stays deterministic");
}

const base = { ...f, workflow: "CI", job: "codex-node-checks", step: "assert", assertion: "AssertionError: x" };

// 3 within 6h fires; count reflects the group.
const fire = detectRepeatDeterministic([
  { ...base, created_at: "2026-08-25T19:51:00Z", run_id: 1 },
  { ...base, created_at: "2026-08-25T20:30:00Z", run_id: 2 },
  { ...base, created_at: "2026-08-25T22:21:00Z", run_id: 3 },
], { threshold: 3, windowHours: 6 });
if (fire.length !== 1) throw new Error(`expected 1 repeat, got ${fire.length}`);
if (fire[0].count !== 3) throw new Error(`expected count 3, got ${fire[0].count}`);
if (fire[0].first_at !== "2026-08-25T19:51:00Z") throw new Error("first_at mismatch");
if (fire[0].last_at !== "2026-08-25T22:21:00Z") throw new Error("last_at mismatch");

// 2 failures: quiet (below threshold).
const quiet2 = detectRepeatDeterministic([
  { ...base, created_at: "2026-08-25T19:51:00Z", run_id: 1 },
  { ...base, created_at: "2026-08-25T20:30:00Z", run_id: 2 },
], { threshold: 3, windowHours: 6 });
if (quiet2.length !== 0) throw new Error("2 failures must stay quiet");

// 3 failures spanning >6h: quiet (window logic, not just count).
const quietSpan = detectRepeatDeterministic([
  { ...base, created_at: "2026-08-25T00:00:00Z", run_id: 1 },
  { ...base, created_at: "2026-08-25T03:00:00Z", run_id: 2 },
  { ...base, created_at: "2026-08-25T06:30:00Z", run_id: 3 },
], { threshold: 3, windowHours: 6 });
if (quietSpan.length !== 0) throw new Error("3 failures spanning >6h must stay quiet");

// Sliding window: 4 runs where only runs 2,3,4 fit in 6h must still fire.
const slide = detectRepeatDeterministic([
  { ...base, created_at: "2026-08-25T00:00:00Z", run_id: 1 },
  { ...base, created_at: "2026-08-25T05:00:00Z", run_id: 2 },
  { ...base, created_at: "2026-08-25T10:00:00Z", run_id: 3 },
  { ...base, created_at: "2026-08-25T11:00:00Z", run_id: 4 },
], { threshold: 3, windowHours: 6 });
if (slide.length !== 1) throw new Error("sliding window must fire on the in-window triple");

// Same step, different assertions: 3 distinct signatures, each count 1 -> quiet.
const diffAssert = detectRepeatDeterministic([
  { ...base, assertion: "err A", created_at: "2026-08-25T10:00:00Z", run_id: 1 },
  { ...base, assertion: "err B", created_at: "2026-08-25T10:10:00Z", run_id: 2 },
  { ...base, assertion: "err C", created_at: "2026-08-25T10:20:00Z", run_id: 3 },
], { threshold: 3, windowHours: 6 });
if (diffAssert.length !== 0) throw new Error("different assertions must stay quiet");

// Alert copy: names the signature, says re-arm will not help, says classify.
const a = renderAlert(fire[0]);
if (!a.includes("repeat-deterministic")) throw new Error("alert must say repeat-deterministic");
if (!a.includes("re-arm or re-queue will not help")) throw new Error("alert must say re-arm will not help");
if (!a.includes("Classify before retrying")) throw new Error("alert must say classify before retrying");
if (!a.includes("codex-node-checks")) throw new Error("alert must name the job");
if (!a.includes("event=")) throw new Error("alert must name the event for the headline split");

// summarizeSignatures: ranks every distinct signature by count desc, splits
// on event so PR and queue failures of the same assertion are SEPARATE rows
// (the whole point of fleet-ops#21). The most-recent tiebreak is also tested.
const sigs = summarizeSignatures([
  // 6 merge_group failures of assertion A — top row.
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T19:51:00Z", run_id: 1 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T20:18:00Z", run_id: 2 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T20:52:00Z", run_id: 3 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T21:21:00Z", run_id: 4 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T21:54:00Z", run_id: 5 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T22:21:00Z", run_id: 6 },
  // 2 pull_request failures of assertion A — second row, same assertion
  // text but a SEPARATE signature because event differs.
  { ...base, event: "pull_request", assertion: "AssertionError: A", created_at: "2026-08-25T17:15:00Z", run_id: 7 },
  { ...base, event: "pull_request", assertion: "AssertionError: A", created_at: "2026-08-25T19:02:00Z", run_id: 8 },
  // 1 pull_request failure of assertion B — last row, isolated.
  { ...base, event: "pull_request", assertion: "AssertionError: B", created_at: "2026-08-25T18:00:00Z", run_id: 9 },
]);
if (sigs.length !== 3) throw new Error(`summarizeSignatures must yield 3 distinct signatures, got ${sigs.length}`);
if (sigs[0].count !== 6) throw new Error("top signature must be the 6x merge_group cluster");
if (sigs[0].event !== "merge_group") throw new Error("top signature must be the merge_group cluster");
if (sigs[1].count !== 2) throw new Error("second signature must be the 2x pull_request cluster");
if (sigs[1].event !== "pull_request") throw new Error("second signature must be pull_request — split must be preserved");
if (sigs[2].count !== 1) throw new Error("third signature must be the 1x outlier");

// limit clamps to >= 1 and trims output (re-feed a Failure[] input).
const mixedFailures = [
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T20:00:00Z", run_id: 100 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T20:30:00Z", run_id: 101 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T21:00:00Z", run_id: 102 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T21:30:00Z", run_id: 103 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T22:00:00Z", run_id: 104 },
  { ...base, event: "merge_group", assertion: "AssertionError: A", created_at: "2026-08-25T22:30:00Z", run_id: 105 },
  { ...base, event: "pull_request", assertion: "AssertionError: A", created_at: "2026-08-25T18:00:00Z", run_id: 106 },
  { ...base, event: "pull_request", assertion: "AssertionError: A", created_at: "2026-08-25T19:00:00Z", run_id: 107 },
];
const limited = summarizeSignatures(mixedFailures, { limit: 1 });
if (limited.length !== 1) throw new Error("limit must clamp top-signatures output");
if (limited[0].count !== 6) throw new Error("limit must preserve the rank order");

// summarizeEventSplit: pulls rates from total_runs and counts failures per
// event. The PR-vs-queue divergence is the headline diagnostic — it must
// be computed and surfaced even when every individual signature is quiet.
const split = summarizeEventSplit(
  [
    { ...base, event: "merge_group", created_at: "2026-08-25T19:51:00Z", run_id: 1 },
    { ...base, event: "merge_group", created_at: "2026-08-25T20:18:00Z", run_id: 2 },
    { ...base, event: "merge_group", created_at: "2026-08-25T20:52:00Z", run_id: 3 },
    { ...base, event: "merge_group", created_at: "2026-08-25T21:21:00Z", run_id: 4 },
    { ...base, event: "merge_group", created_at: "2026-08-25T21:54:00Z", run_id: 5 },
    { ...base, event: "merge_group", created_at: "2026-08-25T22:21:00Z", run_id: 6 },
    { ...base, event: "pull_request", created_at: "2026-08-25T17:15:00Z", run_id: 7 },
    { ...base, event: "pull_request", created_at: "2026-08-25T19:02:00Z", run_id: 8 },
  ],
  [
    { id: 1, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T19:51:00Z" },
    { id: 2, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T20:18:00Z" },
    { id: 3, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T20:52:00Z" },
    { id: 4, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T21:21:00Z" },
    { id: 5, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T21:54:00Z" },
    { id: 6, event: "merge_group", conclusion: "failure", created_at: "2026-08-25T22:21:00Z" },
    { id: 7, event: "merge_group", conclusion: "success", created_at: "2026-08-25T22:30:00Z" },
    { id: 8, event: "merge_group", conclusion: "success", created_at: "2026-08-25T23:00:00Z" },
    { id: 9, event: "merge_group", conclusion: "success", created_at: "2026-08-25T23:30:00Z" },
    { id: 10, event: "merge_group", conclusion: "success", created_at: "2026-08-26T00:00:00Z" },
    { id: 11, event: "merge_group", conclusion: "success", created_at: "2026-08-26T00:30:00Z" },
    { id: 12, event: "merge_group", conclusion: "success", created_at: "2026-08-26T01:00:00Z" },
    { id: 13, event: "merge_group", conclusion: "success", created_at: "2026-08-26T01:30:00Z" },
    { id: 14, event: "merge_group", conclusion: "success", created_at: "2026-08-26T02:00:00Z" },
    { id: 15, event: "merge_group", conclusion: "success", created_at: "2026-08-26T02:30:00Z" },
    { id: 16, event: "merge_group", conclusion: "success", "created_at": "2026-08-26T03:00:00Z" },
    { id: 17, event: "merge_group", conclusion: "success", created_at: "2026-08-26T03:30:00Z" },
    { id: 18, event: "merge_group", conclusion: "success", created_at: "2026-08-26T04:00:00Z" },
    { id: 19, event: "merge_group", conclusion: "success", created_at: "2026-08-26T04:30:00Z" },
    { id: 20, event: "merge_group", conclusion: "success", created_at: "2026-08-26T05:00:00Z" },
    { id: 21, event: "merge_group", conclusion: "success", created_at: "2026-08-26T05:30:00Z" },
    { id: 22, event: "merge_group", conclusion: "success", created_at: "2026-08-26T06:00:00Z" },
    { id: 23, event: "pull_request", conclusion: "failure", created_at: "2026-08-25T17:15:00Z" },
    { id: 24, event: "pull_request", conclusion: "failure", created_at: "2026-08-25T19:02:00Z" },
    { id: 25, event: "pull_request", conclusion: "success", created_at: "2026-08-25T16:00:00Z" },
    { id: 26, event: "pull_request", conclusion: "success", created_at: "2026-08-25T16:30:00Z" },
    { id: 27, event: "pull_request", conclusion: "success", created_at: "2026-08-25T17:00:00Z" },
    { id: 28, event: "pull_request", conclusion: "success", created_at: "2026-08-25T18:00:00Z" },
    { id: 29, event: "pull_request", conclusion: "success", created_at: "2026-08-25T18:30:00Z" },
    { id: 30, event: "pull_request", conclusion: "success", created_at: "2026-08-25T19:30:00Z" },
    { id: 31, event: "pull_request", conclusion: "success", created_at: "2026-08-25T20:00:00Z" },
    { id: 32, event: "pull_request", conclusion: "success", created_at: "2026-08-25T20:30:00Z" },
    { id: 33, event: "pull_request", conclusion: "success", created_at: "2026-08-25T21:00:00Z" },
    { id: 34, event: "pull_request", conclusion: "success", created_at: "2026-08-25T21:30:00Z" },
    { id: 35, event: "pull_request", conclusion: "success", created_at: "2026-08-25T22:00:00Z" },
    { id: 36, event: "pull_request", conclusion: "success", created_at: "2026-08-25T22:30:00Z" },
    { id: 37, event: "pull_request", conclusion: "success", created_at: "2026-08-25T23:00:00Z" },
    { id: 38, event: "pull_request", conclusion: "success", created_at: "2026-08-25T23:30:00Z" },
    { id: 39, event: "pull_request", conclusion: "success", created_at: "2026-08-26T00:00:00Z" },
    { id: 40, event: "pull_request", conclusion: "success", created_at: "2026-08-26T00:30:00Z" },
    { id: 41, event: "pull_request", conclusion: "success", created_at: "2026-08-26T01:00:00Z" },
    { id: 42, event: "pull_request", conclusion: "success", created_at: "2026-08-26T01:30:00Z" },
    { id: 43, event: "pull_request", conclusion: "success", created_at: "2026-08-26T02:00:00Z" },
    { id: 44, event: "pull_request", conclusion: "success", created_at: "2026-08-26T02:30:00Z" },
    { id: 45, event: "pull_request", conclusion: "success", created_at: "2026-08-26T03:00:00Z" },
    { id: 46, event: "pull_request", conclusion: "success", created_at: "2026-08-26T03:30:00Z" },
    { id: 47, event: "pull_request", conclusion: "success", created_at: "2026-08-26T04:00:00Z" },
    { id: 48, event: "pull_request", conclusion: "success", created_at: "2026-08-26T04:30:00Z" },
    { id: 49, event: "pull_request", conclusion: "success", created_at: "2026-08-26T05:00:00Z" },
    { id: 50, event: "pull_request", conclusion: "success", created_at: "2026-08-26T05:30:00Z" },
  ],
);
const pr = split.rows.find((r) => r.event === "pull_request");
const queue = split.rows.find((r) => r.event === "merge_group");
if (!pr || !queue) throw new Error("event split must include both pull_request and merge_group rows");
if (Math.abs(pr.failure_rate - 2/28) > 1e-9) throw new Error(`PR failure rate must be 2/28, got ${pr.failure_rate}`);
if (Math.abs(queue.failure_rate - 6/22) > 1e-9) throw new Error(`queue failure rate must be 6/22, got ${queue.failure_rate}`);
if (Math.abs(split.divergence_pp - ((6/22) - (2/28)) * 100) > 1e-6) {
  throw new Error(`divergence_pp must be (queue_rate - pr_rate) * 100, got ${split.divergence_pp}`);
}
if (!split.primary || split.primary.pr !== pr || split.primary.queue !== queue) {
  throw new Error("primary must pair PR and queue rows for the headline number");
}

// summarizeEventSplit with no totalRuns: rates still zero, divergence zero,
// primary null. Fixture mode — the report does not lie about a rate it
// never measured.
const splitNoTotal = summarizeEventSplit([
  { ...base, event: "merge_group", created_at: "2026-08-25T19:51:00Z", run_id: 1 },
]);
if (splitNoTotal.rows.length !== 1) throw new Error("no-total split must still emit rows");
if (splitNoTotal.rows[0].failed !== 1) throw new Error("failed count must come from the failure list");
if (splitNoTotal.rows[0].failure_rate !== 0) throw new Error("failure rate must be 0 when total is unknown (no lies)");
if (splitNoTotal.primary !== null) throw new Error("primary must be null when total is unknown");
if (splitNoTotal.divergence_pp !== 0) throw new Error("divergence must be 0 when total is unknown");

// selectBlockingRepeats: the repo-scoped gate contract (fleet-ops#3480).
//   - cross-repo repeat never blocks (a 0509 loop from a fleet-ops gate)
//   - same-repo repeat inside the now-anchored lookback blocks
//   - same-repo repeat outside the now-anchored lookback does not block
//   - same-repo repeat whose fix PR references its tracking issue is excluded
const blk = {
  repo: "Nishfleet/fleet-ops", workflow: "CI", job: "j", step: "s",
  assertion: "a", signature: "sig1", count: 3,
  first_at: "2026-09-05T01:00:00Z", last_at: "2026-09-05T03:00:00Z",
  runs: [], threshold: 3, window_hours: 6, event: "merge_group",
};
const blkNow = Date.parse("2026-09-05T04:00:00Z");
if (selectBlockingRepeats([blk], { ownRepo: "Nishfleet/0509", nowMs: blkNow }).length !== 0) {
  throw new Error("cross-repo repeat must never block");
}
const blkSame = selectBlockingRepeats([blk], { ownRepo: "Nishfleet/fleet-ops", nowMs: blkNow, lookbackHours: 24 });
if (blkSame.length !== 1) throw new Error("same-repo repeat inside the lookback must block");
// lookback 1h -> windowStart 03:00Z; the 03:30Z anchor leaves last_at out of window.
if (selectBlockingRepeats([blk], { ownRepo: "Nishfleet/fleet-ops", nowMs: Date.parse("2026-09-05T04:30:00Z"), lookbackHours: 1 }).length !== 0) {
  throw new Error("same-repo repeat outside the now-anchored lookback must not block");
}
if (selectBlockingRepeats([], { ownRepo: "", nowMs: blkNow }).length !== 0) {
  throw new Error("empty own-repo must not block (unscoped run stays alert-only)");
}
const blkExcluded = selectBlockingRepeats([blk], {
  ownRepo: "Nishfleet/fleet-ops", nowMs: blkNow, lookbackHours: 24,
  prBody: "Fix the flaky step. Fixes #7",
  signatureIssues: [{ signature: "sig1", number: 7 }],
});
if (blkExcluded.length !== 0) throw new Error("fix PR referencing its tracking issue must not block");
const blkWrongFix = selectBlockingRepeats([blk], {
  ownRepo: "Nishfleet/fleet-ops", nowMs: blkNow, lookbackHours: 24,
  prBody: "Fix other thing. Fixes #9999",
  signatureIssues: [{ signature: "sig1", number: 7 }],
});
if (blkWrongFix.length !== 1) throw new Error("fix PR referencing the WRONG issue must still block");

console.log("OK: normalizeAssertion, extractPrNumber, signature, detect (fire/quiet2/quietSpan/slide/diffAssert), renderAlert, summarizeSignatures, summarizeEventSplit, selectBlockingRepeats");
' || fail "pure function tests failed"

# --- replay: Deploy production wrangler loop must fire -----------------------
deploy_json="$(node "$script" --from-json "$fixtures/deploy-production-loop.json" --format json)"
echo "$deploy_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.repeats) || report.repeats.length !== 1) {
  throw new Error(`deploy loop must fire exactly once, got ${JSON.stringify(report.repeats)}`);
}
const r = report.repeats[0];
if (r.workflow !== "Deploy production") throw new Error(`expected workflow Deploy production, got ${r.workflow}`);
if (r.job !== "deploy") throw new Error(`expected job deploy, got ${r.job}`);
if (r.step !== "Deploy to Cloudflare") throw new Error(`expected step Deploy to Cloudflare, got ${r.step}`);
if (!r.assertion.includes("wrangler deploy: ERROR")) throw new Error(`assertion must be the wrangler error, got ${r.assertion}`);
if (r.count !== 6) throw new Error(`expected count 6, got ${r.count}`);
if (r.first_at !== "2026-08-25T11:09:00Z") throw new Error(`first_at mismatch: ${r.first_at}`);
if (r.last_at !== "2026-08-25T14:06:00Z") throw new Error(`last_at mismatch: ${r.last_at}`);
console.log("OK: Deploy production loop fires (6x wrangler error, 11:09 -> 14:06)");
'

# --- replay: 0509 PR #994 merge-queue loop must fire -------------------------
queue_json="$(node "$script" --from-json "$fixtures/merge-queue-loop.json" --format json)"
echo "$queue_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.repeats) || report.repeats.length !== 1) {
  throw new Error(`merge-queue loop must fire exactly once, got ${JSON.stringify(report.repeats)}`);
}
const r = report.repeats[0];
if (r.repo !== "Nishfleet/0509") throw new Error(`expected repo Nishfleet/0509, got ${r.repo}`);
if (r.workflow !== "CI") throw new Error(`expected workflow CI, got ${r.workflow}`);
if (r.job !== "codex-node-checks") throw new Error(`expected job codex-node-checks, got ${r.job}`);
if (!r.assertion.includes("AssertionError")) throw new Error(`assertion must be the AssertionError, got ${r.assertion}`);
if (r.count !== 6) throw new Error(`expected count 6, got ${r.count}`);
if (r.first_at !== "2026-08-25T19:51:00Z") throw new Error(`first_at mismatch: ${r.first_at}`);
if (r.last_at !== "2026-08-25T22:21:00Z") throw new Error(`last_at mismatch: ${r.last_at}`);
console.log("OK: 0509 PR #994 merge-queue loop fires (6x assertion, 19:51 -> 22:21)");
'

# --- replay: quiet fixture must stay silent ----------------------------------
quiet_json="$(node "$script" --from-json "$fixtures/quiet.json" --format json)"
echo "$quiet_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.repeats) || report.repeats.length !== 0) {
  throw new Error(`quiet fixture must stay silent, got ${JSON.stringify(report.repeats)}`);
}
console.log("OK: quiet fixture stays silent (below threshold, outside window, different assertions)");
'

# --- replay: 0509 split fixture (fleet-ops#21) -------------------------------
# The headline diagnostic the issue names: a 0509-shaped sample where one
# signature is 6x on merge_group and a couple of pull_request failures of
# a different signature exist too. Top-signatures ranks the 6x first and
# the event-split surfaces the queue-vs-PR gap. Done-criterion.
split_json="$(node "$script" --from-json "$fixtures/event-split-0509.json" --format json)"
echo "$split_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));

// 1. Top-signatures decomposes the headline: the 6x merge_group cluster
//    must appear as the #1 row, the 2x pull_request cluster as #2, with
//    EVENT visible on each row so the diagnosis is one glance away.
if (!Array.isArray(report.top_signatures) || report.top_signatures.length < 2) {
  throw new Error(`top_signatures must be present and rank the dominant signature first, got ${JSON.stringify(report.top_signatures)}`);
}
const top = report.top_signatures[0];
if (top.count !== 6) throw new Error(`top signature count must be 6, got ${top.count}`);
if (top.event !== "merge_group") throw new Error(`top signature event must be merge_group, got ${top.event}`);
if (!top.assertion.includes("design-system-ratchet")) {
  throw new Error(`top signature must name the assertion, got ${top.assertion}`);
}
if (report.top_signatures[1].event !== "pull_request") {
  throw new Error(`second signature must be pull_request so the split is visible, got ${report.top_signatures[1].event}`);
}

// 2. pull_request vs merge_group failure-rate split is first-class.
//    merge_group is 6/22 = 27.27%, pull_request is 2/28 = 7.14%.
const es = report.event_split;
if (!es || !es.primary) throw new Error("event_split.primary must be computed from total_runs");
const prPct = es.primary.pr.failure_rate * 100;
const queuePct = es.primary.queue.failure_rate * 100;
if (Math.abs(prPct - (2/28) * 100) > 1e-6) throw new Error(`PR rate must be 7.14%, got ${prPct}`);
if (Math.abs(queuePct - (6/22) * 100) > 1e-6) throw new Error(`queue rate must be 27.27%, got ${queuePct}`);
if (Math.abs(es.divergence_pp - (queuePct - prPct)) > 1e-3) {
  throw new Error(`divergence_pp must be queue-pr, got ${es.divergence_pp}`);
}
// Positive divergence says queue-side gap — the semantic-merge-conflict
// signature the issue names. A negative or zero divergence would be the
// "not a queue problem" signal. This fixture must produce >0.
if (!(es.divergence_pp > 0)) {
  throw new Error(`divergence must be > 0 for the 0509 split (queue-side gap), got ${es.divergence_pp}`);
}
console.log("OK: 0509 split fixture — 6x merge_group cluster ranked first, PR=" + prPct.toFixed(2) + "% queue=" + queuePct.toFixed(2) + "% divergence=" + es.divergence_pp.toFixed(2) + "pp");
'

# --- human report copy for the split fixture ---------------------------------
split_human="$(node "$script" --from-json "$fixtures/event-split-0509.json" --format human)"
echo "$split_human" | grep -q "Top failure signatures" || fail "human report must include Top failure signatures section"
echo "$split_human" | grep -q "Event split" || fail "human report must include Event split section"
echo "$split_human" | grep -q "pull_request" || fail "human report must name pull_request in the split"
echo "$split_human" | grep -q "merge_group" || fail "human report must name merge_group in the split"
echo "$split_human" | grep -q "divergence" || fail "human report must name the divergence"

# --- repo-scoped blocking gate (fleet-ops#3480) ------------------------------
# A fleet-ops PR with green fleet-ops tests must NOT be blocked by a 0509
# failure cluster. The detector blocks ONLY signatures in the PR's OWN repo,
# inside the now-anchored lookback, and not excluded by a fix-PR reference.
prbody_tmp="$(mktemp)"

gate_run() { # args: fixture own-repo now [pr-body]
  local extra=()
  if [ "$#" -ge 4 ] && [ -n "$4" ]; then extra=(--pr-body "$4"); fi
  node "$script" --from-json "$1" --block --own-repo "$2" --now "$3" "${extra[@]}" --format json >/dev/null 2>&1
}

# 1. same-repo cluster -> the PR gate FAILS (exit 1).
set +e
gate_run "$fixtures/same-repo-loop.json" "Nishfleet/fleet-ops" "2026-09-05T04:00:00Z"
rc_same=$?
set -e
if [ "$rc_same" -ne 1 ]; then fail "same-repo cluster must exit 1 (block), got $rc_same"; fi

# 2. cross-repo cluster -> advisory only, exit 0: NEVER a failing check for
#    the fleet-ops PR (the deadlock this fix removes). Still reported.
set +e
gate_run "$fixtures/merge-queue-loop.json" "Nishfleet/fleet-ops" "2026-08-25T23:00:00Z"
rc_cross=$?
set -e
if [ "$rc_cross" -ne 0 ]; then fail "cross-repo cluster must exit 0 (advisory), got $rc_cross"; fi

cross_json="$(node "$script" --from-json "$fixtures/merge-queue-loop.json" --block --own-repo Nishfleet/fleet-ops --now 2026-08-25T23:00:00Z --format json)"
echo "$cross_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.repeats) || report.repeats.length !== 1) {
  throw new Error("cross-repo repeat must still be reported (advisory)");
}
if (!Array.isArray(report.blocking) || report.blocking.length !== 0) {
  throw new Error("cross-repo repeat must never block the gate (advisory only)");
}
console.log("OK: cross-repo repeat reported (1) but blocking (0) — exit 0, advisory");
'

# 3. PR body 'Fixes <signature issue>' -> exit 0: the fix PR is not blocked.
printf 'Fix the flaky assert. Fixes #4242\n' > "$prbody_tmp"
set +e
gate_run "$fixtures/same-repo-loop.json" "Nishfleet/fleet-ops" "2026-09-05T04:00:00Z" "$prbody_tmp"
rc_fix=$?
set -e
if [ "$rc_fix" -ne 0 ]; then fail "same-repo cluster with Fixes #4242 must exit 0, got $rc_fix"; fi

# 4. wrong fix reference -> still exit 1 (only the matching tracking issue
#    un-blocks; a passing reference must never weaken the gate).
printf 'Fix other thing. Fixes #9999\n' > "$prbody_tmp"
set +e
gate_run "$fixtures/same-repo-loop.json" "Nishfleet/fleet-ops" "2026-09-05T04:00:00Z" "$prbody_tmp"
rc_wrong=$?
set -e
if [ "$rc_wrong" -ne 1 ]; then fail "same-repo cluster with non-matching Fixes must still exit 1, got $rc_wrong"; fi

# 5. stale same-repo cluster (last failure beyond the now-anchored lookback)
#    -> exit 0: the window is anchored to now, not to the oldest sample.
set +e
gate_run "$fixtures/same-repo-loop.json" "Nishfleet/fleet-ops" "2026-09-06T04:00:00Z"
rc_stale=$?
set -e
if [ "$rc_stale" -ne 0 ]; then fail "stale same-repo cluster (outside now-anchored lookback) must exit 0, got $rc_stale"; fi

rm -f "$prbody_tmp"
echo "OK: repo-scoped blocking gate — same-repo=1 cross-repo=0 Fixes#=0 wrong-Fixes#=1 stale=0"

# --- human report copy for the original repeat fixtures ---------------------
human="$(node "$script" --from-json "$fixtures/deploy-production-loop.json" --format human)"
echo "$human" | grep -q "Repeat-deterministic failure detector" || fail "human report must have a title"
echo "$human" | grep -q "Deploy production" || fail "human report must name the workflow"
echo "$human" | grep -q "wrangler deploy: ERROR" || fail "human report must name the assertion"
echo "$human" | grep -q "re-arm or re-queue will not help" || fail "human report must say re-arm will not help"
echo "$human" | grep -q "Classify before retrying" || fail "human report must say classify before retrying"

echo "OK: repeat-deterministic-detector.mjs fixtures and copy"
