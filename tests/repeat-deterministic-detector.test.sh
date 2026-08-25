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
  renderAlert,
} from "./.github/scripts/repeat-deterministic-detector.mjs";

// normalizeAssertion strips the annotation wrapper and a leading log
// timestamp (in either order) and collapses whitespace, without touching
// the message text.
if (normalizeAssertion("##error 2026-08-25T11:09:00.123Z wrangler: ERROR: x") !== "wrangler: ERROR: x") {
  throw new Error("annotation-then-timestamp must normalize");
}
if (normalizeAssertion("11:09:00.123  ##error  some  spaced   msg ") !== "some spaced msg") {
  throw new Error("timestamp-then-annotation must normalize");
}
if (normalizeAssertion("##error plain error") !== "plain error") {
  throw new Error("annotation-only must normalize");
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

// signature is the full (repo, workflow, job, step, assertion) tuple.
const f = {
  repo: "Nishfleet/0509", workflow: "CI", job: "j", step: "s",
  assertion: "a", run_id: 0, run_url: "u", job_id: null, job_url: "u",
  created_at: "2026-08-25T00:00:00Z", head_sha: "h",
};
if (!signature(f).includes("CI") || !signature(f).includes("a")) {
  throw new Error("signature must contain workflow and assertion");
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

console.log("OK: normalizeAssertion, extractPrNumber, signature, detect (fire/quiet2/quietSpan/slide/diffAssert), renderAlert");
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

# --- human report copy -------------------------------------------------------
human="$(node "$script" --from-json "$fixtures/deploy-production-loop.json" --format human)"
echo "$human" | grep -q "Repeat-deterministic failure detector" || fail "human report must have a title"
echo "$human" | grep -q "Deploy production" || fail "human report must name the workflow"
echo "$human" | grep -q "wrangler deploy: ERROR" || fail "human report must name the assertion"
echo "$human" | grep -q "re-arm or re-queue will not help" || fail "human report must say re-arm will not help"
echo "$human" | grep -q "Classify before retrying" || fail "human report must say classify before retrying"

echo "OK: repeat-deterministic-detector.mjs fixtures and copy"
