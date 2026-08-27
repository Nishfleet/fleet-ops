#!/usr/bin/env bash
# tests/gate-integrity-reusable-828.test.sh
#
# Lock the contract between the parked reusable-gate-integrity workflow and
# the decision script (fleet-ops#828 / 0509#1273).
#
# The reusable's Python step does the permission-API prefetch and ships the
# raw `comments` array. The decision script's `extract_attestations_from_comments`
# then runs the line-anchored scan that accepts multi-line attest comments.
# This test reproduces that contract in plain bash so a future regression —
# a re-introduction of the whole-body filter in either the workflow or the
# decision script — is caught.
#
# The contract is: a multi-line attest comment is honoured iff a
# `{marker}: {40-hex}` line appears anywhere in its body, NOT only when the
# whole body equals that string.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DECISION="$REPO_ROOT/.github/scripts/gate-integrity.sh"
REUSABLE="$REPO_ROOT/docs/pending-gate-integrity/reusable-gate-integrity.yml"
[[ -f "$DECISION" ]] || { echo "FAIL: missing $DECISION" >&2; exit 1; }
[[ -f "$REUSABLE" ]] || { echo "FAIL: missing $REUSABLE" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gi-828.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
HEAD="1111111111111111111111111111111111111111"
OLD="2222222222222222222222222222222222222222"

# build_bundle_jq builds a context bundle in the shape the parked reusable
# workflow now produces: raw `comments` array (not pre-extracted
# attestations) plus a `permissions` dict. The decision script's
# `extract_attestations_from_comments` does the line-anchored scan.
#
# Args: <name> <body> [user] [perm] [gate_path] [gate_patch]
build_bundle_jq() {
  local name="$1"
  local body="$2"
  local user="${3:-nish3451}"
  local perm="${4:-admin}"
  local gate_path="${5:-.github/workflows/ci.yml}"
  local gate_patch="${6:-+  timeout-minutes: 30}"
  jq -n \
    --arg head "$HEAD" \
    --arg user "$user" \
    --arg body "$body" \
    --arg gate_path "$gate_path" \
    --arg gate_patch "$gate_patch" \
    --arg perm "$perm" \
    '{
      head_sha: $head,
      files: [{filename: $gate_path, status: "modified", patch: $gate_patch}],
      comments: [{body: $body, user: $user}],
      permissions: {($user): $perm},
      gate_globs: [".github/workflows/**", ".github/scripts/**"],
      ratchet_paths: [],
      admin_attestation_marker: "gate-integrity-attest",
      auto_revert_attestation_marker: "gate-integrity-auto-revert",
      auto_revert_body_opener: "Automatic revert opened because a push-to-main CI workflow went red.",
      git_revert_subject_prefix: "Revert \"",
      test_removal_trailer: "test-removal-justified"
    }' > "$WORK_DIR/$name.json"
}

run() {
  local name="$1" expected="$2" needle="${3:-}"
  local rc=0 out=""
  out="$(bash "$DECISION" < "$WORK_DIR/$name.json" 2>&1)" || rc=$?
  if [[ "$expected" == "PASS" && $rc -eq 0 && "$out" == *"PASS:"* ]]; then
    if [[ -n "$needle" && "$out" != *"$needle"* ]]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL %s: missing expected output: %s\n       | %s\n' "$name" "$needle" "$(echo "$out" | tr '\n' '|' | head -c 400)"
    else
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'ok   %s\n' "$name"
    fi
  elif [[ "$expected" == "FAIL" && $rc -ne 0 && "$out" == *"FAIL:"* ]]; then
    if [[ -n "$needle" && "$out" != *"$needle"* ]]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL %s: missing expected output: %s\n       | %s\n' "$name" "$needle" "$(echo "$out" | tr '\n' '|' | head -c 400)"
    else
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'ok   %s\n' "$name"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s: expected %s, got rc=%s\n       | %s\n' "$name" "$expected" "$rc" "$(echo "$out" | tr '\n' '|' | head -c 400)"
  fi
}

# --- the #1273 repro: multi-line attest comment, line-anchored extraction ---
# This is the EXACT shape Nish posted on 0509#1273 (reproduced here in a
# fixture). A passing run here proves the contract that the parked reusable
# now ships raw `comments` and the decision script does the line-anchored
# extraction — and that the previous whole-body filter is dead.
MULTILINE_BODY="gate-integrity-attest: ${HEAD}
verifier-attest: ${HEAD}

Orchestrator attestation after diff review: SHA-pinned codecov action."

build_bundle_jq "p1273_multiline" "$MULTILINE_BODY" "nish3451" "admin"
run "p1273_multiline" PASS "every gate-integrity violation carries its required justification"

# Attest line in the middle of a longer review comment.
EMBEDDED_BODY="Looking at the diff now. The codecov action is pinned at v7, which is current.

gate-integrity-attest: ${HEAD}

The tokenless upload only works for unprotected PR head branches; main needs a token later. Promotion to required stays gated on 3 consecutive reliable reports per the PR body."

build_bundle_jq "embedded_line" "$EMBEDDED_BODY" "nish3451" "admin"
run "embedded_line" PASS "every gate-integrity violation carries its required justification"

# Attest line at the END of a comment, preceded by review prose.
TRAILING_BODY="Orchestrator review notes: tokenless uploads verified against the Codecov tokens docs, the failure-mode semantics are non-fatal during evaluate, and the diff is sha-pinned.

gate-integrity-attest: ${HEAD}"

build_bundle_jq "trailing_line" "$TRAILING_BODY" "nish3451" "admin"
run "trailing_line" PASS "every gate-integrity violation carries its required justification"

# Prose that merely MENTIONS the marker is not an attestation. The
# line-anchored rule rejects this even though a naive substring search
# would accept it.
PROSE_BODY="I would post gate-integrity-attest: ${HEAD} here but this sentence is prose, not the marker line itself."

build_bundle_jq "prose_mention" "$PROSE_BODY" "nish3451" "admin"
run "prose_mention" FAIL 'no current `gate-integrity-attest:'

# A multi-line attest whose sha is stale (does not match head) is rejected.
STALE_BODY="gate-integrity-attest: ${OLD}

prose"

build_bundle_jq "stale_sha" "$STALE_BODY" "nish3451" "admin"
run "stale_sha" FAIL "stale: a newer commit was pushed after it"

# A multi-line attest by a non-admin is rejected.
build_bundle_jq "nonadmin" "$MULTILINE_BODY" "worker" "write" ".github/workflows/ci.yml" "+  timeout-minutes: 30"
run "nonadmin" FAIL "not admin"

# CR characters in a multi-line attest body must not break extraction.
CRLF_BODY=$'gate-integrity-attest: '"${HEAD}"$'\r\nverifier-attest: '"${HEAD}"$'\r\n\r\nprose'
build_bundle_jq "crlf_body" "$CRLF_BODY" "nish3451" "admin"
run "crlf_body" PASS "every gate-integrity violation carries its required justification"

# --- the parked reusable ships raw `comments`, not pre-extracted arrays ---
# If a future change re-introduces the whole-body filter at the workflow
# level (instead of using the decision script's extractor), these grep
# checks fail and force the fix back onto the line-anchored path.
if grep -qE 'test\("\^.*-attest: \[[0-9a-fA-F\]\{40\}\]\$"\)' "$REUSABLE"; then
  echo "FAIL: parked reusable still has the whole-body att-est test filter (line-anchored is the contract)"
  grep -nE 'test\("\^.*-attest: \[[0-9a-fA-F\]\{40\}\]\$"\)' "$REUSABLE" | head -5
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok   no_whole_body_filter\n'

# The reusable must include `comments` in the bundle (so the decision script
# does the line-anchored extraction). It must NOT pre-extract into
# `attestations` / `auto_revert_attestations` arrays in the bundle, because
# that is the bug that bit 0509#1273.
if ! grep -q '"comments": comments' "$REUSABLE"; then
  echo "FAIL: parked reusable does not ship raw comments in the bundle"
  exit 1
fi
if grep -qE '"attestations":\s*attestations' "$REUSABLE"; then
  echo "FAIL: parked reusable still pre-extracts attestations array"
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok   reusable_ships_raw_comments\n'

# fleet-ops#497: CI host lock. Workers cannot add a verify-command line.
# This file must stay listed in ci.yml OR invoked from seat-lib.test.sh.
ci_yml="$REPO_ROOT/.github/workflows/ci.yml"
listed=0
hosted=0
grep -Fq 'bash tests/gate-integrity-reusable-828.test.sh' "$ci_yml" && listed=1 || true
grep -Fq 'bash "$here/gate-integrity-reusable-828.test.sh"' "$SCRIPT_DIR/seat-lib.test.sh" && hosted=1 || true
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  echo "FAIL: gate-integrity-reusable-828.test.sh has no CI host (fleet-ops#497): list it in ci.yml or invoke it from seat-lib.test.sh" >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))
printf 'ok   ci_host (ci.yml listed=%s, seat-lib hosted=%s)\n' "$listed" "$hosted"

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
test "$FAIL_COUNT" -eq 0
