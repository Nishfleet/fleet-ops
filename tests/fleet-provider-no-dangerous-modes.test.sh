#!/usr/bin/env bash
# tests/fleet-provider-no-dangerous-modes.test.sh
#
# Regression pin (fleet-ops#4382, devin half re-pinned by fleet-ops#4780):
# the repo templates must never SILENTLY drift from the endorsed live seat
# arguments. install.sh deploys these templates to the live seat files, so a
# template that disagrees with the endorsed live form either downgrades the
# seat on the next deploy or makes install.sh refuse to overwrite (which is
# what happened 2026-09-09T17:44Z: every deploy tick went red).
#   - cursor-provider: no "--force" flag  (unchanged, fleet-ops#4382)
#   - devin-provider:  no "--sandbox"     (fleet-ops#4780, see below)
#
# The devin pin is INVERTED relative to fleet-ops#4382 on purpose. Since
# 2026-09-08 the vendor's "--sandbox" forces Devin's autonomous permission
# mode, which rejects every non-interactive file write ("rejected a tool call
# that requires confirmation"), so 100% of sandboxed runs ended empty at the
# first edit. Probe PROBE-E (`pi --provider devin`) passes unsandboxed and
# fails sandboxed. Nish's standing order of 2026-09-09 16:20Z: the provider
# runs "--permission-mode dangerous, no sandbox", and "never re-add --sandbox
# without the probe passing". The safety content is unchanged on this host:
# every other seat already runs unsandboxed under the VPS write-autonomy rule
# (Nish, 2026-08-05). What this test still guarantees is that neither form
# changes SILENTLY -- which was fleet-ops#4382's actual purpose.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

devin_tpl="$repo_root/template/extensions/devin-provider/index.ts"
cursor_tpl="$repo_root/template/extensions/cursor-provider/index.ts"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$devin_tpl" ]] || fail "missing template: $devin_tpl"
[[ -f "$cursor_tpl" ]] || fail "missing template: $cursor_tpl"

# --- devin-provider: must match the endorsed live form (fleet-ops#4780) --
# must NOT pass --sandbox: it forces autonomous mode, which rejects all writes
if grep -q '"--sandbox"' "$devin_tpl"; then
  fail "devin-provider template passes --sandbox; it rejects every file write since 2026-09-08 (fleet-ops#4780)"
fi
ok "devin-provider: no --sandbox flag"

# must pin the endorsed permission-mode so the form cannot drift silently
if ! grep -q '"dangerous"' "$devin_tpl"; then
  fail "devin-provider template missing the endorsed --permission-mode dangerous (fleet-ops#4780)"
fi
ok "devin-provider: uses the endorsed permission-mode"

# the inversion must stay cited in the template itself, so nobody "fixes" it back
if ! grep -q 'fleet-ops#4780\|2026-09-09 (Fable)' "$devin_tpl"; then
  fail "devin-provider template drops the citation for the unsandboxed form (fleet-ops#4780)"
fi
ok "devin-provider: unsandboxed form is cited in-template"

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

ok "fleet-provider-no-dangerous-modes: templates match the endorsed live seat forms (fleet-ops#4382, #4780)"
