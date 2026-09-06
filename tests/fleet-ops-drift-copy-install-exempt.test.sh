#!/usr/bin/env bash
# fleet-ops#3858: MANIFEST files installed as COPIES (seat-caps.json per
# fleet-ops#2910, pi-models.json per #3838) must be exempt from
# bin/fleet-ops-drift.py's must-be-a-symlink check. When #3838 added
# pi-models.json without the exemption, every deploy tick went
# "LOUD DEPLOY-CHECK-FAILED ... DIFF-FILE: ~/.pi/agent/models.json is a
# regular file" and auto-filed #3858 on a file that is a copy by design.
# Pins COPY_INSTALLED_SRC_NAMES to MANIFEST both ways: every copy-install
# is exempt, and every exempt name is still a MANIFEST config/ src.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

names=$(python3 - <<'PY'
import ast, sys
tree = ast.parse(open("bin/fleet-ops-drift.py").read())
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
        getattr(t, "id", "") == "COPY_INSTALLED_SRC_NAMES" for t in node.targets
    ):
        print("\n".join(sorted(ast.literal_eval(node.value))))
        sys.exit(0)
sys.exit(3)
PY
) || fail "bin/fleet-ops-drift.py defines no COPY_INSTALLED_SRC_NAMES set literal (fleet-ops#3858)"

for n in seat-caps.json pi-models.json model-candidates.json; do
  grep -qxF "$n" <<<"$names" \
    || fail "$n is copy-installed per MANIFEST but missing from COPY_INSTALLED_SRC_NAMES (fleet-ops#3858)"
done
while IFS= read -r n; do
  [ -n "$n" ] || continue
  grep -qE "^config/${n}[[:space:]]" MANIFEST \
    || fail "COPY_INSTALLED_SRC_NAMES names $n but MANIFEST has no config/$n entry (stale exemption)"
done <<<"$names"
grep -qE 'if src\.name in COPY_INSTALLED_SRC_NAMES:' bin/fleet-ops-drift.py \
  || fail "the symlink check in bin/fleet-ops-drift.py does not consult COPY_INSTALLED_SRC_NAMES"
grep -qE 'if src\.name == "seat-caps.json":' bin/fleet-ops-drift.py \
  && fail "single-name seat-caps.json exemption still present (fleet-ops#3858)"
python3 -m py_compile bin/fleet-ops-drift.py || fail "bin/fleet-ops-drift.py does not compile"
ok "fleet-ops-drift exempts every MANIFEST copy-install from the symlink check: $(tr '\n' ' ' <<<"$names")(fleet-ops#3858)"
