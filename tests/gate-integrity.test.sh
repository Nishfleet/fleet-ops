#!/usr/bin/env bash
# tests/gate-integrity.test.sh — deterministic fixture regression for the
# generalized gate-integrity decision logic (fleet-ops#247).
#
# Port of 0509's .github/scripts/test-gate-integrity.sh. Default fixtures
# pass 0509's gate-globs / ratchet paths as INPUTS so a behavior change
# against that config is a failed run. Extra fixtures prove the same
# classes honor a different marker, glob, or ratchet path.
#
# Exercises the exact shipped bytes of .github/scripts/gate-integrity.sh
# against fixed context bundles (no network, no mutation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
DECISION="$repo_root/.github/scripts/gate-integrity.sh"
[[ -f "$DECISION" ]] || { echo "FAIL: missing $DECISION" >&2; exit 1; }
PASS_COUNT=0
FAIL_COUNT=0
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gi-fixtures.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

HEAD="1111111111111111111111111111111111111111"
OLD="2222222222222222222222222222222222222222"

GATE_GLOBS='[".github/workflows/**",".github/scripts/**",".github/CODEOWNERS",".gitleaksignore",".gitleaks.toml",".semgrepignore",".semgrep.yml",".semgrep.yaml","scripts/design-system-ratchet.mjs","docs/design-system-ratchet.json","scripts/ci-vitest-run.sh","scripts/ci-verify-*.sh"]'
RATCHET_PATHS='["docs/design-system-ratchet.json"]'

# build_bundle <name> — reads a python expression from $FIXTURE_SRC.
build_bundle() {
  local name="$1"
  FIXTURE_SRC="$FIXTURE_SRC" GATE_GLOBS="$GATE_GLOBS" RATCHET_PATHS="$RATCHET_PATHS" HEAD="$HEAD" OLD="$OLD" \
    python3 - "$WORK_DIR/$name.json" <<'PY'
import json, os, sys
HEAD = os.environ["HEAD"]
OLD = os.environ["OLD"]
GATE_GLOBS = json.loads(os.environ["GATE_GLOBS"])
RATCHET_PATHS = json.loads(os.environ["RATCHET_PATHS"])
# Shorthands the fixture expressions below refer to by name.
ADMIN = {"nish3451": "admin"}
ATTEST = [{"user": "nish3451", "sha": HEAD}]
# Deterministic fixture data; eval is safe here (no untrusted input).
bundle = eval(os.environ["FIXTURE_SRC"])
bundle.setdefault("head_sha", HEAD)
bundle.setdefault("gate_globs", GATE_GLOBS)
bundle.setdefault("ratchet_paths", RATCHET_PATHS)
bundle.setdefault("commit_messages", [])
bundle.setdefault("pr_body", "")
bundle.setdefault("attestations", [])
bundle.setdefault("auto_revert_attestations", [])
bundle.setdefault("permissions", {})
bundle.setdefault("admin_attestation_marker", "gate-integrity-attest")
bundle.setdefault("auto_revert_attestation_marker", "gate-integrity-auto-revert")
bundle.setdefault("auto_revert_body_opener", "Automatic revert opened because a push-to-main CI workflow went red.")
bundle.setdefault("git_revert_subject_prefix", 'Revert "')
bundle.setdefault("test_removal_trailer", "test-removal-justified")
with open(sys.argv[1], "w") as fh:
    json.dump(bundle, fh)
PY
}

# run_fixture <name> <PASS|FAIL> [must-contain] [must-not-contain]
run_fixture() {
  local name="$1" expected="$2" must_contain="${3:-}" must_not_contain="${4:-}"
  local rc=0 out="" ok=0 why=""
  out="$(bash "$DECISION" < "$WORK_DIR/$name.json")" || rc=$?
  if [[ "$expected" == "PASS" && $rc -eq 0 && "$out" == *"PASS:"* ]]; then ok=1; fi
  # Both verdicts are matched anywhere in the output, not anchored at the
  # start: a bundle may legitimately emit `::notice::` lines (e.g. an
  # oversized diff with no patch) before the verdict line.
  if [[ "$expected" == "FAIL" && $rc -ne 0 && "$out" == *"FAIL:"* ]]; then ok=1; fi
  if [[ $ok -eq 1 && -n "$must_contain" && "$out" != *"$must_contain"* ]]; then
    ok=0; why=" (missing expected output: $must_contain)"
  fi
  if [[ $ok -eq 1 && -n "$must_not_contain" && "$out" == *"$must_not_contain"* ]]; then
    ok=0; why=" (found forbidden output: $must_not_contain)"
  fi
  if [[ $ok -eq 1 ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok   %s\n' "$name"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s: expected %s, got rc=%s%s\n' "$name" "$expected" "$rc" "$why"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

fixture() { FIXTURE_SRC="$2"; build_bundle "$1"; }


# --- clean diffs ------------------------------------------------------------
fixture ordinary '{"files": [{"filename": "app/routes/home.tsx", "status": "modified", "patch": "+const x = 1"}]}'
run_fixture ordinary PASS

fixture tests_added '{"files": [{"filename": "tests/new.test.ts", "status": "added", "patch": "+it(\"works\", () => { expect(1).toBe(1); });"}]}'
run_fixture tests_added PASS

fixture test_refactor_net_positive '{"files": [
  {"filename": "tests/a.test.ts", "status": "modified", "patch": "-it(\"a\", () => {});\n+it(\"a\", () => {});\n+it(\"b\", () => {});"}]}'
run_fixture test_refactor_net_positive PASS

# --- test-integrity: deletion ----------------------------------------------
fixture test_deleted '{"files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture test_deleted FAIL "test file deleted: tests/auth.test.ts"

fixture test_deleted_justified_commit '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}],
  "commit_messages": ["test: fold auth cases into session suite\n\ntest-removal-justified: cases moved verbatim to tests/session.test.ts"]}'
run_fixture test_deleted_justified_commit PASS "test-integrity waived"

fixture test_deleted_justified_body '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}],
  "pr_body": "Closes #1\n\ntest-removal-justified: suite replaced by the workerd integration suite"}'
run_fixture test_deleted_justified_body PASS "test-integrity waived"

fixture test_trailer_empty '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}],
  "commit_messages": ["chore\n\ntest-removal-justified:"]}'
run_fixture test_trailer_empty FAIL "no \`test-removal-justified:\` trailer"

# --- test-integrity: rename out of the suite --------------------------------
fixture test_renamed_away '{"files": [
  {"filename": "app/lib/old-auth-checks.ts", "previous_filename": "tests/auth.test.ts", "status": "renamed", "patch": "+// moved"}]}'
run_fixture test_renamed_away FAIL "renamed out of the suite"

fixture test_renamed_within '{"files": [
  {"filename": "tests/auth-v2.test.ts", "previous_filename": "tests/auth.test.ts", "status": "renamed", "patch": "+// moved"}]}'
run_fixture test_renamed_within PASS

# --- test-integrity: skip/only/todo -----------------------------------------
fixture test_skipped '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified", "patch": "-it(\"a\", () => {});\n+it.skip(\"a\", () => {});"}]}'
run_fixture test_skipped FAIL "test disabled in tests/auth.test.ts"

fixture test_only '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified", "patch": "-describe(\"a\", () => {});\n+describe.only(\"a\", () => {});"}]}'
run_fixture test_only FAIL "test disabled in tests/auth.test.ts"

fixture test_xit '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified", "patch": "+xit(\"a\", () => {});"}]}'
run_fixture test_xit FAIL "test disabled in tests/auth.test.ts"

fixture skip_marker_in_app_code '{"files": [
  {"filename": "app/lib/queue.ts", "status": "modified", "patch": "+  // it.skip is mentioned here in a comment"}]}'
run_fixture skip_marker_in_app_code PASS

# --- test-integrity: net assertion loss -------------------------------------
fixture assertions_gutted '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified",
   "patch": "-  expect(a).toBe(1);\n-  expect(b).toBe(2);\n-  expect(c).toBe(3);\n+  // TODO"}]}'
run_fixture assertions_gutted FAIL "net assertion count fell by 3"

fixture assertions_gutted_justified '{
  "files": [{"filename": "tests/auth.test.ts", "status": "modified",
             "patch": "-  expect(a).toBe(1);\n-  expect(b).toBe(2);\n-  expect(c).toBe(3);\n+  // TODO"}],
  "commit_messages": ["test-removal-justified: assertions moved into the property-based suite"]}'
run_fixture assertions_gutted_justified PASS "test-integrity waived"

# --- gate-path: workflow edits ----------------------------------------------
fixture workflow_edited '{"files": [
  {"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}]}'
run_fixture workflow_edited FAIL "gate-owned path changed"

fixture workflow_edited_attested '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture workflow_edited_attested PASS "gate-path waived"

fixture workflow_attested_stale '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": [{"user": "nish3451", "sha": OLD}], "permissions": ADMIN}'
run_fixture workflow_attested_stale FAIL "stale: a newer commit was pushed after it"

fixture workflow_attested_nonadmin '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": [{"user": "worker", "sha": HEAD}], "permissions": {"worker": "write"}}'
run_fixture workflow_attested_nonadmin FAIL "not admin"

fixture workflow_attested_maintainer '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": [{"user": "m", "sha": HEAD}], "permissions": {"m": "maintain"}}'
run_fixture workflow_attested_maintainer FAIL "not admin"

fixture workflow_deleted '{"files": [
  {"filename": ".github/workflows/gate-integrity.yml", "status": "removed", "patch": "-name: gate-integrity"}]}'
run_fixture workflow_deleted FAIL "gate-owned path changed (removed)"

fixture gate_script_deleted '{"files": [
  {"filename": ".github/scripts/gate-integrity.sh", "status": "removed", "patch": "-set -euo pipefail"}]}'
run_fixture gate_script_deleted FAIL "gate-owned path changed (removed)"

fixture codeowners_edited '{"files": [
  {"filename": ".github/CODEOWNERS", "status": "modified", "patch": "-* @nish3451\n+"}]}'
run_fixture codeowners_edited FAIL "gate-owned path changed"

# --- gate-path: ignore files ------------------------------------------------
fixture gitleaksignore_edited '{"files": [
  {"filename": ".gitleaksignore", "status": "modified", "patch": "+abc123:app/secret.ts:generic-api-key:1"}]}'
run_fixture gitleaksignore_edited FAIL "gate-owned path changed"

fixture semgrepignore_added '{"files": [
  {"filename": ".semgrepignore", "status": "added", "patch": "+app/"}]}'
run_fixture semgrepignore_added FAIL "gate-owned path changed"

# --- gate-path: CI softeners ------------------------------------------------
fixture ci_softener_or_true '{"files": [
  {"filename": ".github/workflows/uptime-health.yml", "status": "modified", "patch": "+          npm run check || true"}]}'
run_fixture ci_softener_or_true FAIL "CI step softened"

fixture ci_softener_continue '{"files": [
  {"filename": ".github/workflows/uptime-health.yml", "status": "modified", "patch": "+        continue-on-error: true"}]}'
run_fixture ci_softener_continue FAIL "CI step softened"

fixture softener_in_ungated_script '{"files": [
  {"filename": "scripts/local-helper.sh", "status": "modified", "patch": "+  grep foo bar || true"}]}'
run_fixture softener_in_ungated_script FAIL "CI step softened"

# Prose that NAMES a banned construct is not that construct. The very first run
# of this check against real PR data flagged its own workflow header, because
# the header contains a sentence explaining what `|| true` does.
fixture softener_in_yaml_comment '{"files": [
  {"filename": ".github/workflows/gate-integrity.yml", "status": "added",
   "patch": "+# a PR can append `|| true` or `continue-on-error: true` to a CI step"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture softener_in_yaml_comment PASS "gate-path waived" "CI step softened"

# A brand-new workflow cannot *soften* a step that did not exist, and a shell
# `test`/`[` conditional is not a CI test step even when it contains `|| true`.
fixture added_workflow_shell_guard '{"files": [
  {"filename": ".github/workflows/ratchet-auto-tighten.yml", "status": "added",
   "patch": "+          test -z \"$(git symbolic-ref --quiet HEAD 2>/dev/null || true)\""}]}'
run_fixture added_workflow_shell_guard FAIL "gate-owned path changed (added)" "CI step softened"

fixture added_workflow_shell_guard_attested '{
  "files": [{"filename": ".github/workflows/ratchet-auto-tighten.yml", "status": "added",
   "patch": "+          test -z \"$(git symbolic-ref --quiet HEAD 2>/dev/null || true)\""}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture added_workflow_shell_guard_attested PASS "gate-path waived" "CI step softened"

fixture modified_script_shell_guard '{"files": [
  {"filename": "scripts/local-helper.sh", "status": "modified",
   "patch": "+  test -z \"$(git symbolic-ref --quiet HEAD 2>/dev/null || true)\""}]}'
run_fixture modified_script_shell_guard PASS

fixture modified_script_bracket_guard '{"files": [
  {"filename": "scripts/local-helper.sh", "status": "modified",
   "patch": "+  [ 1 -eq 2 ] || true"}]}'
run_fixture modified_script_bracket_guard PASS

fixture modified_script_double_bracket_guard '{"files": [
  {"filename": "scripts/local-helper.sh", "status": "modified",
   "patch": "+  [[ 1 -eq 2 ]] || true"}]}'
run_fixture modified_script_double_bracket_guard PASS

fixture workflow_run_test_guard_attested '{
  "files": [{"filename": ".github/workflows/uptime-health.yml", "status": "modified",
   "patch": "+        run: test -z \"$(git symbolic-ref --quiet HEAD 2>/dev/null || true)\""}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture workflow_run_test_guard_attested PASS "gate-path waived" "CI step softened"

fixture skip_in_test_comment '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified",
   "patch": "+  // do not use it.skip here; the gate rejects it"}]}'
run_fixture skip_in_test_comment PASS

# Commenting a test OUT is still a real assertion loss, so comment exclusion
# must apply symmetrically to added and removed lines, never only to added.
fixture assertions_commented_out '{"files": [
  {"filename": "tests/auth.test.ts", "status": "modified",
   "patch": "-  expect(a).toBe(1);\n-  expect(b).toBe(2);\n+  // expect(a).toBe(1);\n+  // expect(b).toBe(2);"}]}'
run_fixture assertions_commented_out FAIL "net assertion count fell by 2"

# --- gate-path: ratchet weakening -------------------------------------------
fixture ratchet_raised '{"files": [
  {"filename": "docs/design-system-ratchet.json", "status": "modified",
   "patch": "-  \"raw-hex-color\": 258,\n+  \"raw-hex-color\": 400,"}]}'
run_fixture ratchet_raised FAIL "raised 258 -> 400"

fixture ratchet_key_deleted '{"files": [
  {"filename": "docs/design-system-ratchet.json", "status": "modified",
   "patch": "-  \"css-important\": 26,"}]}'
run_fixture ratchet_key_deleted FAIL "was deleted (was 26)"

fixture ratchet_lowered '{"files": [
  {"filename": "docs/design-system-ratchet.json", "status": "modified",
   "patch": "-  \"raw-hex-color\": 258,\n+  \"raw-hex-color\": 12,"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture ratchet_lowered PASS "gate-path waived" "raised"

fixture ratchet_script_edited '{"files": [
  {"filename": "scripts/design-system-ratchet.mjs", "status": "modified", "patch": "+// tweak"}]}'
run_fixture ratchet_script_edited FAIL "gate-owned path changed"

# --- both classes at once ---------------------------------------------------
fixture both_classes '{"files": [
  {"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
  {"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}]}'
run_fixture both_classes FAIL "test file deleted"

fixture both_classes_one_remedy '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
            {"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture both_classes_one_remedy FAIL "no \`test-removal-justified:\` trailer"

fixture both_classes_both_remedies '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
            {"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "commit_messages": ["test-removal-justified: folded into the workerd suite"],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture both_classes_both_remedies PASS "gate-path waived"

# --- an attestation must never waive a test-integrity violation -------------
fixture attestation_does_not_waive_tests '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture attestation_does_not_waive_tests FAIL "test file deleted"

# --- a trailer must never waive a gate-path violation -----------------------
fixture trailer_does_not_waive_gate '{
  "files": [{"filename": ".gitleaksignore", "status": "modified", "patch": "+abc:app/x.ts:key:1"}],
  "commit_messages": ["test-removal-justified: unrelated"]}'
run_fixture trailer_does_not_waive_gate FAIL "gate-owned path changed"

# --- waivers must be loud ---------------------------------------------------
fixture clean_is_quiet '{"files": [{"filename": "README.md", "status": "modified", "patch": "+text"}]}'
run_fixture clean_is_quiet PASS "" "::warning"

# --- fail closed ------------------------------------------------------------
printf 'not json' > "$WORK_DIR/malformed.json"
run_fixture malformed FAIL "context bundle is not valid JSON"

printf '[]' > "$WORK_DIR/not_object.json"
run_fixture not_object FAIL "context bundle is not a JSON object"

printf '{"files": "nope"}' > "$WORK_DIR/files_not_array.json"
run_fixture files_not_array FAIL "context bundle files is not an array"

fixture missing_head_sha '{
  "head_sha": "",
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  x: 1"}],
  "attestations": ATTEST, "permissions": ADMIN}'
run_fixture missing_head_sha FAIL "attestation currency cannot be proven"

fixture no_patch_on_gate_path '{"files": [
  {"filename": ".github/workflows/ci.yml", "status": "modified"}]}'
run_fixture no_patch_on_gate_path FAIL "gate-owned path changed"

fixture no_patch_on_deleted_test '{"files": [
  {"filename": "tests/auth.test.ts", "status": "removed"}]}'
run_fixture no_patch_on_deleted_test FAIL "test file deleted"

# --- auto-revert waiver ----------------------------------------------------
# The .github/workflows/auto-revert.yml workflow opens a revert PR for every
# failing push-to-main run. The undo is, by construction, the inverse of a
# commit that almost certainly added tests — so the gate would flag every
# auto-revert PR as test-integrity weakened unless it recognises the
# workflow's own signals. Three must agree before the waiver applies:
#   1. PR body opens with the workflow's verbatim sentence.
#   2. Every commit subject starts with git's `Revert "` prefix.
#   3. A sha-bound `gate-integrity-auto-revert:` comment exists.
# Missing any one falls through to the trailer check, which fails closed.

# 1+2+3 all present → waiver applies, the deletion is expected for a revert.
AUTO_REVERT_PR_BODY='Automatic revert opened because a push-to-main CI workflow went red.\n\n- Failing run: Deploy production — https://example/run/1\n- Reverts commit `abcdef0`: `Merge pull request #1 from foo/bar`\n- Failing checks: Deploy Worker'
# Wrapped in Python single-quotes so the literal " inside Revert "..." survives
# the bash→Python eval hop without breaking the outer JSON string.
AUTO_REVERT_COMMIT_REVERT="'''Revert \"Merge pull request #1 from foo/bar\"\n\nThis reverts commit abcdef0123456789abcdef0123456789abcdef01.'''"
AUTO_REVERT_ATTS='[{"user": "github-actions[bot]", "sha": HEAD}]'

fixture auto_revert_full_waiver '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});\n-it(\"b\", () => {});"}]}'
run_fixture auto_revert_full_waiver PASS "test-integrity waived"

# A real-world shape: the reverted merge removed an entire test file and
# dropped assertions across several others — net assertion delta is large
# and negative. The waiver must still apply because the workflow itself
# produced this diff.
fixture auto_revert_big_diff_waived '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [
    {"filename": "tests/sanitize-text.server.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
    {"filename": "tests/creative-text.test.ts", "status": "modified",
     "patch": "-  expect(a).toBe(1);\n-  expect(b).toBe(2);\n-  expect(c).toBe(3);\n+  // refactor"}]}'
run_fixture auto_revert_big_diff_waived PASS "test-integrity waived"

# 1+2 but missing the attestation comment — fail closed, name the missing
# signal so the human knows exactly why the waiver did not apply.
fixture auto_revert_no_attest '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture auto_revert_no_attest FAIL "no sha-bound \`gate-integrity-auto-revert:\`"

# 1+3 but the commits are NOT git reverts — a PR that opens with the
# workflow's sentence but whose commits were hand-written gets no
# exemption. The body opener alone is not enough.
fixture auto_revert_body_only '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ["chore: delete dead tests"],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture auto_revert_body_only FAIL "test file deleted"

# 2+3 but the body is paraphrased — also fail closed. The opener is a fixed
# string the workflow owns; matching only the subject prefix is not enough.
fixture auto_revert_paraphrased_body '{
  "pr_body": "This is a manual revert of the bad deploy commit.",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture auto_revert_paraphrased_body FAIL "test file deleted"

# Stale auto-revert attestation: comment names a sha that is no longer the
# PR head. A force-push after the comment must invalidate the waiver,
# exactly like the admin attestation.
fixture auto_revert_stale_attest '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": [{"user": "github-actions[bot]", "sha": OLD}],
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture auto_revert_stale_attest FAIL "stale: a newer commit was pushed after it"

# The gate-path clause is NOT waived on the auto-revert path. A revert of a
# gate-owned path still needs an admin attestation, because the auto-revert
# body only promises "the diff is the inverse of HEAD_SHA" — it does not
# promise HEAD_SHA did not weaken a gate.
fixture auto_revert_touches_gate '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [
    {"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
    {"filename": ".github/workflows/auto-revert.yml", "status": "modified", "patch": "+  timeout-minutes: 5"}]}'
run_fixture auto_revert_touches_gate FAIL "gate-owned path changed"

# With BOTH the auto-revert waiver AND an admin attestation, the gate-path
# half passes (waived by admin) and the test-integrity half passes (waived
# by the auto-revert) — but the two waivers remain independent and each
# marks only its own clause.
fixture auto_revert_and_admin_attest '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "attestations": ATTEST, "permissions": ADMIN,
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [
    {"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"},
    {"filename": ".github/workflows/auto-revert.yml", "status": "modified", "patch": "+  timeout-minutes: 5"}]}'
run_fixture auto_revert_and_admin_attest PASS "test-integrity waived"

# An auto-revert PR that doesn't actually delete tests stays clean: the
# waiver is not needed, but if every signal is in place the gate still
# passes quietly. This pins the no-op path so a future "always waive on
# auto-revert signal" regression is caught.
fixture auto_revert_no_test_changes '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": '"$AUTO_REVERT_ATTS"',
  "files": [{"filename": "app/lib/x.ts", "status": "modified", "patch": "+const y = 1"}]}'
run_fixture auto_revert_no_test_changes PASS "" "::warning"

# Malformed auto-revert attestation entry (wrong shape) must not crash the
# gate and must not produce a spurious waiver. The fixture exercises the
# `entry is not an object` branch.
fixture auto_revert_malformed_attest_entry '{
  "pr_body": "'"$AUTO_REVERT_PR_BODY"'",
  "commit_messages": ['"$AUTO_REVERT_COMMIT_REVERT"'],
  "auto_revert_attestations": ["not-an-object"],
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}]}'
run_fixture auto_revert_malformed_attest_entry FAIL "test file deleted"

# auto_revert_attestations present but not a list → fail closed (matches
# the existing type-validation contract for every other bundle field).
fixture auto_revert_attest_not_array '{
  "auto_revert_attestations": "oops",
  "files": [{"filename": "README.md", "status": "modified", "patch": "+x"}]}'
run_fixture auto_revert_attest_not_array FAIL "auto_revert_attestations is not an array"


# --- configurable inputs (the generalization) -------------------------------
fixture custom_admin_marker_missing '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": [],
  "permissions": ADMIN,
  "admin_attestation_marker": "custom-attest"}'
run_fixture custom_admin_marker_missing FAIL "custom-attest"

fixture custom_admin_marker_pass '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "attestations": [{"user": "nish3451", "sha": HEAD}],
  "permissions": ADMIN,
  "admin_attestation_marker": "custom-attest"}'
run_fixture custom_admin_marker_pass PASS "admin nish3451 attested"

fixture custom_globs_ignore_workflow '{
  "files": [{"filename": ".github/workflows/ci.yml", "status": "modified", "patch": "+  timeout-minutes: 30"}],
  "gate_globs": ["docs/only-this/**"]}'
run_fixture custom_globs_ignore_workflow PASS "" "gate-owned path changed"

fixture custom_globs_catch_docs '{
  "files": [{"filename": "docs/only-this/policy.md", "status": "modified", "patch": "+x"}],
  "gate_globs": ["docs/only-this/**"]}'
run_fixture custom_globs_catch_docs FAIL "gate-owned path changed"

fixture empty_ratchet_paths_no_ceiling_rule '{
  "files": [{"filename": "docs/unrelated.json", "status": "modified",
   "patch": "-  \"raw-hex-color\": 258,\n+  \"raw-hex-color\": 400,"}],
  "ratchet_paths": [],
  "gate_globs": [".github/workflows/**"]}'
run_fixture empty_ratchet_paths_no_ceiling_rule PASS "" "raised"

fixture custom_ratchet_path '{
  "files": [{"filename": "config/legacy-ceilings.json", "status": "modified",
   "patch": "-  \"foo\": 1,\n+  \"foo\": 99,"}],
  "ratchet_paths": ["config/legacy-ceilings.json"],
  "gate_globs": [".github/workflows/**"]}'
run_fixture custom_ratchet_path FAIL "raised 1 -> 99"

fixture custom_test_trailer '{
  "files": [{"filename": "tests/auth.test.ts", "status": "removed", "patch": "-it(\"a\", () => {});"}],
  "commit_messages": ["tests-ok: folded into session suite"],
  "test_removal_trailer": "tests-ok"}'
run_fixture custom_test_trailer PASS "test-integrity waived"

# Workflow shape — skipped when this test is fetched into a temp tree
# containing only the decision script and this file.
reusable="$repo_root/.github/workflows/reusable-gate-integrity.yml"
caller="$repo_root/.github/workflows/gate-integrity.yml"
template_gate="$repo_root/template/.github/workflows/gate-integrity.yml"
ci="$repo_root/.github/workflows/ci.yml"
if [[ -f "$reusable" && -f "$caller" && -f "$template_gate" ]]; then
  grep -q 'workflow_call:' "$reusable" || { echo "FAIL: reusable-gate-integrity.yml must declare workflow_call" >&2; exit 1; }
  grep -q 'timeout-minutes:' "$reusable" || { echo "FAIL: reusable-gate-integrity.yml must set timeout-minutes" >&2; exit 1; }
  grep -q 'cancel-in-progress: true' "$reusable" || { echo "FAIL: reusable-gate-integrity.yml must cancel superseded PR runs" >&2; exit 1; }
  if grep -E '^[[:space:]]+paths:' "$reusable"; then
    echo "FAIL: reusable-gate-integrity.yml must not path-filter the trigger" >&2
    exit 1
  fi
  grep -q 'uses: ./.github/workflows/reusable-gate-integrity.yml' "$caller" \
    || { echo "FAIL: fleet-ops gate-integrity.yml must call the reusable workflow in this repo" >&2; exit 1; }
  grep -q 'uses: Nishfleet/fleet-ops/.github/workflows/reusable-gate-integrity.yml@main' "$template_gate" \
    || { echo "FAIL: template must call Nishfleet/fleet-ops reusable-gate-integrity.yml@main" >&2; exit 1; }
  if grep -q 'secrets: inherit' "$caller" "$template_gate"; then
    echo "FAIL: gate-integrity callers must not use secrets: inherit" >&2
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok   workflow_shape\n'
else
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok   workflow_shape (skipped; decision-only tree)\n'
fi

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
test "$FAIL_COUNT" -eq 0
