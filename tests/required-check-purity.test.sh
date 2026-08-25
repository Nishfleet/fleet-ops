#!/usr/bin/env bash
# tests/required-check-purity.test.sh
#
# Proves the required-check purity lint without reaching GitHub.
# 0509's ratchet in its pre-1056 form must flag; the monotonic post-1056
# form, a sha256 pin, and this repo's own tree must stay quiet.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/required-check-purity.mjs"
fixtures="$here/fixtures/required-check-purity"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "purity script not found: $script"
node --check "$script" || fail "purity script failed node --check"
node "$script" --help >/dev/null || fail "purity --help failed"

cd "$repo_root"

node --input-type=module -e '
import { classifyLine, findingsInSource, renderReport } from "./.github/scripts/required-check-purity.mjs";

if (classifyLine("    if (counts[marker] !== ceiling) {") !== "exact-equality-baseline") {
  throw new Error("current 0509 if-condition must classify as exact-equality-baseline");
}
if (classifyLine("      `${marker}: count ${counts[marker]} !== ceiling ${ceiling} (run --update in this PR)`,") !== "pr-must-edit-shared-baseline") {
  throw new Error("update-in-PR message must classify as pr-must-edit-shared-baseline");
}
if (classifyLine("    if (counts[marker] > ceiling) {") !== null) {
  throw new Error("monotonic > ceiling must stay quiet");
}
if (classifyLine("  if (JSON.stringify(ceilingKeys) !== JSON.stringify(expectedKeys)) {") !== null) {
  throw new Error("key-set integrity must stay quiet");
}
if (classifyLine("    // if (counts[marker] !== ceiling) {") !== null) {
  throw new Error("commented exact-equality must stay quiet");
}
if (classifyLine("if (got !== expectedSha) {") !== null) {
  throw new Error("sha256 pin must stay quiet");
}

const report = renderReport([{
  file: "scripts/design-system-ratchet.mjs",
  line: 274,
  kind: "exact-equality-baseline",
  text: "if (counts[marker] !== ceiling) {",
}]);
if (!report.includes("scripts/design-system-ratchet.mjs:274")) {
  throw new Error("report must name file:line");
}
if (!report.includes("pure function of the PR")) {
  throw new Error("report must state the purity rule");
}
if (findingsInSource("const ok = 1;\n", "x.mjs").length !== 0) {
  throw new Error("clean source must yield no findings");
}
console.log("OK: classifyLine, comments, key-set, pin, report copy");
' || fail "pure function tests failed"

# 0509 current form (exact equality + --update in this PR): must flag.
current_json="$(node "$script" --root "$fixtures/current-0509" --format json --advisory)"
echo "$current_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.findings) || report.findings.length < 1) {
  throw new Error(`current 0509 ratchet must flag, got ${JSON.stringify(report.findings)}`);
}
const files = new Set(report.findings.map((f) => f.file));
if (![...files].some((f) => f.endsWith("design-system-ratchet.mjs"))) {
  throw new Error(`must name the ratchet script, got ${JSON.stringify([...files])}`);
}
const kinds = new Set(report.findings.map((f) => f.kind));
if (!kinds.has("exact-equality-baseline") && !kinds.has("pr-must-edit-shared-baseline")) {
  throw new Error(`unexpected kinds: ${JSON.stringify([...kinds])}`);
}
if (report.advisory !== true) {
  throw new Error("advisory mode must set advisory=true");
}
console.log("OK: 0509 current-form fixture flags");
'

# Advisory: findings must not fail the process.
if ! node "$script" --root "$fixtures/current-0509" --advisory --format human >/dev/null; then
  fail "advisory mode must exit 0 on findings"
fi

# Enforce: findings must fail the process.
if node "$script" --root "$fixtures/current-0509" --enforce --format human >/dev/null 2>&1; then
  fail "enforce mode must exit 1 on findings"
fi

# 0509 after 1056 (monotonic > ceiling): must stay quiet.
post_json="$(node "$script" --root "$fixtures/post-1056" --format json --enforce)"
echo "$post_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.findings) || report.findings.length !== 0) {
  throw new Error(`post-1056 ratchet must stay quiet, got ${JSON.stringify(report.findings)}`);
}
console.log("OK: post-1056 fixture stays quiet");
'

# Sha256 pin: quiet.
pin_json="$(node "$script" --root "$fixtures/hash-pin" --format json --enforce)"
echo "$pin_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.findings) || report.findings.length !== 0) {
  throw new Error(`hash pin must stay quiet, got ${JSON.stringify(report.findings)}`);
}
console.log("OK: hash-pin fixture stays quiet");
'

# Scanning this repo must not flag our own current-form fixture.
self_json="$(node "$script" --root "$repo_root" --format json --enforce)"
echo "$self_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.findings) || report.findings.length !== 0) {
  throw new Error(`fleet-ops self-scan must stay quiet, got ${JSON.stringify(report.findings)}`);
}
console.log("OK: fleet-ops self-scan stays quiet");
'

human="$(node "$script" --root "$fixtures/current-0509" --format human --advisory)"
echo "$human" | grep -q "design-system-ratchet.mjs" || fail "human report must name the ratchet"
echo "$human" | grep -q "pure function of the PR" || fail "human report must state the purity rule"

echo "OK: required-check-purity.mjs fixtures and copy"
