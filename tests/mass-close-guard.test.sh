#!/usr/bin/env bash
# tests/mass-close-guard.test.sh
#
# Proves the mass-close guard's decision logic without reaching GitHub.
# The pure function `shouldReopen(stateReason, labels, linkedPrStates)` is
# the contract: a not-planned close of an agent-labeled issue with no
# merged linked PR reopens; everything else stays closed.
#
# The live "close a dummy agent-ready issue as not-planned and watch it
# reopen" acceptance test (fleet-ops#77) is a manual GitHub-side check;
# this file locks the decision matrix that drives it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/mass-close-guard.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "guard script not found: $script"
node --check "$script" || fail "guard script failed node --check"
node "$script" --help >/dev/null 2>&1 || fail "guard --help failed"

cd "$repo_root"

node --input-type=module -e '
import {
  shouldReopen,
  linkedPrNumbersFromTimeline,
  PROTECTED_LABEL_NAMES,
} from "./.github/scripts/mass-close-guard.mjs";

const eq = (got, want, msg) => {
  if (got !== want) throw new Error(`${msg}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};

// The textbook mass-close: not_planned + agent-labeled + no merged PR.
eq(shouldReopen("not_planned", ["agent-ready"], []), true, "agent-ready no PR reopens");
eq(shouldReopen("not_planned", ["agent-in-progress"], []), true, "agent-in-progress no PR reopens");
eq(shouldReopen("not_planned", ["agent-in-progress", "agent-ready"], []), true, "both labels no PR reopens");

// A merged linked PR means the close was legitimate: stay closed.
eq(shouldReopen("not_planned", ["agent-ready"], ["MERGED"]), false, "merged PR stays closed");
eq(shouldReopen("not_planned", ["agent-ready"], ["OPEN", "MERGED"]), false, "any merged PR stays closed");

// Only OPEN/CLOSED (no merge) references do not justify a not-planned close.
eq(shouldReopen("not_planned", ["agent-ready"], ["OPEN"]), true, "open PR still reopens");
eq(shouldReopen("not_planned", ["agent-ready"], ["CLOSED"]), true, "closed-unmerged PR still reopens");
eq(shouldReopen("not_planned", ["agent-ready"], [null]), true, "unknown-state PR still reopens");

// A completed close (the normal PR-merge auto-close, or a human completing) is never touched.
eq(shouldReopen("completed", ["agent-ready"], []), false, "completed stays closed");
eq(shouldReopen("completed", ["agent-ready"], ["MERGED"]), false, "completed+merged stays closed");

// duplicate / outdated / other state_reasons are not the mass-close signature.
eq(shouldReopen("duplicate", ["agent-ready"], []), false, "duplicate stays closed");
eq(shouldReopen("outdated", ["agent-in-progress"], []), false, "outdated stays closed");
eq(shouldReopen(null, ["agent-ready"], []), false, "null state_reason stays closed");
eq(shouldReopen(undefined, ["agent-ready"], []), false, "undefined state_reason stays closed");

// No agent label: outside the guard remit. Nish can retire non-agent issues as not-planned freely.
eq(shouldReopen("not_planned", [], []), false, "no labels stays closed");
eq(shouldReopen("not_planned", ["bug"], []), false, "non-agent label stays closed");
eq(shouldReopen("not_planned", ["agent-blocked"], []), false, "agent-blocked is not protected (only ready/in-progress)");

// Defensive: bad input shapes.
eq(shouldReopen("not_planned", null, []), false, "null labels stays closed");
eq(shouldReopen("not_planned", "agent-ready", []), false, "string labels stays closed");
eq(shouldReopen("not_planned", ["agent-ready"], null), true, "null linkedPrStates treated as none -> reopens");

// PROTECTED_LABEL_NAMES is the single source of truth the workflow YAML `if` mirrors.
if (!PROTECTED_LABEL_NAMES.includes("agent-ready") || !PROTECTED_LABEL_NAMES.includes("agent-in-progress")) {
  throw new Error(`PROTECTED_LABEL_NAMES must list both protected labels, got ${JSON.stringify(PROTECTED_LABEL_NAMES)}`);
}

// linkedPrNumbersFromTimeline: only cross-referenced PRs (not plain issues) count.
const timeline = [
  { event: "cross-referenced", source: { issue: { number: 12, pull_request: { url: "x" } } } },
  { event: "cross-referenced", source: { issue: { number: 13 } } }, // plain issue, not a PR
  { event: "cross-referenced", source: { issue: { number: 14, pull_request: {} } } },
  { event: "labeled", label: { name: "agent-ready" } },
  { event: "closed" },
];
const nums = linkedPrNumbersFromTimeline(timeline);
if (nums.length !== 2 || !nums.includes(12) || !nums.includes(14)) {
  throw new Error(`timeline must yield PRs 12 and 14 only, got ${JSON.stringify(nums)}`);
}
if (linkedPrNumbersFromTimeline(null).length !== 0) throw new Error("null timeline yields []");
if (linkedPrNumbersFromTimeline([]).length !== 0) throw new Error("empty timeline yields []");

console.log("OK: mass-close-guard shouldReopen + linkedPrNumbersFromTimeline decision matrix");
' || fail "pure function tests failed"

echo "OK: mass-close-guard.mjs decision matrix"
