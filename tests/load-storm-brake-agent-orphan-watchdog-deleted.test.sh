#!/usr/bin/env bash
# tests/load-storm-brake-agent-orphan-watchdog-deleted.test.sh
#
# fleet-ops#4147 (child of #4140 row 8): the hand-built load-storm brake and
# all-agents orphan janitor were retired. The replacement is systemd-oomd +
# CPUWeight/IOWeight + cgroup scoping (`systemd-run --scope`,
# KillMode=control-group) — every agent launch runs as a scope/service so
# orphans cannot exist, and oomd + weights prevent load storms. Both scripts
# were live-only (never tracked in this repo).
#
# This test pins the retirement so a future rebuild is caught:
#   1. No load-storm-brake / agent-orphan-watchdog script in the repo's
#      active code dirs (bin/, lib/, libexec/).
#   2. No reference to them (or the `agent-governor-orphan-watchdog` unit) in
#      active code paths (prompts/, config/, systemd/, MANIFEST).
#   3. The design doc row 8 is marked DONE.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin. The LoadStorm
# prometheus ALERT name (config/fleet_rules.yml) is not the retired script and
# is intentionally NOT matched — it remains a monitoring alert that
# alert-repair-dispatch root-causes.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# The retired script/unit names to pin. "LoadStorm" alone is a live prometheus
# alert name and must stay; these names are the retired mechanism only.
names='load-storm-brake|agent-orphan-watchdog|agent-governor-orphan-watchdog'

# --- 1. no script in active code dirs --------------------------------------
for name in load-storm-brake agent-orphan-watchdog; do
  for dir in bin lib libexec; do
    f="$repo_root/$dir/$name"
    if [[ -e "$f" ]]; then
      fail "active code must not carry $f - $name was retired (#4147)"
    fi
  done
done
ok "no load-storm-brake/agent-orphan-watchdog script in bin/, lib/, libexec/"

# --- 2. no reference in active code paths -----------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) is the
# retirement record and is allowed. Everything else must be clean.
for path in prompts config systemd MANIFEST; do
  if grep -rnE "$names" "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference $names - retired (#4147)"
  fi
done
ok "no reference to the retired scripts in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 8 is marked DONE -------------------------------------
if ! grep -q 'load-storm-brake + agent-orphan-watchdog.*DONE' "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 8 must be marked DONE (#4147)"
fi
ok "design doc row 8 is marked DONE"

exit 0
