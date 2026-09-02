#!/usr/bin/env bash
# tests/fleet-help-flag-runs-live.test.sh
#
# fleet-ops#1549: --help/-h on fleet-blind-audit and fleet-researcher-dispatch
# must print usage and exit 0. They must NOT take the flock, call pi, start a
# unit, or write a report/state directory. This is the class guard for the
# help-flag-runs-live dedupe: a future refactor that drops the argv branch (or
# moves it below the first side effect) fails this test.
#
# fleet-ops#2889: same guard for lifecycle-label-sweep and
# fleet-stale-auto-revert-sweep.
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
lifecycle="$repo_root/bin/lifecycle-label-sweep"
stale="$repo_root/bin/fleet-stale-auto-revert-sweep"

[[ -x "$blind" ]] || fail "not executable: $blind"
[[ -x "$researcher" ]] || fail "not executable: $researcher"
[[ -x "$lifecycle" ]] || fail "not executable: $lifecycle"
[[ -x "$stale" ]] || fail "not executable: $stale"
bash -n "$blind" || fail "blind-audit: bash -n"
bash -n "$researcher" || fail "researcher-dispatch: bash -n"
bash -n "$lifecycle" || fail "lifecycle-label-sweep: bash -n"
bash -n "$stale" || fail "fleet-stale-auto-revert-sweep: bash -n"

# Source guard: the help branch must exist and must sit before the first
# side effect (mkdir -p / python3 init). A grep for the case arm is the
# cheap class lock; the live run below is the real proof.
for script in "$blind" "$researcher" "$lifecycle" "$stale"; do
    grep -Fq 'case "${1:-}" in' "$script" \
      || fail "$(basename "$script") must dispatch argv[1] before side effects"
done

# --- fleet-blind-audit -------------------------------------------------
# Point AUDIT_STATE_DIR at a scratch dir so any stray mkdir -p is visible.
scratch_blind=$(mktemp -d)
trap 'rm -rf "${scratch_blind:-}" "${scratch_researcher:-}" "${scratch_lifecycle:-}" "${scratch_stale:-}"' EXIT

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

# --- lifecycle-label-sweep ---------------------------------------------
scratch_lifecycle=$(mktemp -d)

for flag in --help -h; do
    out=$(LIFECYCLE_SWEEP_LOCKDIR="$scratch_lifecycle" \
          LIFECYCLE_SWEEP_REPOS='Nishfleet/__does_not_exist__' \
          "$lifecycle" "$flag" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    [[ "$rc" -eq 0 ]] || fail "lifecycle-label-sweep $flag exited $rc (must exit 0)"
    [[ -n "$out" ]] || fail "lifecycle-label-sweep $flag printed nothing"
    echo "$out" | grep -Eq "lifecycle-label-sweep|Usage" \
      || fail "lifecycle-label-sweep $flag did not print usage (got: $(printf '%s' "$out" | head -1))"
    found=$(find "$scratch_lifecycle" -mindepth 1 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] \
      || fail "lifecycle-label-sweep $flag created state under \$LIFECYCLE_SWEEP_LOCKDIR ($found) — help must not run"
    rc=
done
ok "lifecycle-label-sweep --help/-h print usage, exit 0, write no lock dir"

# --- fleet-stale-auto-revert-sweep -------------------------------------
scratch_stale=$(mktemp -d)

for flag in --help -h; do
    out=$(FLEET_STALE_REVERT_LOCKDIR="$scratch_stale" \
          FLEET_STALE_REVERT_REPOS='Nishfleet/__does_not_exist__' \
          "$stale" "$flag" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    [[ "$rc" -eq 0 ]] || fail "fleet-stale-auto-revert-sweep $flag exited $rc (must exit 0)"
    [[ -n "$out" ]] || fail "fleet-stale-auto-revert-sweep $flag printed nothing"
    echo "$out" | grep -Eq "fleet-stale-auto-revert-sweep|Usage" \
      || fail "fleet-stale-auto-revert-sweep $flag did not print usage (got: $(printf '%s' "$out" | head -1))"
    found=$(find "$scratch_stale" -mindepth 1 2>/dev/null | head -1 || true)
    [[ -z "$found" ]] \
      || fail "fleet-stale-auto-revert-sweep $flag created state under \$FLEET_STALE_REVERT_LOCKDIR ($found) — help must not run"
    rc=
done
ok "fleet-stale-auto-revert-sweep --help/-h print usage, exit 0, write no lock dir"

echo "OK: help-flag-runs-live guard green"
