#!/usr/bin/env bash
# tests/repo-standards.test.sh — offline, deterministic tests for the
# repo-standards machinery. No network; exercises the exceptions parser and the
# standards lib against fixtures. Run by ci.yml: `bash tests/repo-standards.test.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok() { echo "ok $1"; pass=$((pass+1)); }
ko() { echo "FAIL $1"; fail=$((fail+1)); }

# --- Exceptions parser: honored vs proposed ---
cat > /tmp/exc-good.yml <<'YML'
# declared exceptions for a repo
- rule: branch-protection
  reason: "legacy repo, manual control retained"
  decided: "2026-08-25"
  decided_by: nish
- rule: thin-caller:semgrep.yml
  reason: "repo has no JS; semgrep not applicable"
  decided: "2026-08-26"
  decided_by: nish
YML

node --input-type=module - <<'JS'
import { ExceptionsFile, KNOWN_EXCEPTION_RULES } from "./.github/scripts/standards-exceptions.mjs";
import { readFileSync } from "node:fs";
const text = readFileSync("/tmp/exc-good.yml", "utf8");
const exc = new ExceptionsFile(text, "test/good");
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
assert(exc.exceptions.length === 2, "two Nish-approved exceptions honored");
assert(exc.proposed.length === 0, "no proposed-only exceptions");
assert(exc.isExcepted("branch-protection"), "branch-protection excepted");
assert(exc.isExcepted("thin-caller:semgrep.yml"), "thin-caller:semgrep.yml excepted");
assert(!exc.isExcepted("label-triad"), "label-triad NOT excepted");
assert(exc.errors.length === 0, "no parse errors");
assert(KNOWN_EXCEPTION_RULES.includes("branch-protection"), "branch-protection is a known rule");
JS
ok "exceptions parser: honors decided_by: nish"

# --- Exceptions parser: proposed (not nish) is NOT honored ---
cat > /tmp/exc-proposed.yml <<'YML'
- rule: label-triad
  reason: "agent proposes skipping"
  decided: "2026-08-26"
  decided_by: claude-vps
YML
node --input-type=module - <<'JS'
import { ExceptionsFile } from "./.github/scripts/standards-exceptions.mjs";
import { readFileSync } from "node:fs";
const text = readFileSync("/tmp/exc-proposed.yml", "utf8");
const exc = new ExceptionsFile(text, "test/proposed");
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
assert(exc.exceptions.length === 0, "non-nish exception NOT honored");
assert(exc.proposed.length === 1, "non-nish exception captured as proposed");
assert(!exc.isExcepted("label-triad"), "label-triad NOT excepted (proposed only)");
JS
ok "exceptions parser: non-nish decided_by is proposed, not honored"

# --- Exceptions parser: missing rule is an error ---
cat > /tmp/exc-bad.yml <<'YML'
- reason: "no rule field"
  decided: "2026-08-26"
  decided_by: nish
YML
node --input-type=module - <<'JS'
import { ExceptionsFile } from "./.github/scripts/standards-exceptions.mjs";
import { readFileSync } from "node:fs";
const text = readFileSync("/tmp/exc-bad.yml", "utf8");
const exc = new ExceptionsFile(text, "test/bad");
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
assert(exc.errors.length > 0, "missing rule field is a parse error");
assert(exc.exceptions.length === 0, "no exception honored from bad entry");
JS
ok "exceptions parser: missing rule is an error"

# --- Standards lib: classifyRepo ---
node --input-type=module - <<'JS'
import { classifyRepo, isHandsOff, isLocalRicher, LABEL_TRIAD, THIN_CALLERS, REPO_TYPES } from "./.github/scripts/repo-standards.lib.mjs";
const assert = (cond, msg) => { if (!cond) { console.error("FAIL " + msg); process.exit(1); } else console.error("ok " + msg); };
assert(classifyRepo("0509", ["TypeScript"]) === "node_app", "0509 -> node_app");
assert(classifyRepo("fleet-ops", ["TypeScript"]) === "infra", "fleet-ops -> infra");
assert(classifyRepo("inish-site", ["HTML"]) === "static_site", "inish-site -> static_site");
assert(isHandsOff("Nishfleet/fleet2"), "fleet2 is hands-off");
assert(!isHandsOff("Nishfleet/0509"), "0509 is not hands-off");
assert(isLocalRicher("Nishfleet/0509"), "0509 is local-richer");
assert(LABEL_TRIAD.length === 3, "label triad has 3 labels");
assert(THIN_CALLERS.length === 4, "4 thin callers (gitleaks, semgrep, review-gate, auto-enqueue)");
assert(REPO_TYPES.node_app.merge_queue === true, "node_app has merge queue");
assert(REPO_TYPES.static_site.merge_queue === false, "static_site has no merge queue");
assert(REPO_TYPES.archive.skip === true, "archive type is skipped");
JS
ok "standards lib: classifyRepo + type table"

# --- stray worker notes at the repo root (fleet-ops#3682 committed pr-body-3376.md + verification-3376.md) ---
stray=""
for f in pr-body-*.md verification-*.md PR_BODY*.md; do [ -e "$f" ] && stray="$stray$f "; done
if [ -z "$stray" ]; then ok "repo root carries no stray worker notes (pr-body-*.md / verification-*.md)"; else ko "stray worker notes at repo root: $stray — PR bodies belong in the PR, not the tree"; fi

echo
echo "repo-standards tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
