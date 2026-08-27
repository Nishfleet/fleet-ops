#!/usr/bin/env bash
# tests/fleet-vault-knowledge-format.test.sh
#
# fleet-ops#525: shape check for the vault knowledge-format lint timer.
# The lint script lives in nish-vault because it writes the shared-memory
# report and 03 Knowledge hub contents; this test locks the fleet-ops side:
# the unit files parse, the timer is installable, MANIFEST ships them, the
# rule-enforcement matrix names the rule as enforced, and the lint script is
# reachable and executable on the VPS.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
svc="$repo_root/systemd/vault-knowledge-format.service"
timer="$repo_root/systemd/vault-knowledge-format.timer"
lint="/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/vault-knowledge-lint.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
grep -q 'ExecStart=/bin/sh ' "$svc" \
  || fail "service must invoke the lint through /bin/sh"
grep -qF "$lint" "$svc" \
  || fail "service must point to $lint"
ok "service exists and references the lint script"

grep -q '^\[Install\]$' "$timer" \
  || fail "timer must have [Install] so install.sh can enable it"
grep -q 'OnCalendar=' "$timer" \
  || fail "timer must have OnCalendar"
ok "timer has [Install] and OnCalendar"

grep -q '^systemd/vault-knowledge-format.service' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install the service"
grep -q '^systemd/vault-knowledge-format.timer' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install the timer"
ok "MANIFEST ships the service and timer"

python3 - "$repo_root/config/rule-enforcement.json" <<'PY' || fail "rule-enforcement matrix misconfigured"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
row = next((r for r in data["rules"] if r["id"] == "sr-vault-knowledge-format"), None)
if row is None:
    raise SystemExit("sr-vault-knowledge-format row missing")
if row.get("status") != "enforced":
    raise SystemExit(f"status must be enforced, got {row.get('status')}")
proof = row.get("proof", "")
mechanism = row.get("mechanism", "")
if "vault-knowledge-lint.sh" not in proof:
    raise SystemExit("proof must point to vault-knowledge-lint.sh")
if "vault-knowledge-format" not in mechanism + proof:
    raise SystemExit("mechanism/proof must reference vault-knowledge-format")
PY
ok "rule-enforcement.json: sr-vault-knowledge-format is enforced"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no "$svc" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for $svc"
  systemd-analyze verify --man=no "$timer" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for $timer"
  ok "systemd-analyze verify accepts the service and timer"
else
  ok "SKIP: systemd-analyze not on PATH"
fi

if [[ -f "$lint" && -s "$lint" ]]; then
  # The script lives in nish-vault and is not fleet-ops-tracked; the service
  # runs it through /bin/sh so it does not need the execute bit on disk.
  head -n 1 "$lint" | grep -qE '^#!/bin/sh|#!/usr/bin/env bash' \
    || fail "lint script must be a /bin/sh or bash script"
  ok "lint script is present and is a shell script"
else
  ok "SKIP: lint script not present (hosted CI)"
fi

echo "OK: fleet-vault-knowledge-format: units, MANIFEST, matrix, and lint wiring locked"
