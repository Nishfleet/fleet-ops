#!/usr/bin/env bash
# tests/ci-checklist-gate.test.sh
#
# Proves the CI checklist gate without reaching GitHub. The gate parses a PR
# body for markdown checkboxes and fails when a required checkbox (in a
# ## Verification section or with a "required:" prefix) is unchecked.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/ci-checklist-gate.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "ci-checklist-gate.mjs not found: $script"
node --check "$script" || fail "ci-checklist-gate.mjs failed node --check"
node "$script" --help >/dev/null || fail "ci-checklist-gate.mjs --help failed"

cd "$repo_root"

# run <body> <expected-rc> [must-contain]
run() {
  local body="$1" expected="$2" contain="${3:-}"
  local rc=0 out=""
  out=$(BODY="$body" node "$script" --body-env BODY 2>&1) || rc=$?
  if [[ "$rc" -ne "$expected" ]]; then
    fail "expected rc=$expected, got rc=$rc; output:\n$out"
  fi
  if [[ -n "$contain" && "$out" != *"$contain"* ]]; then
    fail "expected output to contain '$contain'; output:\n$out"
  fi
  ok "body produced rc=$expected"
}

# Empty body has no required checkboxes.
run "" 0 "all required checkboxes are checked"

# Plain checkbox with no required marker is ignored.
run "- [ ] optional thing" 0 "all required checkboxes are checked"

# Required prefix, checked.
run "- [x] required: CI codex-node-checks" 0 "all required checkboxes are checked"

# Required prefix, unchecked.
run "- [ ] required: CI codex-node-checks" 1 "CI codex-node-checks"

# Required prefix is case-insensitive and optional bold/italic.
run "- [ ] **Required:** CI codex-node-checks" 1 "CI codex-node-checks"

# Verification section: all items are required.
run $'## Verification\n- [ ] CI unit tests' 1 "CI unit tests"

# Verification section with all boxes checked.
run $'## Verification\n- [x] CI unit tests\n- [x] Manual QA' 0 "all required checkboxes are checked"

# Verification section ends at the next same-level heading.
run $'## Plan\n- [ ] unchecked plan item\n## Verification\n- [ ] CI unit tests' 1 "CI unit tests"

# A non-required checkbox outside a Verification section is ignored.
run $'## Verification\n- [x] CI unit tests\n## Notes\n- [ ] optional note' 0 "all required checkboxes are checked"

# Verification subsection (h3) still inside the Verification section.
run $'## Verification\n- [x] CI unit tests\n### Details\n- [ ] sign-off' 1 "sign-off"

# Required marker outside a Verification section still counts.
run $'## Plan\n- [x] research\n- [ ] required: sign legal review' 1 "sign legal review"

# Mixed list markers.
run $'* [ ] required: asterisk item\n+ [x] required: plus item' 1 "asterisk item"

# JSON format reports the unchecked item.
out=$(BODY=$'## Verification\n- [ ] CI unit tests' node "$script" --body-env BODY --format json) || true
printf '%s' "$out" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const data = JSON.parse(readFileSync(0, "utf8"));
if (data.status !== "fail") throw new Error("json status must be fail");
if (data.unchecked_required.length !== 1) throw new Error("expected one unchecked item");
if (data.unchecked_required[0].text !== "CI unit tests") throw new Error("unexpected text: " + data.unchecked_required[0].text);
if (data.unchecked_required[0].in_verification !== true) throw new Error("item must be in verification");
console.log("OK: json report shape");
'

echo "OK: ci-checklist-gate.mjs behavior and output"
