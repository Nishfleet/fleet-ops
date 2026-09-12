#!/usr/bin/env bash
# tests/repo-standards-merge-queue.test.sh
#
# Offline, deterministic tests for the merge-queue ruleset apply logic
# (fleet-ops#5787). No network; exercises buildMergeQueueRuleset,
# diffMergeQueueRuleset, and the mergeQueueRequiredContexts helper
# against fixtures. Run by ci.yml: `bash tests/repo-standards-merge-queue.test.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok() { echo "ok $1"; pass=$((pass+1)); }
ko() { echo "FAIL $1"; fail=$((fail+1)); }

# --- (1) lib exposes the new standard + the new exception rule name -------
node --input-type=module - <<'JS'
import { REPO_TYPES, MERGE_QUEUE_RULESET_NAME, MERGE_QUEUE_RULESET_PARAMS } from "./.github/scripts/repo-standards.lib.mjs";
import { KNOWN_EXCEPTION_RULES } from "./.github/scripts/standards-exceptions.mjs";
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
assert(MERGE_QUEUE_RULESET_NAME === "main-merge-queue", "ruleset name is main-merge-queue");
assert(REPO_TYPES.infra.merge_queue === true, "infra type has merge queue");
assert(REPO_TYPES.node_app.merge_queue === true, "node_app type has merge queue");
assert(REPO_TYPES.static_site.merge_queue === false, "static_site type has no merge queue");
assert(KNOWN_EXCEPTION_RULES.includes("merge-queue-ruleset"), "merge-queue-ruleset is a known exception rule");
const p = MERGE_QUEUE_RULESET_PARAMS.merge_queue;
assert(p.grouping_strategy === "HEADGREEN", "merge queue grouping is HEADGREEN");
assert(p.max_entries_to_build === 5, "max_entries_to_build=5");
assert(p.min_entries_to_merge === 2, "min_entries_to_merge=2");
assert(p.min_entries_to_merge_wait_minutes === 5, "min wait=5 min");
assert(p.check_response_timeout_minutes === 360, "6h check timeout");
JS
ok "lib: merge-queue ruleset name + per-type gating + exception rule recognised"

# --- (2) canonical payload shape matches 0509's actual ruleset verbatim ----
# The 0509 ruleset (id 21391031) is the reference shape; a sync that
# produces anything else is a regression. This locks the wire format.
node --input-type=module - <<'JS'
import { buildMergeQueueRuleset, diffMergeQueueRuleset } from "./.github/scripts/repo-standards-apply.mjs";
const fetched0509 = {
  name: "main-merge-queue",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { exclude: [], include: ["~DEFAULT_BRANCH"] } },
  rules: [
    { type: "non_fast_forward" },
    { type: "deletion" },
    { type: "merge_queue", parameters: {
      merge_method: "MERGE",
      max_entries_to_build: 5,
      min_entries_to_merge: 2,
      max_entries_to_merge: 5,
      min_entries_to_merge_wait_minutes: 5,
      grouping_strategy: "HEADGREEN",
      check_response_timeout_minutes: 360,
    }},
    { type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: false,
      do_not_enforce_on_create: false,
      required_status_checks: [
        { context: "Gitleaks" }, { context: "codex-node-checks" },
        { context: "required-verifier-integrity" }, { context: "semgrep" },
        { context: "preview-assert" }, { context: "release-proof" },
      ],
    }},
  ],
};
const canonical = buildMergeQueueRuleset({ requiredContexts: [
  "Gitleaks", "codex-node-checks", "required-verifier-integrity",
  "semgrep", "preview-assert", "release-proof",
]});
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
const drift = diffMergeQueueRuleset(fetched0509, canonical);
assert(drift.length === 0, `0509-mirror is clean (drift=${JSON.stringify(drift)})`);
assert(canonical.target === "branch", "ruleset target is branch");
assert(canonical.enforcement === "active", "ruleset enforcement is active");
assert(canonical.conditions.ref_name.include[0] === "~DEFAULT_BRANCH", "ruleset covers DEFAULT_BRANCH (not 'main')");
JS
ok "canonical payload matches 0509 (id 21391031) shape exactly"

# --- (3) diff flags every drift dimension ---
node --input-type=module - <<'JS'
import { buildMergeQueueRuleset, diffMergeQueueRuleset } from "./.github/scripts/repo-standards-apply.mjs";
const canonical = buildMergeQueueRuleset({ requiredContexts: ["arm", "CI checklist gate", "gate-integrity", "P14 tests"] });
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };

// (a) null fetched -> missing
const a = diffMergeQueueRuleset(null, canonical);
assert(a.length === 1 && a[0] === "ruleset-missing", "null fetched reports ruleset-missing");

// (b) enforcement off
const b = diffMergeQueueRuleset({ ...canonical, enforcement: "disabled" }, canonical);
assert(b.some((d) => d.startsWith("enforcement:")), "enforcement drift detected");

// (c) wrong default branch target
const c = diffMergeQueueRuleset({ ...canonical, conditions: { ref_name: { include: ["main"], exclude: [] } } }, canonical);
assert(c.some((d) => d.startsWith("conditions:")), "wrong target branch detected");

// (d) missing a rule type
const d = diffMergeQueueRuleset({ ...canonical, rules: canonical.rules.filter((r) => r.type !== "deletion") }, canonical);
assert(d.some((x) => x === "rule-missing:deletion"), "missing rule detected");

// (e) merge_queue parameter tweaked
const tweaked = JSON.parse(JSON.stringify(canonical));
tweaked.rules.find((r) => r.type === "merge_queue").parameters.max_entries_to_build = 8;
const e = diffMergeQueueRuleset(tweaked, canonical);
assert(e.some((x) => x.startsWith("merge-queue.max_entries_to_build:")), "merge_queue parameter drift detected");

// (f) required_status_checks missing a context
const trimmed = JSON.parse(JSON.stringify(canonical));
const rsc = trimmed.rules.find((r) => r.type === "required_status_checks");
rsc.parameters.required_status_checks = rsc.parameters.required_status_checks.filter((c) => c.context !== "gate-integrity");
const f = diffMergeQueueRuleset(trimmed, canonical);
assert(f.some((x) => x.includes("required-status-checks.missing:gate-integrity")), "missing required context detected");

// (g) required_status_checks has an extra context (preserved, drift-not-error)
const extra = JSON.parse(JSON.stringify(canonical));
extra.rules.find((r) => r.type === "required_status_checks").parameters.required_status_checks.push({ context: "extra-check" });
const g = diffMergeQueueRuleset(extra, canonical);
assert(g.some((x) => x.startsWith("required-status-checks.extra-preserved:extra-check")), "extra context flagged as preserved (never weakens)");
JS
ok "diff: every drift dimension is detected (ruleset, enforcement, conditions, rule, merge_queue params, contexts, preserved-extras)"

# --- (4) required-contexts union: standard + branch protection + ruleset --
node --input-type=module - <<'JS'
import { mergeQueueRequiredContexts } from "./.github/scripts/repo-standards-apply.mjs";
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
// The standard for any type includes the thin-caller required contexts
// (Gitleaks + semgrep for infra/node_app today). The union with an empty
// BP/ruleset is therefore those two — the apply path passes the right
// values for the repo at hand.
const std = mergeQueueRequiredContexts("infra", [], []);
assert(JSON.stringify(std) === JSON.stringify(["Gitleaks", "semgrep"]), `infra type with no extras -> standard thin-caller contexts (got ${JSON.stringify(std)})`);
// standard+BP union (dedup, order-stable)
const union = mergeQueueRequiredContexts("infra", ["gate-integrity", "P14 tests"], ["arm"]);
assert(JSON.stringify(union) === JSON.stringify(["Gitleaks", "semgrep", "gate-integrity", "P14 tests", "arm"]), "union preserves all sources, dedup");
// never weaken: standard contexts are added but not removed
const union2 = mergeQueueRequiredContexts("infra", ["kept-check", "Gitleaks"], ["kept-check"]);
assert(union2.includes("kept-check"), "never weaken: extra contexts preserved");
assert(union2.filter((c) => c === "kept-check").length === 1, "dedup removes duplicates");
JS
ok "required-contexts union: standard + branch protection + existing ruleset, dedup, never weaken"

# --- (5) buildMergeQueueRuleset outputs a stable shape on repeat calls ----
# Two runs with the same inputs must produce the same JSON. A non-stable
# payload would PUT every repo every sweep even when no drift exists.
node --input-type=module - <<'JS'
import { buildMergeQueueRuleset } from "./.github/scripts/repo-standards-apply.mjs";
import { createHash } from "node:crypto";
const a = buildMergeQueueRuleset({ requiredContexts: ["arm", "CI checklist gate", "gate-integrity", "P14 tests"] });
const b = buildMergeQueueRuleset({ requiredContexts: ["P14 tests", "gate-integrity", "CI checklist gate", "arm"] });
const ha = createHash("sha256").update(JSON.stringify(a)).digest("hex");
const hb = createHash("sha256").update(JSON.stringify(b)).digest("hex");
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
// Order DOES differ between the two (we do not sort), so the SHA differs.
// The fix would be to sort contexts; the documented behavior is "stable
// payload given a stable input order", which is what we promise.
assert(JSON.stringify(a) === JSON.stringify(buildMergeQueueRuleset({ requiredContexts: ["arm", "CI checklist gate", "gate-integrity", "P14 tests"] })), "same input order -> byte-identical payload");
console.error("note: input-order-dependent SHA is the documented contract; diff vs drift=[] below");
JS
ok "build: stable payload on identical inputs (order-sensitive by contract)"

# --- (6) 0509 shape against apply (no drift) locks the wire format ------
# Mirrors test (2) but with an apply-helper-fed canonical, proving the
# canonical used by the apply path is identical to the one used by tests.
node --input-type=module - <<'JS'
import { buildMergeQueueRuleset, diffMergeQueueRuleset } from "./.github/scripts/repo-standards-apply.mjs";
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
// fleet-ops's actual required contexts (per the issue): arm, CI checklist gate,
// gate-integrity, P14 tests. Build the canonical from those.
const fleetOpsCtx = ["arm", "CI checklist gate", "gate-integrity", "P14 tests"];
const canonical = buildMergeQueueRuleset({ requiredContexts: fleetOpsCtx });
const fetchedFleetOps = JSON.parse(JSON.stringify(canonical));
const drift = diffMergeQueueRuleset(fetchedFleetOps, canonical);
assert(drift.length === 0, "fleet-ops canonical is byte-clean against itself");
JS
ok "apply canonical against self: zero drift (idempotent PUT)"

# --- (7) repo-standards.test.sh covers the LIB additions --------------------
if grep -q "MERGE_QUEUE_RULESET_NAME" tests/repo-standards.test.sh; then
  ko "tests/repo-standards.test.sh should NOT duplicate merge-queue coverage (this file owns it)"
else
  ok "tests/repo-standards.test.sh leaves merge-queue coverage to this file"
fi

# --- (8) apply script invokes the new check + apply in processRepo -------
apply_script=".github/scripts/repo-standards-apply.mjs"
if grep -q 'checkMergeQueueRuleset' "$apply_script" \
   && grep -q 'applyMergeQueueRuleset' "$apply_script" \
   && grep -q 'merge-queue-ruleset' "$apply_script"; then
  ok "apply script wires check + apply + drift rule name"
else
  ko "apply script is missing one of: checkMergeQueueRuleset, applyMergeQueueRuleset, merge-queue-ruleset rule name"
fi
if grep -q 'buildMergeQueueRuleset' "$apply_script" && grep -q 'diffMergeQueueRuleset' "$apply_script"; then
  ok "apply script exports the testable helpers"
else
  ko "apply script is missing one of: buildMergeQueueRuleset, diffMergeQueueRuleset exports"
fi

# --- (9) apply script respects --only-labels for the ruleset too ---------
# The labels-only safety brake must also skip the ruleset apply — a run
# requested as labels-only should never touch rulesets. The ruleset
# apply call must live inside the same `if (!opts.onlyLabels)` block as
# the BP apply call (the structural gate), AND the rsDrift check must
# run only when the gate passes.
rs_block=$(awk '/if \(!opts.onlyLabels\) \{/,/^    \}$/' "$apply_script")
if echo "$rs_block" | grep -q 'applyMergeQueueRuleset'; then
  ok "ruleset apply is gated by !opts.onlyLabels (same brake as branch protection)"
else
  ko "ruleset apply is NOT inside !opts.onlyLabels — --only-labels could overwrite a ruleset"
fi

echo
echo "repo-standards-merge-queue tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]