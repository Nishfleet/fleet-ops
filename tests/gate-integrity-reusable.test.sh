#!/usr/bin/env bash
# tests/gate-integrity-reusable.test.sh
#
# Shape-lock the reusable gate-integrity workflow (fleet-ops#303):
#   1. Parked reusable YAML is workflow_call, timeout, no trigger paths, no job if.
#   2. Candidate checkout is forbidden (base-owned detector).
#   3. Repo-specific globs are inputs (and/or `.fleet/gate-integrity.yml`).
#   4. Thin template caller points at fleet-ops; no copied decision steps.
#   5. If the GitHub-callable path exists, it matches the parked source.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

src="$repo_root/docs/pending-gate-integrity/reusable-gate-integrity.yml"
callable="$repo_root/.github/workflows/reusable-gate-integrity.yml"
caller="$repo_root/template/.github/workflows/gate-integrity.yml"
template_cfg="$repo_root/template/.fleet/gate-integrity.yml"
decision="$repo_root/.github/scripts/gate-integrity.sh"
loader="$repo_root/lib/gate-integrity-config.sh"

[[ -f "$src" ]] || fail "missing parked reusable $src"
[[ -f "$caller" ]] || fail "missing thin caller $caller"
[[ -f "$template_cfg" ]] || fail "missing template config $template_cfg"
[[ -f "$decision" ]] || fail "missing $decision"
[[ -f "$loader" ]] || fail "missing $loader"

grep -q 'workflow_call:' "$src" || fail "reusable must declare workflow_call"
grep -q 'timeout-minutes:' "$src" || fail "job must set timeout-minutes"
grep -q 'cancel-in-progress: true' "$src" || fail "must cancel superseded PR runs"
ok "workflow_call + timeout + concurrency"

if grep -E '^[[:space:]]+paths:' "$src"; then
  fail "must not path-filter the trigger (a skipped required check freezes PRs)"
fi
ok "no trigger-level paths: filter"

if grep -E '^    if:' "$src"; then
  fail "must not skip the required job with a job-level if:"
fi
ok "no job-level if:"

if grep -E 'actions/checkout@' "$src"; then
  fail "must not check out candidate code (base-owned detector)"
fi
ok "no checkout of candidate code"

grep -q 'gate-globs' "$src" || fail "must accept gate-globs input"
if grep -q 'Nishfleet/0509' "$src"; then
  fail "reusable must not hardcode Nishfleet/0509"
fi
if grep -q 'scripts/design-system-ratchet.mjs' "$src"; then
  fail "0509 ratchet path must live in config/inputs, not the reusable workflow"
fi
ok "repo-specific rules are inputs/config, not hardcoded"

grep -q 'gate-integrity.sh' "$src" || fail "must fetch the decision script from fleet-ops"
ok "decision script is fetched from fleet-ops"

if grep -F 'run: ${{ inputs.' "$src"; then
  fail "inputs must go through env: (semgrep run-shell-injection)"
fi
ok "inputs are not interpolated in run:"

grep -q 'uses: Nishfleet/fleet-ops/.github/workflows/reusable-gate-integrity.yml@v1' "$caller" \
  || fail "template caller must point at Nishfleet/fleet-ops reusable-gate-integrity.yml@v1"
grep -q 'pull_request_target:' "$caller" || fail "thin caller must trigger on pull_request_target"
grep -q 'merge_group:' "$caller" || fail "thin caller must report on merge_group"
if grep -q 'secrets: inherit' "$caller"; then
  fail "callers must not use secrets: inherit"
fi
if grep -E 'gate-integrity.sh|gh api' "$caller"; then
  fail "template caller copied reusable steps instead of passing the call"
fi
ok "template caller is thin and points at fleet-ops"

python3 - "$template_cfg" "$repo_root/tests/fixtures/gate-integrity/default.yml" "$loader" <<'PY'
import json, subprocess, sys
loader = sys.argv[3]
got = []
for path in sys.argv[1:3]:
    got.append(json.loads(subprocess.check_output(["bash", loader, path], text=True)))
if got[0]["gate_globs"] != got[1]["gate_globs"] or got[0]["ratchet_paths"] != got[1]["ratchet_paths"]:
    raise SystemExit("template .fleet config must match tests/fixtures/gate-integrity/default.yml")
PY
ok "template config matches the default fixture"

if [[ -f "$callable" ]]; then
  cmp -s "$callable" "$src" || fail "callable workflow drifted from parked source"
  ok "callable workflow matches parked source"
else
  echo "NOTE: $callable is absent — nishfleet-worker cannot push .github/workflows/**; parked source is $src"
fi

echo "OK: reusable gate-integrity workflow is shape-locked"
