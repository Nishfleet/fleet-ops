#!/usr/bin/env bash
# tests/fleet-provider-no-dangerous-modes.test.sh
#
# Regression pin (fleet-ops#4382, devin half re-pinned by fleet-ops#4780,
# cursor half re-pinned by fleet-ops#5174):
# the repo templates must never SILENTLY drift from the endorsed live seat
# arguments. install.sh deploys these templates to the live seat files, so a
# template that disagrees with the endorsed live form either downgrades the
# seat on the next deploy or makes install.sh refuse to overwrite (which is
# what happened 2026-09-09T17:44Z: every deploy tick went red).
#   - cursor-provider: "--force", never "--auto-review" (fleet-ops#5174)
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

# --- cursor-provider: must use --force, never --auto-review (fleet-ops#5174)
# The cursor pin is INVERTED relative to fleet-ops#4382 for the same reason
# the devin pin was inverted by fleet-ops#4780: the vendor "safe" mode kills
# non-interactive writes. `--auto-review` is a server classifier that
# auto-runs "safe" tool calls and PROMPTS for the rest — under `--print`
# there is no approval UI, so the prompt is discarded and the write never
# happens. Two consecutive orchestrator-decision-sweep runs on
# cursor/cursor-grok-4.6-high (2026-09-10 21:51Z and 22:28Z) drafted verdicts
# and landed zero GitHub writes, parking every needs-orchestrator ticket.
# `--force` allows all commands unless explicitly denied — the
# permissions.deny list in ~/.cursor/cli-config.json still applies, and the
# seat's blast radius stays bounded by the nishfleet-worker token scope,
# protected main, and the fleet's own merge gates. Same write-autonomy class
# every other seat runs under the standing VPS rule (Nish 2026-08-05).
# Live proof 2026-09-11: `cursor-agent --print --force --model
# cursor-grok-4.6-high` accepted a `gh issue comment` write on fleet-ops#5174.
if grep -q '"--auto-review"' "$cursor_tpl"; then
  fail "cursor-provider template passes --auto-review; it silently discards non-interactive writes (fleet-ops#5174)"
fi
ok "cursor-provider: no --auto-review flag"

# must pin the endorsed force form so the form cannot drift silently
if ! grep -q '"--force"' "$cursor_tpl"; then
  fail "cursor-provider template missing the endorsed --force flag (fleet-ops#5174)"
fi
ok "cursor-provider: uses --force flag"

# the inversion must stay cited in the template itself, so nobody "fixes" it back
if ! grep -q 'fleet-ops#5174' "$cursor_tpl"; then
  fail "cursor-provider template drops the citation for the --force form (fleet-ops#5174)"
fi
ok "cursor-provider: --force form is cited in-template"

ok "fleet-provider-no-dangerous-modes: templates match the endorsed live seat forms (fleet-ops#4382, #4780, #5174)"
