#!/usr/bin/env bash
# tests/gate-arm-guard.test.sh
#
# fleet-ops#5238: the auto-merge arm must refuse gate-path PRs whose
# `gate-integrity` check is not green — PR #5207 merged with FAILURE
# because the advisory check is not a required context and
# `--auto --squash` only waits on required checks.
#
# Drill matrix (every fixture asserts BOTH verdict and exit code):
#   gate-path + FAILURE            -> refuse (the #5207 escape)
#   gate-path + SUCCESS            -> arm    (re-arm once green)
#   non-gate-path (+ FAILURE row)  -> arm    (unaffected)
#   gate-path + no check + no gate -> arm    (repo has no gate; fail-open)
#   gate-path + no check + gate    -> refuse (gate repo, verdict never landed)
#   gate-path + PENDING            -> refuse (not SUCCESS; live mode waits first)
#   rename out of a gate dir       -> refuse (previous_filename matches)
#   bare `gate-integrity` job name -> both verdicts resolve
#   check-runs-API row shape       -> normalized identically
#
# Wiring assertions pin the reusable arm workflow to the guard: the
# fetched-at-workflow_sha step must exist and the arm step must read
# `steps.gateint.outputs.gated`.
#
# Prior behaviour: on origin/main there is no bin/fleet-gate-arm-guard
# and no gateint step — the existence and wiring assertions below fail
# there and pass here, which is the before/after the issue asks for.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
guard="$repo_root/bin/fleet-gate-arm-guard"
lib="$repo_root/lib/gate-arm-guard.py"
fixtures="$here/fixtures/gate-arm-guard"
arm_wf="$repo_root/.github/workflows/reusable-auto-merge-arm.yml"
ci_yml="$repo_root/.github/workflows/ci.yml"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$guard" ]] || fail "not executable: $guard"
[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "gate-arm-guard.py failed py_compile"

# --- fixture loop: verdict + exit code ------------------------------------
seen=0
for fx in "$fixtures"/*.json; do
  name="$(basename "$fx" .json)"
  expect="$(jq -r '.expect' "$fx")"
  [[ "$expect" == arm || "$expect" == refuse ]] \
    || fail "$name: fixture expect must be arm|refuse, got $expect"
  set +e
  out=$("$guard" evaluate --input "$fx" 2>&1)
  rc=$?
  set -e
  want_rc=0; [[ "$expect" == refuse ]] && want_rc=1
  [[ "$rc" -eq "$want_rc" ]] \
    || fail "$name: exit $rc, want $want_rc: $out"
  jq -e --arg v "$expect" '.verdict == $v' <<<"$out" >/dev/null \
    || fail "$name: verdict must be $expect: $out"
  jq -e '.matched_paths and (.reason | length > 0)' <<<"$out" >/dev/null \
    || fail "$name: verdict must carry matched_paths and a reason: $out"
  seen=$((seen + 1))
  ok "fixture $name: $expect (rc=$rc, $(jq -r .reason <<<"$out"))"
done
[[ "$seen" -ge 9 ]] || fail "fixture set shrank ($seen < 9) — drill coverage dropped"

# --- targeted asserts the issue names -------------------------------------
set +e
out=$("$guard" evaluate --input "$fixtures/gate-path-failure.json")
set -e
jq -e '.matched_paths | index(".github/workflows/ci.yml")' <<<"$out" >/dev/null \
  || fail "gate-path-failure must name the matched gate path: $out"

set +e
out=$("$guard" evaluate --input "$fixtures/rename-out-of-gate.json")
set -e
jq -e '.matched_paths | index(".github/workflows/ci-notes.md")' <<<"$out" >/dev/null \
  || fail "rename-out-of-gate must match previous_filename: $out"

# A missing check on a gate-running repo refuses; without the gate it arms.
set +e
"$guard" evaluate --input "$fixtures/absent-gate-repo.json" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "absent-gate-repo must refuse (exit 1), got $rc"
set +e
"$guard" evaluate --input "$fixtures/absent-no-gate-repo.json" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "absent-no-gate-repo must arm (exit 0), got $rc"

# --- wiring: the reusable arm workflow runs the guard and honours it ------
grep -Fq 'bin/fleet-gate-arm-guard' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must fetch bin/fleet-gate-arm-guard"
grep -Fq 'lib/gate-arm-guard.py' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must fetch lib/gate-arm-guard.py"
grep -Fq 'id: gateint' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must carry a gateint step"
grep -Fq 'steps.gateint.outputs.gated' "$arm_wf" \
  || fail "arm step must read steps.gateint.outputs.gated"
grep -Fq 'github.workflow_sha' "$arm_wf" \
  || fail "guard must be fetched at github.workflow_sha (no drift)"
grep -Fq 'wait-seconds' "$arm_wf" \
  || fail "guard call must carry a pending-check wait budget"
grep -Fq -- '--disable-auto' "$arm_wf" \
  || fail "refuse path must disarm already-armed auto-merge (the #5207 escape)"
grep -Fq 'set +e' "$arm_wf" \
  || fail "gateint step must set +e so a refuse (exit 1) cannot fail the required arm check"
ok "reusable arm workflow wires the guard and gates the arm on it"

# --- wiring: the hourly queue pass refuses AND disarms -------------------
grep -Fq 'fleet-gate-arm-guard' "$tier1" \
  || fail "tier1 queue pass must call fleet-gate-arm-guard"
grep -Fq 'GATE-INTEGRITY not green' "$tier1" \
  || fail "tier1 must skip+disarm gate-path PRs whose gate is not green"
python3 - "$tier1" <<'PY' || fail "heartbeat must call the guard before gh pr merge --auto"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
queue = text.find("2. queue pass starting")
if queue < 0:
    raise SystemExit("queue pass marker missing")
gate = text.find("fleet-gate-arm-guard", queue)
disarm = text.find("--disable-auto", queue)
arm = text.find("--auto --squash", queue)
if gate < 0:
    raise SystemExit("queue pass must call fleet-gate-arm-guard")
if arm < 0:
    raise SystemExit("queue pass must still call gh pr merge --auto")
if gate > arm:
    raise SystemExit("gate-arm-guard must run BEFORE gh pr merge --auto in the queue pass")
if disarm < 0 or not (gate < disarm < arm):
    raise SystemExit("queue-pass refuse path must --disable-auto before the arm")
PY
ok "heartbeat queue pass runs the guard before arming and disarms on refuse"

# --- wiring: MANIFEST installs the evaluator for the live heartbeat -------
grep -Fq 'bin/fleet-gate-arm-guard' "$manifest" \
  || fail "MANIFEST must install bin/fleet-gate-arm-guard"
grep -Fq 'lib/gate-arm-guard.py' "$manifest" \
  || fail "MANIFEST must install lib/gate-arm-guard.py"
grep -Fq 'lib/gate-integrity-config.sh' "$manifest" \
  || fail "MANIFEST must install lib/gate-integrity-config.sh (live glob loader)"
ok "MANIFEST installs the guard"

# --- DEFAULT_GLOBS stay locked to the shared loader ------------------------
python3 - "$lib" "$repo_root/lib/gate-integrity-config.sh" <<'PY' \
  || fail "DEFAULT_GLOBS drifted from lib/gate-integrity-config.sh"
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("gag", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
got = json.loads(subprocess.check_output(["bash", sys.argv[2]], text=True))["gate_globs"]
if list(mod.DEFAULT_GLOBS) != got:
    raise SystemExit(f"{list(mod.DEFAULT_GLOBS)!r} != {got!r}")
PY
ok "DEFAULT_GLOBS match the shared loader defaults"

# --- wiring: P14 runs this test -------------------------------------------
grep -Fq 'bash tests/gate-arm-guard.test.sh' "$ci_yml" \
  || fail "ci.yml verify-command must run tests/gate-arm-guard.test.sh"
ok "test is registered in ci.yml"

# --- measure.sh reports the escape metric ---------------------------------
grep -Fq 'gate-escapes-24h' "$repo_root/measure.sh" \
  || fail "measure.sh must print the gate-escapes-24h line (issue metric)"
ok "measure.sh carries gate-escapes-24h"

echo "gate-arm-guard: all checks passed ($seen fixtures)"
