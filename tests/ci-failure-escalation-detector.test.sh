#!/usr/bin/env bash
# tests/ci-failure-escalation-detector.test.sh
#
# Proves the CI-failure -> senior-auditor escalation bridge (fleet-ops#221)
# without reaching GitHub. The detector's pure functions + a fixture-replay
# mode (--from-json) cover every acceptance bullet in the issue:
#
#   1. inject a failing check on a drill branch twice -> one escalation
#      issue filed with context (drill-branch-twice.json).
#   2. auto-revert-handled failure (CI on main, push) -> NO escalation
#      (auto-revert-handled.json).
#   3. #124-redispatch-handled failure (claim/issue-* branch) -> NO
#      escalation (claim-branch-handled.json).
#   4. signature bound respected: one escalation per signature per 6h,
#      deduped against open escalate-senior issues (deduped.json).
#   5. below threshold (a single transient red) -> quiet
#      (below-threshold.json).
#   6. window bound: two failures spanning >6h with no dense sub-window ->
#      quiet (window-span.json).
#
# Fixture mode makes NO gh calls, so the inner loop runs anywhere.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/ci-failure-escalation-detector.mjs"
fixtures="$here/fixtures/ci-failure-escalation-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import { readFileSync as _readFileSync } from "node:fs";
import {
  normalizeAssertion,
  extractPrNumber,
  signature,
  signatureHash,
  isAutoRevertHandled,
  isRedPrRepairHandled,
  detectEscalations,
  findLastGreen,
  isDuplicated,
  renderIssueTitle,
  renderIssueBody,
  parseEnrolledRepos,
} from "./.github/scripts/ci-failure-escalation-detector.mjs";

// normalizeAssertion mirrors repeat-deterministic so a signature is stable
// across real logs and fixtures.
if (normalizeAssertion("##[error] AssertionError: x") !== "AssertionError: x") throw new Error("bracket form must normalize");
if (normalizeAssertion("2026-08-25T17:50:34.829Z ##[error]AssertionError: ratchet") !== "AssertionError: ratchet") throw new Error("timestamp+bracket must normalize");
if (normalizeAssertion(null) !== "") throw new Error("null must be empty");

// extractPrNumber: merge-queue head_branch + embedded pull_requests.
if (extractPrNumber({ head_branch: "gh-readonly-queue/main/pr-994-abc" }) !== 994) throw new Error("queue branch must yield 994");
if (extractPrNumber({ pull_request_numbers: [7] }) !== 7) throw new Error("pull_request_numbers must yield 7");
if (extractPrNumber({ head_branch: "main" }) !== null) throw new Error("main must yield null");

// signature splits on event so PR and merge_group failures of the same
// assertion are SEPARATE escalations (different owners / fixes).
const base = { repo: "Nishfleet/0509", workflow: "CI", job: "j", step: "s", assertion: "a", run_id: 0, run_url: "u", job_id: null, job_url: "u", created_at: "2026-08-26T00:00:00Z", head_branch: "b", head_sha: "h", pr: null };
if (signature({ ...base, event: "pull_request" }) === signature({ ...base, event: "merge_group" })) {
  throw new Error("signature must split on event");
}
// hash is a stable sha256 hex.
const h = signatureHash(signature({ ...base, event: "pull_request" }));
if (!/^[0-9a-f]{64}$/.test(h)) throw new Error("hash must be sha256 hex");
if (signatureHash(signature({ ...base, event: "pull_request" })) !== h) throw new Error("hash must be deterministic");

// auto-revert owns CI-on-main push failures only.
if (!isAutoRevertHandled({ workflow: "CI", event: "push", head_branch: "main" })) throw new Error("CI push main must be auto-revert-handled");
if (isAutoRevertHandled({ workflow: "CI", event: "pull_request", head_branch: "main" })) throw new Error("pull_request on main is NOT auto-revert (it is a PR check)");
if (isAutoRevertHandled({ workflow: "Deploy production", event: "push", head_branch: "main" })) throw new Error("non-CI workflow on main is NOT auto-revert-owned by default");
if (isAutoRevertHandled({ workflow: "CI", event: "push", head_branch: "release" })) throw new Error("CI push to non-main is NOT auto-revert (auto-revert watches main only)");

// #124 owns claim/issue-* branch failures.
if (!isRedPrRepairHandled({ head_branch: "claim/issue-77" })) throw new Error("claim/issue-* must be #124-handled");
if (isRedPrRepairHandled({ head_branch: "drill/escalation-221" })) throw new Error("drill branch is NOT #124-handled");
if (isRedPrRepairHandled({ head_branch: "main" })) throw new Error("main is NOT #124-handled");

// detectEscalations: 2 in window fires; auto-revert and #124 domains
// excluded; below threshold quiet; window-span quiet.
const drill = [
  { ...base, workflow: "CI", job: "P14 tests", step: "assert", assertion: "AssertionError: expected x to be y", event: "pull_request", head_branch: "drill/escalation-221", created_at: "2026-08-26T10:00:00Z", run_id: 1 },
  { ...base, workflow: "CI", job: "P14 tests", step: "assert", assertion: "AssertionError: expected x to be y", event: "pull_request", head_branch: "drill/escalation-221", created_at: "2026-08-26T10:40:00Z", run_id: 2 },
];
const fire = detectEscalations(drill, { threshold: 2, windowHours: 6 });
if (fire.length !== 1) throw new Error(`drill twice must yield 1 escalation, got ${fire.length}`);
if (fire[0].count !== 2) throw new Error("drill escalation count must be 2");
if (fire[0].excluded_owner !== null) throw new Error("drill escalation must not be excluded");

const mainCi = [
  { ...base, workflow: "CI", job: "P14 tests", step: "assert", assertion: "main broke", event: "push", head_branch: "main", created_at: "2026-08-26T11:00:00Z", run_id: 3 },
  { ...base, workflow: "CI", job: "P14 tests", step: "assert", assertion: "main broke", event: "push", head_branch: "main", created_at: "2026-08-26T11:30:00Z", run_id: 4 },
];
if (detectEscalations(mainCi, { threshold: 2, windowHours: 6 }).length !== 0) throw new Error("auto-revert-handled main CI must NOT escalate");

const claimPr = [
  { ...base, repo: "Nishfleet/fleet-ops", workflow: "CI", job: "Semgrep", step: "Run semgrep", assertion: "semgrep rule fired", event: "pull_request", head_branch: "claim/issue-77", created_at: "2026-08-26T12:00:00Z", run_id: 5 },
  { ...base, repo: "Nishfleet/fleet-ops", workflow: "CI", job: "Semgrep", step: "Run semgrep", assertion: "semgrep rule fired", event: "pull_request", head_branch: "claim/issue-77", created_at: "2026-08-26T12:20:00Z", run_id: 6 },
];
if (detectEscalations(claimPr, { threshold: 2, windowHours: 6 }).length !== 0) throw new Error("#124-handled claim/* must NOT escalate");

// below threshold: 1 failure -> quiet.
if (detectEscalations([drill[0]], { threshold: 2, windowHours: 6 }).length !== 0) throw new Error("1 failure must stay quiet");

// window span: 2 failures 7h apart -> quiet (no dense 6h sub-window).
const span = [
  { ...base, assertion: "spread", event: "pull_request", head_branch: "feature/y", created_at: "2026-08-26T00:00:00Z", run_id: 7 },
  { ...base, assertion: "spread", event: "pull_request", head_branch: "feature/y", created_at: "2026-08-26T07:00:00Z", run_id: 8 },
];
if (detectEscalations(span, { threshold: 2, windowHours: 6 }).length !== 0) throw new Error("2 failures spanning >6h must stay quiet");

// distinct signatures -> separate escalations.
const twoSigs = [
  ...drill,
  { ...base, workflow: "CI", job: "Semgrep", step: "Run semgrep", assertion: "semgrep rule fired", event: "pull_request", head_branch: "feature/z", created_at: "2026-08-26T10:10:00Z", run_id: 9 },
  { ...base, workflow: "CI", job: "Semgrep", step: "Run semgrep", assertion: "semgrep rule fired", event: "pull_request", head_branch: "feature/z", created_at: "2026-08-26T10:20:00Z", run_id: 10 },
];
const two = detectEscalations(twoSigs, { threshold: 2, windowHours: 6 });
if (two.length !== 2) throw new Error(`distinct signatures must yield 2 escalations, got ${two.length}`);

// findLastGreen: most recent success before the first failure.
const green = findLastGreen(
  [
    { id: 900, name: "CI", conclusion: "success", created_at: "2026-08-26T09:00:00Z", html_url: "u900" },
    { id: 901, name: "CI", conclusion: "success", created_at: "2026-08-26T09:30:00Z", html_url: "u901" },
    { id: 902, name: "CI", conclusion: "failure", created_at: "2026-08-26T09:45:00Z", html_url: "u902" },
  ],
  "CI",
  Date.parse("2026-08-26T10:00:00Z"),
);
if (!green || green.run_id !== 901) throw new Error("findLastGreen must return the most recent success before the failure");
if (findLastGreen([], "CI", 0) !== null) throw new Error("findLastGreen empty must be null");
if (findLastGreen([{ id: 1, name: "CI", conclusion: "success", created_at: "2026-08-26T11:00:00Z", html_url: "u" }], "CI", Date.parse("2026-08-26T10:00:00Z")) !== null) throw new Error("findLastGreen must ignore successes after the failure");

// isDuplicated: open issues carrying the hash marker are the dedup ledger.
const hash = signatureHash(signature(drill[0]));
if (isDuplicated([], hash)) throw new Error("empty open issues must not dedup");
if (isDuplicated([{ number: 1, body: "unrelated" }], hash)) throw new Error("non-matching body must not dedup");
if (!isDuplicated([{ number: 1, body: `<!-- escalate-sig: ${hash} -->\nbody` }], hash)) throw new Error("body with the marker must dedup");
if (isDuplicated([{ number: 1, body: null }], hash)) throw new Error("null body must not dedup");

// renderIssueTitle / renderIssueBody: name repo + workflow + job, carry the
// hash marker, name the exclusion owners, surface last-green.
const esc = fire[0];
const title = renderIssueTitle(esc);
if (!title.includes("[escalate-senior]")) throw new Error("title must carry the label tag");
if (!title.includes("Nishfleet/0509")) throw new Error("title must name the repo");
if (!title.includes("CI")) throw new Error("title must name the workflow");
const body = renderIssueBody(esc);
if (!body.includes(`<!-- escalate-sig: ${esc.hash} -->`)) throw new Error("body must carry the hash marker");
if (!body.includes("auto-revert")) throw new Error("body must name auto-revert as an excluded owner");
if (!body.includes("#124")) throw new Error("body must name #124 as an excluded owner");
if (!body.includes("Last green")) throw new Error("body must surface last green");

// parseEnrolledRepos: reads intake-repos.json, excludes permanent exclusions.
const enrolled = parseEnrolledRepos(_readFileSync("config/intake-repos.json", "utf8"));
if (!enrolled.includes("Nishfleet/0509")) throw new Error("0509 must be enrolled");
if (!enrolled.includes("Nishfleet/fleet-ops")) throw new Error("fleet-ops must be enrolled");
if (enrolled.includes("Nishfleet/fleet2")) throw new Error("fleet2 is permanently excluded and must NOT be enrolled");
if (enrolled.includes("Nishfleet/siterep")) throw new Error("archived siterep is permanently excluded");
if (parseEnrolledRepos("not json").length !== 0) throw new Error("invalid json must yield []");

console.log("OK: pure function tests (normalize, signature, exclusions, detect, dedup, render, enrolled)");
' || fail "pure function tests failed"

# --- replay: drill branch twice -> one escalation filed ----------------------
drill_json="$(node "$script" --from-json "$fixtures/drill-branch-twice.json" --output-json /tmp/esc-drill.json)"
echo "$drill_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-drill.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 1) throw new Error(`drill twice must yield 1 escalation, got ${t.escalations.length}`);
if (t.filed.length !== 1) throw new Error(`drill twice must file 1, got ${t.filed.length}`);
if (t.filed[0].deduped !== false) throw new Error("first drill escalation must not be deduped");
const e = t.escalations[0];
if (e.repo !== "Nishfleet/0509") throw new Error("escalation repo mismatch");
if (e.workflow !== "CI") throw new Error("escalation workflow mismatch");
if (e.count !== 2) throw new Error("escalation count must be 2");
if (!e.last_green || e.last_green.run_id !== 900) throw new Error("escalation must surface last green run 900");
if (!e.runs[0].run_url.includes("/1001")) throw new Error("escalation must carry run url");
console.log("OK: drill-branch twice -> one escalation with context + last green");
' || fail "drill-branch replay failed"

# --- replay: auto-revert-handled -> NO escalation ----------------------------
node "$script" --from-json "$fixtures/auto-revert-handled.json" --output-json /tmp/esc-ar.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-ar.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 0) throw new Error(`auto-revert-handled main CI must NOT escalate, got ${t.escalations.length}`);
if (t.filed.length !== 0) throw new Error("auto-revert-handled must file nothing");
console.log("OK: auto-revert-handled main CI -> no escalation (no duplicate)");
' || fail "auto-revert replay failed"

# --- replay: #124 claim-branch-handled -> NO escalation ----------------------
node "$script" --from-json "$fixtures/claim-branch-handled.json" --output-json /tmp/esc-claim.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-claim.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 0) throw new Error(`#124-handled claim/* must NOT escalate, got ${t.escalations.length}`);
console.log("OK: #124-handled claim/* -> no escalation (no duplicate)");
' || fail "claim-branch replay failed"

# --- replay: deduped against open issue -> NO new filing ---------------------
node "$script" --from-json "$fixtures/deduped.json" --output-json /tmp/esc-dedup.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-dedup.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 1) throw new Error("dedup fixture still detects the signature");
if (t.filed.length !== 1) throw new Error("dedup fixture must report the filing decision");
if (t.filed[0].deduped !== true) throw new Error("open issue with the hash marker must dedupe — no new filing");
console.log("OK: signature bound — open issue with hash marker dedupes (no duplicate filing)");
' || fail "dedup replay failed"

# --- replay: below threshold -> quiet ---------------------------------------
node "$script" --from-json "$fixtures/below-threshold.json" --output-json /tmp/esc-quiet.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-quiet.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 0) throw new Error(`single transient red must stay quiet, got ${t.escalations.length}`);
console.log("OK: below threshold -> quiet");
' || fail "below-threshold replay failed"

# --- replay: window span >6h -> quiet ---------------------------------------
node "$script" --from-json "$fixtures/window-span.json" --output-json /tmp/esc-span.json >/dev/null
node --input-type=module -e '
import { readFileSync } from "node:fs";
const r = JSON.parse(readFileSync("/tmp/esc-span.json", "utf8"));
const t = r.targets[0];
if (t.escalations.length !== 0) throw new Error(`2 failures spanning >6h must stay quiet, got ${t.escalations.length}`);
console.log("OK: window span >6h -> quiet (6h bound respected)");
' || fail "window-span replay failed"

# --- workflow shape: the reusable workflow must be workflow_call + schedule --
wf="$repo_root/.github/workflows/ci-failure-escalation.yml"
grep -q 'workflow_call:' "$wf" || fail "ci-failure-escalation.yml must declare workflow_call"
grep -q 'schedule:' "$wf" || fail "ci-failure-escalation.yml must run on schedule (central sweep per #185)"
grep -q 'timeout-minutes:' "$wf" || fail "ci-failure-escalation.yml job must set timeout-minutes"
grep -q 'issues: write' "$wf" || fail "workflow needs issues: write to file escalate-senior issues"
grep -q 'config/intake-repos.json' "$wf" || fail "sweep must enumerate enrolled repos from config/intake-repos.json (#185 auto-discovery)"
ok "ci-failure-escalation.yml shape (workflow_call + schedule + issues:write + auto-discovery)"

echo "OK: ci-failure-escalation-detector bridge proven (fleet-ops#221)"
