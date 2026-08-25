#!/usr/bin/env bash
# tests/semantic-conflict-detector.test.sh
#
# Proves the merge-queue semantic-conflict detector without reaching GitHub.
# Replay fixtures: 0509 PR #994 (green on pull_request, red on merge_group)
# must fire; a PR that fails on both triggers must stay quiet.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/semantic-conflict-detector.mjs"
fixtures="$here/fixtures/semantic-conflict-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

node --input-type=module -e '
import {
  extractPrNumber,
  detectSemanticConflicts,
  eventFailureRates,
  divergencePct,
  renderAlert,
} from "./.github/scripts/semantic-conflict-detector.mjs";

const queuePr = extractPrNumber({
  id: 1,
  name: "CI",
  event: "merge_group",
  conclusion: "failure",
  head_branch: "gh-readonly-queue/main/pr-994-079269b362b8772c7b13a1b185f327a68360afd8",
  head_sha: "deadbeef",
  created_at: "2026-08-25T17:48:14Z",
  html_url: "https://example.test/1",
});
if (queuePr !== 994) throw new Error(`queue PR extract: expected 994, got ${queuePr}`);

const embedPr = extractPrNumber({
  id: 2,
  name: "CI",
  event: "pull_request",
  conclusion: "success",
  head_branch: "claim/issue-951",
  head_sha: "cafe",
  created_at: "2026-08-25T07:28:24Z",
  html_url: "https://example.test/2",
  pull_requests: [{ number: 994 }],
});
if (embedPr !== 994) throw new Error(`embed PR extract: expected 994, got ${embedPr}`);

const none = extractPrNumber({
  id: 3,
  name: "CI",
  event: "push",
  conclusion: "success",
  head_branch: "main",
  head_sha: "mainsha",
  created_at: "2026-08-25T00:00:00Z",
  html_url: "https://example.test/3",
});
if (none !== null) throw new Error(`main branch should not yield a PR, got ${none}`);

// Latest isolation is red even though an older isolation run was green:
// the PR is currently bad on its own — stay quiet.
const quietDespiteOlderGreen = detectSemanticConflicts([
  {
    id: 10,
    name: "CI",
    event: "pull_request",
    conclusion: "success",
    head_branch: "wip",
    head_sha: "old",
    created_at: "2026-08-25T08:00:00Z",
    html_url: "https://example.test/10",
    pull_request_numbers: [7],
  },
  {
    id: 11,
    name: "CI",
    event: "pull_request",
    conclusion: "failure",
    head_branch: "wip",
    head_sha: "new",
    created_at: "2026-08-25T09:00:00Z",
    html_url: "https://example.test/11",
    pull_request_numbers: [7],
  },
  {
    id: 12,
    name: "CI",
    event: "merge_group",
    conclusion: "failure",
    head_branch: "gh-readonly-queue/main/pr-7-abc",
    head_sha: "batch",
    created_at: "2026-08-25T10:00:00Z",
    html_url: "https://example.test/12",
    failed_jobs: ["codex-node-checks"],
  },
]);
if (quietDespiteOlderGreen.length !== 0) {
  throw new Error(`expected quiet on latest isolation failure, got ${JSON.stringify(quietDespiteOlderGreen)}`);
}

const rates = eventFailureRates([
  { id: 1, name: "CI", event: "pull_request", conclusion: "success", head_branch: "a", head_sha: "1", created_at: "t", html_url: "u" },
  { id: 2, name: "CI", event: "pull_request", conclusion: "failure", head_branch: "a", head_sha: "2", created_at: "t", html_url: "u" },
  { id: 3, name: "CI", event: "merge_group", conclusion: "failure", head_branch: "a", head_sha: "3", created_at: "t", html_url: "u" },
  { id: 4, name: "CI", event: "merge_group", conclusion: "failure", head_branch: "a", head_sha: "4", created_at: "t", html_url: "u" },
  { id: 5, name: "CI", event: "merge_group", conclusion: "success", head_branch: "a", head_sha: "5", created_at: "t", html_url: "u" },
  { id: 6, name: "CI", event: "push", conclusion: "cancelled", head_branch: "a", head_sha: "6", created_at: "t", html_url: "u" },
]);
const pr = rates.find((r) => r.event === "pull_request");
const mg = rates.find((r) => r.event === "merge_group");
if (!pr || pr.total !== 2 || pr.failed !== 1 || pr.rate_pct !== 50) {
  throw new Error(`pull_request rate mismatch: ${JSON.stringify(pr)}`);
}
if (!mg || mg.total !== 3 || mg.failed !== 2 || mg.rate_pct !== 66.7) {
  throw new Error(`merge_group rate mismatch: ${JSON.stringify(mg)}`);
}
const div = divergencePct(rates);
if (div !== 16.7) throw new Error(`divergence expected 16.7, got ${div}`);

const alert = renderAlert({
  pr: 994,
  check: "codex-node-checks",
  workflow: "CI",
  isolation_event: "pull_request",
  isolation_run_id: 1,
  isolation_url: "u1",
  batch_run_id: 2,
  batch_url: "u2",
  batch_failure_count: 6,
});
if (!alert.includes("codex-node-checks")) throw new Error("alert must name the check");
if (!alert.includes("PR #994")) throw new Error("alert must name the PR");
if (!alert.includes("green in isolation")) throw new Error("alert must say green in isolation");
if (!alert.includes("conflicts with the batch")) throw new Error("alert must say conflicts with the batch");
if (!alert.includes("Re-queueing will not help")) throw new Error("alert must tell people not to re-queue");

console.log("OK: extractPrNumber, quiet-on-both, rates, alert copy");
' || fail "pure function tests failed"

# Replay 0509 PR #994 history: must fire and name codex-node-checks.
report_994="$(node "$script" --from-json "$fixtures/pr-994.json" --format json)"
echo "$report_994" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.conflicts) || report.conflicts.length !== 1) {
  throw new Error(`PR 994 must fire exactly once, got ${JSON.stringify(report.conflicts)}`);
}
const c = report.conflicts[0];
if (c.pr !== 994) throw new Error(`expected PR 994, got ${c.pr}`);
if (c.check !== "codex-node-checks") throw new Error(`expected check codex-node-checks, got ${c.check}`);
if (c.workflow !== "CI") throw new Error(`expected workflow CI, got ${c.workflow}`);
console.log("OK: PR #994 fixture fires and names codex-node-checks");
'

# Replay a PR that fails on both triggers: must stay quiet.
report_both="$(node "$script" --from-json "$fixtures/both-fail.json" --format json)"
echo "$report_both" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.conflicts) || report.conflicts.length !== 0) {
  throw new Error(`both-fail PR must stay quiet, got ${JSON.stringify(report.conflicts)}`);
}
console.log("OK: both-fail fixture stays quiet");
'

# Human report from the 994 fixture names the check in plain language.
human="$(node "$script" --from-json "$fixtures/pr-994.json" --format human)"
echo "$human" | grep -q "codex-node-checks" || fail "human report must name the check"
echo "$human" | grep -q "green in isolation" || fail "human report must say green in isolation"
echo "$human" | grep -q "conflicts with the batch" || fail "human report must say conflicts with the batch"
echo "$human" | grep -q "Failure rate by trigger" || fail "human report must publish the rate split"

echo "OK: semantic-conflict-detector.mjs fixtures and copy"
