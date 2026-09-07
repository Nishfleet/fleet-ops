#!/usr/bin/env bash
# tests/fleet-provider-no-dangerous-modes.test.sh
#
# Regression pin (fleet-ops#4382): the repo templates for devin-provider
# and cursor-provider must never pass the vendor's most permissive mode.
#   - devin-provider: no "dangerous" permission-mode
#   - cursor-provider: no "--force" flag
# install.sh deploys these templates to the live seat files; if the repo
# ships the dangerous forms, every fresh deploy silently downgrades the
# fleet's primary seats. This test catches that.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

devin_tpl="$repo_root/template/extensions/devin-provider/index.ts"
cursor_tpl="$repo_root/template/extensions/cursor-provider/index.ts"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$devin_tpl" ]] || fail "missing template: $devin_tpl"
[[ -f "$cursor_tpl" ]] || fail "missing template: $cursor_tpl"

# --- devin-provider: must not pass --permission-mode dangerous -----------
if grep -q '"dangerous"' "$devin_tpl"; then
  fail "devin-provider template passes --permission-mode dangerous (fleet-ops#4382)"
fi
ok "devin-provider: no dangerous permission-mode"

# devin-provider: must use smart mode
if ! grep -q '"smart"' "$devin_tpl"; then
  fail "devin-provider template missing --permission-mode smart (fleet-ops#4382)"
fi
ok "devin-provider: uses smart permission-mode"

# devin-provider: must pass --sandbox
if ! grep -q '"--sandbox"' "$devin_tpl"; then
  fail "devin-provider template missing --sandbox flag (fleet-ops#4382)"
fi
ok "devin-provider: uses --sandbox flag"

# --- cursor-provider: must not pass --force ------------------------------
if grep -q '"--force"' "$cursor_tpl"; then
  fail "cursor-provider template passes --force (fleet-ops#4382)"
fi
ok "cursor-provider: no --force flag"

# cursor-provider: must use --auto-review
if ! grep -q '"--auto-review"' "$cursor_tpl"; then
  fail "cursor-provider template missing --auto-review flag (fleet-ops#4382)"
fi
ok "cursor-provider: uses --auto-review flag"

ok "fleet-provider-no-dangerous-modes: templates ship vendor-native safety modes (fleet-ops#4382)"
