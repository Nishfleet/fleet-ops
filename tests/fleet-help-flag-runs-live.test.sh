#!/usr/bin/env bash
# tests/fleet-help-flag-runs-live.test.sh
#
# fleet-ops#1549: --help/-h on fleet-blind-audit and fleet-researcher-dispatch
# must print usage and exit 0. They must NOT take the flock, call pi, start a
# unit, or write a report/state directory. This is the class guard for the
# help-flag-runs-live dedupe: a future refactor that drops the argv branch (or
# moves it below the first side effect) fails this test.
#
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

blind="$repo_root/bin/fleet-blind-audit"
researcher="$repo_root/bin/fleet-researcher-dispatch"

[[ -x "$blind" ]] || fail "not executable: $blind"
[[ -x "$researcher" ]] || fail "not executable: $researcher"
bash -n "$blind" || fail "blind-audit: bash -n"
bash -n "$researcher" || fail "researcher-dispatch: bash -n"

# Source guard: the help branch must exist and must sit before the first
# side effect (mkdir -p / python3 init). A grep for the case arm is the
# cheap class lock; the live run below is the real proof.
grep -Fq 'case "${1:-}" in' "$blind" \
  || fail "fleet-blind-audit must dispatch argv[1] before side effects (fleet-ops#1549)"
grep -Fq 'case "${1:-}" in' "$researcher" \
  || fail "fleet-researcher-dispatch must dispatch argv[1] before side effects (fleet-ops#1549)"

# --- fleet-blind-audit -------------------------------------------------
# Point AUDIT_STATE_DIR at a scratch dir so any stray mkdir -p is visible.
scratch_blind=$(mktemp -d)
trap 'rm -rf "$scratch_blind" "$scratch_researcher"' EXIT

for flag in --help -h; do
    out=$(AUDIT_STATE_DIR="$scratch_blind" "$blind" "$flag" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    [[ "$rc" -eq 0 ]] || fail "fleet-blind-audit $flag exited $rc (must exit 0)"
    [[ -n "$out" ]] || fail "fleet-blind-audit $flag printed nothing"
    # Usage must name the binary, not a live-run verdict.
    echo "$out" | grep -Eq "fleet-blind-audit|Usage" \
      || fail "fleet-blind-audit $flag did not print usage (got: $(printf '%s' "$out" | head -1))"
    # No report directory must appear under the scratch state dir.
    found=$(find "$scratch_blind" -mindepth 1 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] \
      || fail "fleet-blind-audit $flag created state under \$AUDIT_STATE_DIR ($found) — help must not run"
    rc=
done
ok "fleet-blind-audit --help/-h print usage, exit 0, write no report dir"

# --- fleet-researcher-dispatch -----------------------------------------
scratch_researcher=$(mktemp -d)

for flag in --help -h; do
    out=$(RESEARCHER_STATE_DIR="$scratch_researcher" "$researcher" "$flag" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    [[ "$rc" -eq 0 ]] || fail "fleet-researcher-dispatch $flag exited $rc (must exit 0)"
    [[ -n "$out" ]] || fail "fleet-researcher-dispatch $flag printed nothing"
    echo "$out" | grep -Eq "fleet-researcher-dispatch|Usage" \
      || fail "fleet-researcher-dispatch $flag did not print usage (got: $(printf '%s' "$out" | head -1))"
    found=$(find "$scratch_researcher" -mindepth 1 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] \
      || fail "fleet-researcher-dispatch $flag created state under \$RESEARCHER_STATE_DIR ($found) — help must not run"
    rc=
done
ok "fleet-researcher-dispatch --help/-h print usage, exit 0, write no state dir"

echo "OK: fleet-ops#1549 help-flag-runs-live guard green"
