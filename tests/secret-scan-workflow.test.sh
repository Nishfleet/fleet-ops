#!/usr/bin/env bash
# tests/secret-scan-workflow.test.sh — fleet-ops#6635
#
# Pins .github/workflows/secret-scan.yml, the gitleaks gate copied from
# Nishfleet/0509 (required context "Gitleaks" there; #6476 stage-2 folds the
# same promotion in here). The scan closes the gap that 14 of 20 fleet-ops
# workflows consume Actions secrets — including NISHFLEET_WORKER_PRIVATE_KEY —
# with no secret-scan gate running on this repo's PRs or pushes.
#
# Drills:
#   1. The workflow exists and fires on pull_request + merge_group +
#      push-to-main (and workflow_dispatch for authorized manual runs).
#   2. The gitleaks binary is pinned by version AND sha256, checksum-verified,
#      and the installed binary's own version output is asserted — and the
#      gitleaks-action wrapper (org-license-gated, fails on Nishfleet repos)
#      is never used.
#   3. Range scoping: pull_request/merge_group scan base..head only;
#      push/dispatch scan --full-history of HEAD — never a bare `gitleaks git`
#      (git log --all walks every claim branch; 0509#1817 reverted an
#      innocent PR over a fixture on an unrelated branch). --redact and
#      --exit-code 2 separate leaks (2) from scanner error (1).
#   4. Required-context shape: the Gitleaks job has no job-level `if:` or
#      `needs:` (a skipped required context satisfies branch protection),
#      the authorizer step asserts this repo, and the fork guard keeps
#      untrusted fork code out of the scan step.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
wf="$repo_root/.github/workflows/secret-scan.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$wf" ]] || fail "missing $wf"
ok "secret-scan.yml exists"

# --- Drill 1: triggers ------------------------------------------------------
for needle in \
  'name: Secret Scan' \
  'pull_request:' \
  'merge_group:' \
  'push:' \
      '- main' \
  'workflow_dispatch:'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing trigger/name line: $needle"
done
ok "triggers on pull_request + merge_group + push:main + workflow_dispatch"

# --- Drill 2: pinned binary, never the action -------------------------------
for needle in \
  'GITLEAKS_VERSION: 8.30.1' \
  'GITLEAKS_SHA256: 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' \
  'sha256sum --check --strict' \
  'test "$("$install_dir/gitleaks" version)" = "$GITLEAKS_VERSION"'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing pin line: $needle"
done
grep -qF 'gitleaks/gitleaks-action' "$wf" \
  && fail "workflow uses the org-license-gated gitleaks-action wrapper"
ok "gitleaks binary pinned by version+sha256, checksum-verified, no action wrapper"

# --- Drill 3: range scoping + redaction -------------------------------------
for needle in \
  'pull_request|merge_group)' \
  '"${PR_BASE_SHA}..${PR_HEAD_SHA}"' \
  '--full-history HEAD' \
  '--redact' \
  '--exit-code 2'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing scan-scope line: $needle"
done
ok "PR scans base..head; push scans --full-history HEAD; --redact + exit-code 2"

# --- Drill 4: required-context shape ----------------------------------------
awk '/^  gitleaks:/{f=1} f' "$wf" | grep -qE '^    (if|needs):' \
  && fail "Gitleaks job has a job-level if:/needs: — a skipped required context still satisfies branch protection"
for needle in \
  'name: Gitleaks' \
  'test "$GITHUB_REPOSITORY" = "Nishfleet/fleet-ops"' \
  'github.event.pull_request.head.repo.full_name == github.repository'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing gate-shape line: $needle"
done
ok "no job-level if/needs; authorizer asserts Nishfleet/fleet-ops; fork guard on scan step"

echo "PASS: secret-scan-workflow"
