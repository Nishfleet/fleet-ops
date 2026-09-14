#!/usr/bin/env bash
# fleet-ops#6537: bin/fleet-ops-drift.py's parse_manifest skipped every
# @-templated basename when building expected_enabled, so enabled instances
# of a MANIFEST-installed template (gh-runner@{1,2,3}.service, shipped by
# #5935) could never count as expected — the DRIFT-UNITS extra-enabled
# finding re-fired structurally on every heartbeat tick (issue #6366 stayed
# open because observe-to-close can never go green).
#
# Pins, offline (in-process, stubbed run()/TRIAGE/AUDIT_LOG):
#   1. parse_manifest collects MANIFEST-installed [Install] templates into
#      expected_templates; a template present in systemd/ but NOT installed
#      via the MANIFEST never lands there (spec guard).
#   2. check_enabled_units is green with gh-runner@{1,2,3}.service enabled.
#   3. The guard: an enabled instance of a NON-MANIFEST template still
#      alarms as extra-enabled.
#   4. The missing-enabled direction is unchanged (plain.service absent
#      still alarms; enrolled intake timer absent still alarms).
#   5. An intake instance of a repo NOT in config/intake-repos.json stays
#      canary-expected under the template rule — that class is policed by
#      the intake reconciler's undeclared-drift disable (fleet-ops#32),
#      while the per-repo missing direction above is unchanged.
#
# Run: bash tests/fleet-ops-drift-template-instances.test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }
python3 -m py_compile bin/fleet-ops-drift.py || fail "bin/fleet-ops-drift.py does not compile"

python3 - <<'PY' || fail "template-instance behavior regressed (fleet-ops#6537)"
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("drift", "bin/fleet-ops-drift.py")
m = importlib.util.module_from_spec(spec)
sys.modules["drift"] = m
spec.loader.exec_module(m)

scratch = Path(tempfile.mkdtemp(prefix="drift-template-6537."))
m.TRIAGE = scratch / "triage.md"
m.AUDIT_LOG = scratch / "audit.log"
m.HOME = scratch  # user_systemd_dir resolves under the scratch home

systemd = scratch / "systemd"
systemd.mkdir()
user_dir = scratch / ".config" / "systemd" / "user"
user_dir.mkdir(parents=True)

UNIT = "[Unit]\nDescription=t\n[Install]\nWantedBy=default.target\n"
(systemd / "gh-runner@.service").write_text(UNIT)
(systemd / "plain.service").write_text(UNIT)
(systemd / "rogue@.service").write_text(UNIT)  # in systemd/, NOT in MANIFEST

scratch_manifest = scratch / "MANIFEST"
scratch_manifest.write_text(
    f"systemd/gh-runner@.service {user_dir}/gh-runner@.service\n"
    f"systemd/plain.service {user_dir}/plain.service\n"
)

# --- stub run(): is-enabled + list-unit-files backed by ENABLED ------------
ENABLED: set[str] = set()

def fake_run(cmd, cwd=None, check=True, capture=True):
    # argv shape: [systemctl, --user, <subcommand>, ...]
    sub = cmd[2]
    if sub == "is-enabled":
        unit = cmd[3]
        return (0, "", "") if unit in ENABLED else (1, "", "")
    if sub == "list-unit-files":
        out = "".join(f"{u} enabled enabled\n" for u in sorted(ENABLED))
        return (0, out, "")
    raise AssertionError(f"unexpected systemctl call: {cmd}")

m.run = fake_run

def run_check(checkout):
    """Run check_enabled_units; return (ok, stderr_tail)."""
    import io
    import contextlib
    _, _, templates = m.parse_manifest(checkout)
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            m.check_enabled_units(checkout, m.parse_manifest(checkout)[1], templates)
        return True, err.getvalue()
    except SystemExit:
        return False, err.getvalue()

# 1. parse_manifest: templates collected, non-MANIFEST template excluded.
_, expected_enabled, expected_templates = m.parse_manifest(scratch)
assert expected_templates == {"gh-runner@.service"}, expected_templates
assert "rogue@.service" not in expected_templates
assert "plain.service" in expected_enabled
assert "gh-runner@.service" not in expected_enabled

# 2. matches_template: instances and the template itself match.
assert m.matches_template("gh-runner@1.service", expected_templates)
assert m.matches_template("gh-runner@.service", expected_templates)
assert not m.matches_template("rogue@9.service", expected_templates)
assert not m.matches_template("plain.service", expected_templates)

# 3. Green with gh-runner@{1,2,3} enabled (the #6366 alarm class).
ENABLED = {"gh-runner@1.service", "gh-runner@2.service", "gh-runner@3.service",
           "plain.service"}
ok_run, err = run_check(scratch)
assert ok_run, f"expected green, got: {err}"
assert "extra-enabled" not in err

# 4. Guard: instance of a NON-MANIFEST template still alarms extra-enabled.
ENABLED = ENABLED | {"rogue@9.service"}
ok_run, err = run_check(scratch)
assert not ok_run and "extra-enabled: rogue@9.service" in err, err
ENABLED = ENABLED - {"rogue@9.service"}

# 5. Missing-enabled direction unchanged for concrete expected units.
ENABLED = ENABLED - {"plain.service"}
ok_run, err = run_check(scratch)
assert not ok_run and "missing-enabled: plain.service" in err, err

# 6. Intake: enrolled repo's timers still expected; absent still alarms.
config = scratch / "config"
config.mkdir()
(config / "intake-repos.json").write_text(json.dumps({"repos": [{"name": "demo"}]}))
ENABLED = {"gh-runner@1.service", "gh-runner@2.service", "gh-runner@3.service",
           "plain.service", "pi-intake@demo.timer", "pi-scout@demo.timer"}
ok_run, err = run_check(scratch)
assert ok_run, f"expected green with enrolled intake timers, got: {err}"

ENABLED = ENABLED - {"pi-intake@demo.timer"}
ok_run, err = run_check(scratch)
assert not ok_run and "missing-enabled: pi-intake@demo.timer" in err, err

# 7. Rogue intake instance: canary-expected under the template rule; the
#    intake reconciler's undeclared-drift disable owns that class.
ENABLED = ENABLED | {"pi-intake@demo.timer", "pi-intake@rogue.timer"}
ok_run, err = run_check(scratch)
assert ok_run, f"rogue intake instance should not alarm here: {err}"

print("all template-instance cases green")
PY
ok "fleet-ops-drift: MANIFEST-installed template instances expected-enabled; non-MANIFEST templates still alarm (fleet-ops#6537)"
