#!/usr/bin/env bash
# tests/gate-integrity-config.test.sh
#
# Proves each named repo gate set (0509, default, fleet-ops) is enforced
# when the shared decision script is invoked with that repo's
# `.fleet/gate-integrity.yml` (fleet-ops#303). No network, no mutation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
DECISION="$repo_root/.github/scripts/gate-integrity.sh"
CONFIG_LOADER="$repo_root/lib/gate-integrity-config.sh"
PASS_COUNT=0
FAIL_COUNT=0
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gi-config.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

HEAD="1111111111111111111111111111111111111111"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$DECISION" ]] || fail "missing $DECISION"
[[ -f "$CONFIG_LOADER" ]] || fail "missing $CONFIG_LOADER"

run_fixture() {
  local name="$1" expected="$2" must_contain="${3:-}"
  local rc=0 out="" ok=0 why=""
  out="$(bash "$DECISION" < "$WORK_DIR/$name.json")" || rc=$?
  if [[ "$expected" == "PASS" && $rc -eq 0 && "$out" == *"PASS:"* ]]; then ok=1; fi
  if [[ "$expected" == "FAIL" && $rc -ne 0 && "$out" == *"FAIL:"* ]]; then ok=1; fi
  if [[ $ok -eq 1 && -n "$must_contain" && "$out" != *"$must_contain"* ]]; then
    ok=0; why=" (missing expected output: $must_contain)"
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

run_configured() {
  local name="$1" config_json="$2" expected="$3" must_contain="${4:-}"
  local files_json="$5"
  python3 - "$WORK_DIR/$name.json" "$config_json" "$files_json" "$HEAD" <<'PY'
import json, sys
out, config_path, files_json, head = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(config_path, encoding="utf-8") as fh:
    config = json.load(fh)
bundle = {
    "head_sha": head,
    "files": json.loads(files_json),
    "commit_messages": [],
    "pr_body": "",
    "attestations": [],
    "permissions": {},
}
bundle.update(config)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(bundle, fh)
PY
  run_fixture "$name" "$expected" "$must_contain"
}

bash "$CONFIG_LOADER" "$here/fixtures/gate-integrity/0509.yml" > "$WORK_DIR/0509.json"
bash "$CONFIG_LOADER" "$here/fixtures/gate-integrity/default.yml" > "$WORK_DIR/default.json"
bash "$CONFIG_LOADER" "$repo_root/.fleet/gate-integrity.yml" > "$WORK_DIR/fleet-ops.json"

python3 - "$WORK_DIR/0509.json" "$WORK_DIR/default.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    a = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    b = json.load(fh)
for extra in (
    "scripts/ci-vitest-run.sh",
    "scripts/ci-verify-*.sh",
    "scripts/design-system-ratchet.mjs",
    "docs/design-system-ratchet.json",
):
    if extra not in a["gate_globs"]:
        raise SystemExit(f"0509 config missing {extra}")
    if extra in b["gate_globs"]:
        raise SystemExit(f"default config must not include {extra}")
if a["ratchet_paths"] != ["docs/design-system-ratchet.json"]:
    raise SystemExit("0509 ratchet_paths mismatch")
if b["ratchet_paths"] != []:
    raise SystemExit("default ratchet_paths must be empty")
print("ok   config-0509-vs-default-shape")
PY
PASS_COUNT=$((PASS_COUNT + 1))

CI_VITEST_FILES='[{"filename": "scripts/ci-vitest-run.sh", "status": "modified", "patch": "+# tweak"}]'
run_configured repo0509_ci_vitest "$WORK_DIR/0509.json" FAIL "gate-owned path changed" "$CI_VITEST_FILES"
run_configured default_ci_vitest "$WORK_DIR/default.json" PASS "" "$CI_VITEST_FILES"

RATCHET_RAISE_FILES='[{"filename": "docs/design-system-ratchet.json", "status": "modified", "patch": "-  \"raw-hex-color\": 258,\n+  \"raw-hex-color\": 400,"}]'
run_configured repo0509_ratchet_raise "$WORK_DIR/0509.json" FAIL "raised 258 -> 400" "$RATCHET_RAISE_FILES"
run_configured default_ratchet_raise "$WORK_DIR/default.json" PASS "" "$RATCHET_RAISE_FILES"

FLEET_DECISION_FILES='[{"filename": ".github/scripts/gate-integrity.sh", "status": "modified", "patch": "+# tweak"}]'
run_configured fleetops_decision_script "$WORK_DIR/fleet-ops.json" FAIL "gate-owned path changed" "$FLEET_DECISION_FILES"
run_configured default_decision_script "$WORK_DIR/default.json" FAIL "gate-owned path changed" "$FLEET_DECISION_FILES"

FLEET_CONFIG_FILES='[{"filename": ".fleet/gate-integrity.yml", "status": "modified", "patch": "+# widened"}]'
run_configured fleetops_own_config "$WORK_DIR/fleet-ops.json" FAIL "gate-owned path changed" "$FLEET_CONFIG_FILES"
run_configured default_own_config "$WORK_DIR/default.json" FAIL "gate-owned path changed" "$FLEET_CONFIG_FILES"
run_configured repo0509_own_config "$WORK_DIR/0509.json" FAIL "gate-owned path changed" "$FLEET_CONFIG_FILES"

LOADER_FILES='[{"filename": "lib/gate-integrity-config.sh", "status": "modified", "patch": "+# tweak"}]'
run_configured fleetops_loader "$WORK_DIR/fleet-ops.json" FAIL "gate-owned path changed" "$LOADER_FILES"
run_configured default_loader "$WORK_DIR/default.json" PASS "" "$LOADER_FILES"

bash "$CONFIG_LOADER" > "$WORK_DIR/no-file.json"
bash "$CONFIG_LOADER" "$WORK_DIR/does-not-exist.yml" > "$WORK_DIR/missing-file.json"
python3 - "$WORK_DIR/no-file.json" "$WORK_DIR/missing-file.json" "$WORK_DIR/default.json" <<'PY'
import json, sys
vals = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        vals.append(json.load(fh))
if vals[0] != vals[1] or vals[0]["gate_globs"] != vals[2]["gate_globs"]:
    raise SystemExit("missing config must equal the default fixture")
if "ratchet_paths" not in vals[0] or "ratchet_ceilings" in vals[0]:
    raise SystemExit("loader must emit ratchet_paths, not ratchet_ceilings")
print("ok   config-missing-equals-default")
PY
PASS_COUNT=$((PASS_COUNT + 1))

printf 'unknown_key: 1\n' > "$WORK_DIR/bad-key.yml"
if bash "$CONFIG_LOADER" "$WORK_DIR/bad-key.yml" >"$WORK_DIR/bad-key.out" 2>"$WORK_DIR/bad-key.err"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL unknown-config-key: loader accepted an unknown key\n'
else
  if grep -q "unknown key" "$WORK_DIR/bad-key.err"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok   unknown-config-key\n'
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL unknown-config-key: missing "unknown key" in stderr\n'
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
test "$FAIL_COUNT" -eq 0

# fleet-ops#497: CI host lock. Workers cannot add a verify-command line.
# This file must stay listed in ci.yml OR invoked from seat-lib.test.sh.
ci_yml="$repo_root/.github/workflows/ci.yml"
listed=0
hosted=0
grep -Fq 'bash tests/gate-integrity-config.test.sh' "$ci_yml" && listed=1 || true
grep -Fq 'bash "$here/gate-integrity-config.test.sh"' "$here/seat-lib.test.sh" && hosted=1 || true
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "gate-integrity-config.test.sh has no CI host (fleet-ops#497): list it in ci.yml or invoke it from seat-lib.test.sh"
fi
echo "OK: CI host exists (ci.yml listed=$listed seat-lib hosted=$hosted)"
