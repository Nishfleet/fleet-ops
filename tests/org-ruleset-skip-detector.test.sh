#!/usr/bin/env bash
# tests/org-ruleset-skip-detector.test.sh
#
# Proves the org-ruleset SKIP detector without reaching GitHub.
# The silent-pass this exists to prevent: treating a free-plan 403 as if
# org rulesets were already binding every repo.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/org-ruleset-skip-detector.mjs"
audit="$repo_root/.github/scripts/ci-standards-audit.mjs"
docs="$repo_root/docs/ci-standard.md"
fixtures="$here/fixtures/org-ruleset-skip-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "detector script not found: $script"
[[ -f "$audit" ]] || fail "ci-standards-audit.mjs not found: $audit"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null 2>&1 || fail "detector --help failed"

cd "$repo_root"

# The daily ci-standards-audit live path must import this detector. That is
# the named schedule (org plan changes have no webhook). Removing the import
# would make the SKIP assumed again.
grep -q 'org-ruleset-skip-detector.mjs' "$audit" \
  || fail "ci-standards-audit.mjs must import org-ruleset-skip-detector.mjs"
grep -q 'probeOrgRulesets' "$audit" \
  || fail "ci-standards-audit live path must call probeOrgRulesets"
grep -q 'maybePostDecisionResolved' "$audit" \
  || fail "ci-standards-audit live path must observe-to-close via maybePostDecisionResolved"
grep -qi 'org rulesets' "$docs" \
  || fail "docs/ci-standard.md must name the org-rulesets SKIP"

# --- pure-function unit tests ----------------------------------------------
node --input-type=module -e '
import {
  classifyOrgRulesets,
  renderReport,
  decisionResolvedComment,
  isAppTokenOrgDenied,
  normalizePlanName,
} from "./.github/scripts/org-ruleset-skip-detector.mjs";

if (normalizePlanName("free") !== "free") throw new Error("normalizePlanName must keep a real plan name");
if (normalizePlanName("null") !== null) throw new Error("jq null must not become plan name 'null'");
if (normalizePlanName("") !== null) throw new Error("empty plan must be null");
if (!isAppTokenOrgDenied("Resource not accessible by integration")) {
  throw new Error("App-token 403 must be recognised");
}
if (isAppTokenOrgDenied("Upgrade to GitHub Team to enable this feature.")) {
  throw new Error("plan-limit 403 must not look like an App-token denial");
}

const freeForged = classifyOrgRulesets({
  plan: "free",
  rulesets: [{ id: 1, name: "forged" }],
});
if (freeForged.status !== "team-required") {
  throw new Error(`free plan with a forged ruleset list must be team-required, got ${freeForged.status}`);
}
if (freeForged.ruleset_count !== null) {
  throw new Error("free plan must not report a ruleset_count (that would look like a pass)");
}

const team403 = classifyOrgRulesets({
  plan: null,
  rulesets: { status: 403, message: "Upgrade to GitHub Team to enable this feature." },
});
if (team403.status !== "team-required") {
  throw new Error(`plan-limit 403 must be team-required, got ${team403.status}`);
}

const available = classifyOrgRulesets({
  plan: "team",
  rulesets: [{ id: 1 }],
});
if (available.status !== "available") {
  throw new Error(`paid plan with a ruleset list must be available, got ${available.status}`);
}
if (available.ruleset_count !== 1) {
  throw new Error(`available ruleset_count must be 1, got ${available.ruleset_count}`);
}

const perm = classifyOrgRulesets({
  plan: null,
  rulesets: { status: 403, message: "Resource not accessible by integration" },
});
if (perm.status !== "permission-denied") {
  throw new Error(`token 403 must be permission-denied, got ${perm.status}`);
}

const empty = classifyOrgRulesets({});
if (empty.status !== "error") {
  throw new Error(`empty probe must be error, got ${empty.status}`);
}

const report = {
  generated_at: "2026-08-26T19:00:00Z",
  org: "Nishfleet",
  classification: available,
};
const human = renderReport(report);
if (!human.includes("STATE CHANGE")) throw new Error("available human report must say STATE CHANGE");
const skipHuman = renderReport({
  generated_at: "2026-08-26T19:00:00Z",
  org: "Nishfleet",
  classification: freeForged,
});
if (!skipHuman.includes("steady SKIP")) throw new Error("team-required human report must say steady SKIP");

const comment = decisionResolvedComment(report);
if (!comment.includes("decision-resolved: org rulesets now available on a paid plan")) {
  throw new Error("observe-to-close comment must carry decision-resolved:");
}
if (!comment.includes("<!-- org-ruleset-skip-detector:available -->")) {
  throw new Error("observe-to-close comment must carry the HTML marker");
}

console.log("OK: classifyOrgRulesets, renderReport, decisionResolvedComment");
' || fail "pure function tests failed"

# --- replay: free plan with a forged ruleset list stays SKIP ---------------
free_json="$(node "$script" --from-json "$fixtures/team-required-plan.json" --format json --no-issue)"
echo "$free_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (report.classification.status !== "team-required") {
  throw new Error(`expected team-required, got ${report.classification.status}`);
}
if (report.classification.plan !== "free") {
  throw new Error(`expected plan free, got ${report.classification.plan}`);
}
' || fail "team-required-plan fixture failed"

# --- replay: plan-limit 403 is SKIP ----------------------------------------
set +e
node "$script" --from-json "$fixtures/team-required-403.json" --format json --no-issue >/tmp/org-ruleset-403.json
rc403=$?
set -e
[[ "$rc403" -eq 0 ]] || fail "team-required 403 must exit 0 (steady SKIP is green), got $rc403"
jq -e '.classification.status == "team-required"' /tmp/org-ruleset-403.json >/dev/null \
  || fail "team-required-403 fixture must classify team-required"

# --- replay: paid plan is available, exit 0 --------------------------------
avail_json="$(node "$script" --from-json "$fixtures/available.json" --format json --no-issue)"
echo "$avail_json" | jq -e '.classification.status == "available" and .classification.ruleset_count == 1' >/dev/null \
  || fail "available fixture must classify available with one ruleset"

# --- replay: permission-denied is a loud failure, never a pass -------------
set +e
node "$script" --from-json "$fixtures/permission-denied.json" --format json --no-issue >/tmp/org-ruleset-perm.json
rcperm=$?
set -e
[[ "$rcperm" -eq 1 ]] || fail "permission-denied must exit 1, got $rcperm"
jq -e '.classification.status == "permission-denied"' /tmp/org-ruleset-perm.json >/dev/null \
  || fail "permission-denied fixture must classify permission-denied"

# --- replay: empty probe is a loud failure ---------------------------------
set +e
node "$script" --from-json "$fixtures/error-empty.json" --format json --no-issue >/tmp/org-ruleset-empty.json
rcempty=$?
set -e
[[ "$rcempty" -eq 1 ]] || fail "empty probe must exit 1, got $rcempty"
jq -e '.classification.status == "error"' /tmp/org-ruleset-empty.json >/dev/null \
  || fail "error-empty fixture must classify error"

# --- human copy ------------------------------------------------------------
human="$(node "$script" --from-json "$fixtures/team-required-plan.json" --format human --no-issue)"
echo "$human" | grep -q "Org-ruleset SKIP detector" || fail "human report must have a title"
echo "$human" | grep -q "SKIP, not a pass" || fail "human report must say SKIP, not a pass"
echo "$human" | grep -q "fleet-ops#219" || fail "human report must cite the money decision issue"

echo "OK: org-ruleset-skip-detector.mjs fixtures and copy"
