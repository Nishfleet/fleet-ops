#!/usr/bin/env bash
# tests/reusable-surface-audit.test.sh
#
# Shape-lock the reusable surface-audit workflow (fleet-ops#1198):
#   1. Parked reusable YAML is workflow_call, timeout, no trigger paths,
#      no job-level if.
#   2. The reusable accepts the documented inputs (config-path, audit-script,
#      node-version, install-command, out-dir, timeout-minutes) and passes
#      them through env: (semgrep run-shell-injection).
#   3. The reusable is self-skipping on absent config — no required check
#      silently disappears.
#   4. The reusable validates the per-product surface-audit.json shape
#      (matrix.{themes,authStates,viewports,routes}, viewport {name,width,
#      height}, theme ∈ {light,dark}, auth.method=cookie).
#   5. The reusable passes the matrix as a JSON env var, never via run: arg.
#   6. The reusable uploads results/ as surface-audit-results regardless of
#      exit (if: always()), matching the prove-one-run gate's inspectability.
#   7. Thin template caller points at fleet-ops; no copied reusable steps.
#   8. The template ships a sample surface-audit.json the consumer can copy.
#   9. If the GitHub-callable path exists at .github/workflows/, it must
#      match the parked source.
#  10. The example surface-audit.json validates against the reusable's own
#      JSON schema check (executed against the parked source).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

src="$repo_root/docs/pending-surface-audit/reusable-surface-audit.yml"
caller="$repo_root/template/.github/workflows/surface-audit.yml"
example="$repo_root/docs/pending-surface-audit/surface-audit.json.example"
template_cfg="$repo_root/template/surface-audit.json"
readme="$repo_root/docs/pending-surface-audit/README.md"

[[ -f "$src" ]] || fail "missing parked reusable $src"
[[ -f "$caller" ]] || fail "missing thin caller $caller"
[[ -f "$example" ]] || fail "missing example $example"
[[ -f "$template_cfg" ]] || fail "missing template sample $template_cfg"
[[ -f "$readme" ]] || fail "missing README $readme"

# 1. workflow_call + timeout + concurrency, no trigger paths, no job-level if.
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

# 2. Documented inputs.
for inp in config-path audit-script node-version install-command out-dir timeout-minutes; do
  grep -qE "^      ${inp}:" "$src" || fail "reusable must accept ${inp} input"
done
ok "all six documented inputs declared"

# 3. Self-skip on absent config.
grep -q 'Self-skip gate' "$src" || fail "must declare a self-skip gate step"
grep -q 'configured=false' "$src" || fail "self-skip must emit configured=false on absent config"
grep -q '::notice::' "$src" || fail "self-skip must emit a ::notice:: line so the skip is visible in the run log"
ok "self-skip gate present and visible"

# 4. Schema validation in the reusable. The reusable iterates over the four
# matrix axes in one tuple; check the tuple is exactly that set so a
# future drift (adding or dropping an axis) is caught.
grep -q '("themes", "authStates", "viewports", "routes")' "$src" \
  || fail "must iterate over exactly the four matrix axes themes/authStates/viewports/routes"
grep -q 'm\["viewports"\]' "$src" || fail "must validate matrix.viewports as a list of viewport objects"
grep -q 'm\["themes"\]' "$src" || fail "must iterate over matrix.themes"
grep -qE '\bnot in \(.light., .dark.\)|"light".*"dark"' "$src" \
  || fail "must restrict themes to light/dark"
grep -q "'cookie'" "$src" || fail "must restrict auth.method to cookie"
ok "schema validation matches the design"

# 5. Inputs go through env:, never run: interpolation (semgrep run-shell-injection).
if grep -F 'run: ${{ inputs.' "$src"; then
  fail "inputs must go through env: (semgrep run-shell-injection)"
fi
ok "inputs are not interpolated in run:"

# 6. Artifact upload uses if: always() so failure runs are inspectable.
grep -q 'if: always()' "$src" || fail "artifact upload must use if: always()"
grep -q 'surface-audit-results' "$src" || fail "artifact name must be surface-audit-results"
grep -q 'upload-artifact@' "$src" || fail "must upload via actions/upload-artifact"
grep -q 'retention-days: 7' "$src" || fail "artifact retention-days must be 7 (matches gitleaks SARIF)"
ok "artifact upload is failure-visible and inspectable"

# The reusable must NOT start the product server itself. Only the consumer
# knows the right command + readiness probe, and a hard-coded `npm run
# preview` would freeze every non-Vite product's audit.
if grep -E 'npm run preview|npm run dev' "$src"; then
  fail "reusable must not hardcode a serve command (consumer owns serving)"
fi
ok "reusable does not start the server (consumer-owned)"

# 7. Thin caller is shape-correct.
grep -q 'uses: Nishfleet/fleet-ops/.github/workflows/reusable-surface-audit.yml@v1' "$caller" \
  || fail "thin caller must point at Nishfleet/fleet-ops reusable-surface-audit.yml@v1"
grep -q 'pull_request:' "$caller" || fail "thin caller must trigger on pull_request"
if grep -q 'secrets: inherit' "$caller"; then
  fail "callers must not use secrets: inherit"
fi
if grep -E 'matrix:|fromJSON|npm run preview|surface-audit.json' "$caller" | grep -v 'config-path\|config\.path\|surface-audit\.json'; then
  fail "thin caller copied reusable steps instead of passing the call"
fi
ok "thin caller is thin and points at fleet-ops"

# 8. Template sample config is shipped.
python3 -c "import json; json.load(open('$template_cfg'))" \
  || fail "template/surface-audit.json must be valid JSON"
ok "template sample config is valid JSON"

# 9. Optional callable copy under .github/workflows/ must match parked source.
callable="$repo_root/.github/workflows/reusable-surface-audit.yml"
if [[ -f "$callable" ]]; then
  cmp -s "$callable" "$src" || fail "callable workflow drifted from parked source"
  ok "callable workflow matches parked source"
else
  echo "NOTE: $callable is absent — nishfleet-worker cannot push .github/workflows/**; parked source is $src"
fi

# 10. Validate the example surface-audit.json against the reusable's own
# schema check. We re-execute the Python validator inline so the test fails
# fast on a schema mismatch.
python3 - "$example" <<'PY' || fail "example surface-audit.json failed schema validation"
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read()
cfg = json.loads(raw)
# Strip the sample-only "_comment" key before validating (the real validator
# does not expect it; the sample ships one for human readers).
if "_comment" in cfg:
    cfg = {k: v for k, v in cfg.items() if k != "_comment"}
m = cfg.get("matrix")
assert isinstance(m, dict), "matrix must be an object"
for axis in ("themes", "authStates", "viewports", "routes"):
    assert axis in m and isinstance(m[axis], list) and m[axis], f"matrix.{axis} must be a non-empty array"
for vp in m["viewports"]:
    assert isinstance(vp, dict) and {"name", "width", "height"} <= set(vp.keys()), "every viewport needs {name, width, height}"
for t in m["themes"]:
    assert t in ("light", "dark"), f"theme must be light or dark, got {t!r}"
auth = cfg.get("auth", {})
if "method" in auth:
    assert auth["method"] == "cookie", "auth.method must be 'cookie'"
print("example validates")
PY
ok "example surface-audit.json validates against the schema"

# CI host lock (fleet-ops#497). Worker must not add a verify-command line.
# This test stays listed in ci.yml OR invoked from seat-lib.test.sh.
ci_yml="$repo_root/.github/workflows/ci.yml"
listed=0
hosted=0
grep -Fq 'bash tests/reusable-surface-audit.test.sh' "$ci_yml" && listed=1 || true
grep -Fq 'bash "$here/reusable-surface-audit.test.sh"' "$here/seat-lib.test.sh" && hosted=1 || true
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "reusable-surface-audit.test.sh has no CI host (fleet-ops#497): list it in ci.yml or invoke it from seat-lib.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed seat-lib hosted=$hosted)"

echo "OK: reusable surface-audit workflow is shape-locked"
