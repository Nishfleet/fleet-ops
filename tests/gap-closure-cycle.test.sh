#!/usr/bin/env bash
# tests/gap-closure-cycle.test.sh
#
# Proves the org-wide gap-closure cycle (fleet-ops#185) without reaching
# GitHub. Pattern copied from tests/red-on-main-detector.test.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/gap-closure-cycle.mjs"
fixture="$here/fixtures/gap-closure-cycle/full-cycle.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "cycle script not found: $script"
[[ -f "$fixture" ]] || fail "fixture not found: $fixture"
node --check "$script" || fail "cycle script failed node --check"
node "$script" --help >/dev/null || fail "cycle --help failed"

cd "$repo_root"

node --input-type=module -e '
import {
  excludedNames,
  discoverTargets,
  classifyOrgRulesets,
  decideAutoRevert,
  isStaleLostBranch,
  isOwnerlessPr,
  auditRepo,
  dedupeFindings,
  computeDora,
  nextLoopState,
} from "./.github/scripts/gap-closure-cycle.mjs";

const excluded = excludedNames({
  excluded: [{ name: "fleet2" }, { name: "siterep" }, { name: "  " }],
});
if (!excluded.has("fleet2") || !excluded.has("siterep")) throw new Error("excludedNames missed a name");
if (excluded.has("")) throw new Error("excludedNames must ignore blank names");

const discovery = discoverTargets({
  orgRepos: [
    { name: "fleet2" },
    { name: "siterep", archived: true },
    { name: "paused-product" },
    { name: "brand-new-tomorrow" },
    { name: "0509" },
  ],
  excluded,
  handsOff: ["paused-product"],
});
const names = discovery.targets.map((r) => r.name);
if (names.includes("fleet2")) throw new Error("fleet2 must be skipped");
if (names.includes("siterep")) throw new Error("archived must be skipped");
if (names.includes("paused-product")) throw new Error("hands-off must be skipped");
if (!names.includes("brand-new-tomorrow")) throw new Error("unenrolment must not hide a new repo");
if (!names.includes("0509")) throw new Error("known repos stay in the cycle");
if (discovery.skipped.find((s) => s.name === "fleet2")?.reason !== "excluded") {
  throw new Error("fleet2 skip reason must be excluded");
}

const rules = classifyOrgRulesets({
  status: 403,
  message: "Upgrade to GitHub Team to enable this feature.",
});
if (rules.status !== "team-required") throw new Error("free-plan 403 must be team-required SKIP");
if (classifyOrgRulesets([]).status !== "available") throw new Error("empty list is available");

if (decideAutoRevert({
  branch: "main", conclusion: "failure", subject: "feat: x", main_head: "a", head_sha: "a",
}) !== "OPEN_REVERT") throw new Error("main red must open revert");
if (decideAutoRevert({
  branch: "drill/canary", conclusion: "failure", subject: "feat: x", main_head: "a", head_sha: "b",
}) !== "SKIP_NOT_MAIN") throw new Error("drill branch must not revert main");

const now = new Date("2026-08-26T06:00:00Z");
if (!isStaleLostBranch(
  { name: "abandoned/old-fix", updated_at: "2026-08-01T00:00:00Z", ahead: 3, open_pr: false },
  { now },
)) throw new Error("three-check must fire on abandoned unique branch");
if (isStaleLostBranch(
  { name: "abandoned/old-fix", updated_at: "2026-08-01T00:00:00Z", ahead: 0, open_pr: false },
  { now },
)) throw new Error("three-check must not fire when ahead=0");
if (isOwnerlessPr(
  { draft: false, assignees: [], labels: [], updated_at: "2026-08-20T00:00:00Z" },
  { now },
) !== true) throw new Error("ownerless PR must fire");
if (isOwnerlessPr(
  { draft: false, assignees: [], labels: ["agent-in-progress"], updated_at: "2026-08-20T00:00:00Z" },
  { now },
)) throw new Error("agent-in-progress PR is owned");

const fresh = auditRepo({
  name: "brand-new-tomorrow",
  workflows: [],
  has_auto_revert: false,
  has_branch_protection: false,
});
const kinds = new Set(fresh.map((f) => f.kind));
if (!kinds.has("ci-health")) throw new Error("new repo must flag missing CI");
if (!kinds.has("deploy-gate")) throw new Error("new repo must flag missing auto-revert/protection");

const kept = dedupeFindings(fresh, [fresh[0].title]);
if (kept.length !== fresh.length - 1) throw new Error("dedupeFindings must drop exact open titles");

const dora = computeDora({
  now,
  merged_prs: [
    { created_at: "2026-08-25T10:00:00Z", merged_at: "2026-08-25T12:00:00Z", auto_revert: false },
    { created_at: "2026-08-25T13:00:00Z", merged_at: "2026-08-25T13:30:00Z", auto_revert: true },
  ],
  deployments: [{ created_at: "2026-08-25T12:05:00Z", state: "success" }],
});
if (dora.changes !== 2) throw new Error(`expected 2 changes, got ${dora.changes}`);
if (dora.change_fail_rate !== 0.5) throw new Error(`expected change-fail 0.5, got ${dora.change_fail_rate}`);
if (dora.deploys !== 1) throw new Error(`expected 1 deploy, got ${dora.deploys}`);

if (nextLoopState({ prev: "looping", findingsFiled: 1, drillsPassed: true }) !== "looping") {
  throw new Error("findings keep the repo looping");
}
if (nextLoopState({ prev: "looping", findingsFiled: 0, drillsPassed: true }) !== "candidate-done") {
  throw new Error("clean cycle is candidate-done until the #180 conference");
}
if (nextLoopState({ prev: "done", findingsFiled: 1, drillsPassed: true }) !== "reopened") {
  throw new Error("regression must reopen just that repo");
}
if (nextLoopState({ prev: "done", findingsFiled: 0, drillsPassed: true }) !== "done") {
  throw new Error("clean done stays done");
}

console.log("OK: pure functions");
' || fail "pure function tests failed"

report_json="$(node "$script" --from-json "$fixture" --format json)"
echo "$report_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));

if (report.org_rulesets.status !== "team-required") {
  throw new Error(`org rulesets must SKIP as team-required, got ${report.org_rulesets.status}`);
}

const discovered = report.discovered;
if (discovered.includes("fleet2")) throw new Error("fleet2 leaked into discovered");
if (discovered.includes("siterep")) throw new Error("archived siterep leaked into discovered");
if (discovered.includes("paused-product")) throw new Error("hands-off leaked into discovered");
if (!discovered.includes("brand-new-tomorrow")) {
  throw new Error("brand-new-tomorrow must be auto-discovered with zero enrolment");
}
if (!discovered.includes("0509-telemetry")) {
  throw new Error("private repos stay in the API-only cycle");
}
if (!Array.isArray(report.private_api_only) || !report.private_api_only.includes("0509-telemetry")) {
  throw new Error("private_api_only must list 0509-telemetry");
}

if (report.drills.failed.length !== 0) {
  throw new Error(`auto-revert drill must pass, failed=${JSON.stringify(report.drills.failed)}`);
}
if (report.drills.passed < 4) {
  throw new Error(`expected ≥4 drill cases, got ${report.drills.passed}`);
}

const titles = report.findings.map((f) => f.title);
if (!titles.some((t) => t.includes("brand-new-tomorrow") && t.includes("no CI"))) {
  throw new Error("new repo must produce a missing-CI finding");
}
if (!titles.some((t) => t.includes("fleet-ops") && t.includes("red on main"))) {
  throw new Error("fleet-ops red-on-main finding missing");
}
if (!titles.some((t) => t.includes("ownerless PR #88"))) {
  throw new Error("0509 ownerless PR finding missing");
}
if (!titles.some((t) => t.includes("abandoned/old-fix"))) {
  throw new Error("stale-branch three-check finding missing");
}
if (report.findings.some((f) => f.repo.includes("fleet2"))) {
  throw new Error("must not file findings against excluded fleet2");
}

if (report.loop["brand-new-tomorrow"] !== "looping") {
  throw new Error(`new repo should be looping, got ${report.loop["brand-new-tomorrow"]}`);
}
if (report.loop["0509"] !== "reopened") {
  throw new Error(`0509 was done and has findings, should reopen, got ${report.loop["0509"]}`);
}
if (report.loop["context-hub"] !== "done") {
  throw new Error(`clean context-hub was already done, should stay done, got ${report.loop["context-hub"]}`);
}

if (report.conference !== "pending-180") {
  throw new Error("conference must stay pending-180 (VPS, not duplicated here)");
}

const fleetDora = report.dora.by_repo["fleet-ops"];
if (!fleetDora || fleetDora.changes !== 2) throw new Error("fleet-ops DORA changes missing");
if (fleetDora.change_fail_rate !== 0.5) throw new Error("fleet-ops change-fail rate should be 0.5");
if (typeof report.dora.product_vs_control_plane !== "number") {
  throw new Error("org-wide product vs control-plane ratio must be a number");
}

if (report.filed.length !== 0) {
  throw new Error("--from-json must not file issues");
}

console.log("OK: fixture replay");
' || { echo "$report_json"; fail "fixture replay assertions failed"; }

ok "gap-closure cycle: discovery, org-ruleset SKIP, audit, drill, DORA, reopen"
