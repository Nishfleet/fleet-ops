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

# ---------------------------------------------------------------------------
# fleet-ops#5087: the SAME copy-installed configs are byte-compared by
# check_live_matches_origin_main, which reported DRIFT-ORIGIN forever on a
# live seat-caps.json that install.sh --check already accepts as semantically
# equal (fleet-ops#4894/#4948). Pin the JSON-equivalence guard: it must accept
# a re-serialized copy, and must still report a real content change.
grep -qE '^def copy_installed_json_equivalent\(' bin/fleet-ops-drift.py \
  || fail "bin/fleet-ops-drift.py defines no copy_installed_json_equivalent (fleet-ops#5087)"
grep -qE 'not copy_installed_json_equivalent\(' bin/fleet-ops-drift.py \
  || fail "check_live_matches_origin_main does not consult copy_installed_json_equivalent (fleet-ops#5087)"

python3 - <<'PY' || fail "copy_installed_json_equivalent behaves wrong (fleet-ops#5087)"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fleet_ops_drift", "bin/fleet-ops-drift.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
eq = mod.copy_installed_json_equivalent

# Same JSON document, re-serialized (key order + \uXXXX re-escaping) — the
# live seat-caps.json shape fleet-ops#4894/#4948 documented.
expected = b'{ "providers": { "devin": { "cap": 10, "note": "a b" } } }'
actual = b'{"providers":{"devin":{"note":"a\\u0020b","cap":10}}}'
assert eq("config/seat-caps.json", actual, expected), "re-serialized copy must be equivalent"
assert eq("config/pi-models.json", actual, expected), "every copy-install name is covered"

# A real content change must still be drift.
changed = b'{"providers":{"devin":{"note":"a b","cap":11}}}'
assert not eq("config/seat-caps.json", changed, expected), "a changed cap must still be drift"

# Out of scope: a non-copy-install src keeps the byte compare (a stale
# checkout is exactly the drift signal that lives there).
assert not eq("config/intake-repos.json", actual, expected), "non-copy-install src must keep the byte compare"

# Neither body JSON -> not equivalent (never mask unparseable drift).
assert not eq("config/seat-caps.json", b"not json", b"also not json"), "non-JSON must not be equivalent"
assert not eq("config/seat-caps.json", actual, b"not json"), "unparseable expected side must not be equivalent"
print("OK: copy_installed_json_equivalent accepts re-serialization and still reports real drift")
PY
ok "check_live_matches_origin_main tolerates re-serialized copy-install JSON (fleet-ops#5087)"
