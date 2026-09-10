#!/usr/bin/env bash
# tests/fleet-alert-detached-deadman-command-path.test.sh
#
# fleet-ops#4921: the DetachedJobDied alert description told alert-repair
# workers to run `bin/fleet-who-stopped <unit>` and
# `bin/pi-detached-deadman --clear <unit>` — bare cwd-relative `bin/...`
# paths with NO stated base directory. In the live 2026-09-10 alert-repair
# session the worker guessed a checkout that did not ship those scripts and
# `sed bin/pi-detached-deadman` failed with ENOENT, a failed command the
# session swallowed (FAILED-COMMAND-SWALLOWED, signal bin-pi-detached-deadman).
#
# This test locks the fix: the repair description must reference the two
# commands (a) by their installed-on-PATH names — never a bare relative
# `bin/...` path that depends on an unstated cwd — and (b) the named scripts
# must exist as shipped repo files, and (c) the description must name the
# canonical absolute source checkout so a worker can find them without
# guessing. A future change that reintroduces a cwd-dependent relative
# `bin/` path (or drops the canonical path) fails closed here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$rules" ]] || fail "missing: $rules"

REQUIRED_CMDS=(fleet-who-stopped pi-detached-deadman)
CANONICAL_CHECKOUT="/home/nish/workspaces/tooling/fleet-ops-deploy-clone"

# The two repair commands must be shipped scripts for the alert to name them.
for c in "${REQUIRED_CMDS[@]}"; do
  [[ -f "$repo_root/bin/$c" && -x "$repo_root/bin/$c" ]] \
    || fail "shipped script missing: bin/$c (the alert description names it)"
done
ok "repair commands ship as executable files under bin/: ${REQUIRED_CMDS[*]}"

python3 - "$rules" "$repo_root" <<'PY'
import os, re, sys
import yaml

path, repo_root = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = yaml.safe_load(f)

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)
def ok(msg):
    print(f"OK: {msg}")

RULES = re.compile(r"^config/fleet_rules.yml\s+", re.M)

det = None
for g in cfg.get("groups", []):
    for r in g.get("rules", []):
        if r.get("alert") == "DetachedJobDied":
            det = r["annotations"]["description"]
if det is None:
    fail("DetachedJobDied rule not found in config/fleet_rules.yml")

d = det  # shorthand

# (a) repair commands must be referenced by PATH name, not a bare relative bin path.
for cmd in ("fleet-who-stopped", "pi-detached-deadman"):
    if f"bin/{cmd}" in d:
        fail(f"DetachedJobDied description uses cwd-relative `bin/{cmd}` with no base dir — repair workers guess the checkout and swallow an ENOENT (fleet-ops#4921)")
    if cmd not in d:
        fail(f"DetachedJobDied description must advise the on-PATH command `{cmd}`")
    ok(f"description advises on-PATH command `{cmd}` (no bare bin/ prefix)")

# (c) the canonical source checkout must be named so a worker finds the scripts.
CANON = "/home/nish/workspaces/tooling/fleet-ops-deploy-clone"
if CANON not in d:
    fail(f"DetachedJobDied description must name the canonical source checkout {CANON} so a worker does not guess")
ok(f"description names the canonical source checkout {CANON}")

print("fleet-alert-detached-deadman-command-path: all invariants pass (fleet-ops#4921)")
PY