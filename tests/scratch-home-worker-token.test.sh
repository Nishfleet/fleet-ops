#!/usr/bin/env bash
# fleet-ops#6093 regression pin: the escalation-coverage canary's scratch
# HOME must carry a worker-token stub in $HOME/.local/bin. The #3445 gate
# (bin/pi-salvage-worktree:11, bin/fleet-credential-expiry-canary:78, and
# siblings) mints via ${HOME}/.local/bin/worker-token whenever GH_TOKEN is
# stripped and GITHUB_ACTIONS is unset — the bare-box shape of every local
# run. Without the harness provisioning (the #6152 drill pattern) those
# legs exit 1: the 09-12 SALVAGE-ORPHAN-FAIL and the 09-13 "GET /app 200
# must exit 0, got 1 ... worker-token: No such file or directory" reds.
# Invoked from tests/escalation-coverage-canary.test.sh (CI-listed file)
# so hosted runners run it without a workflow edit.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/../bin/fleet-credential-expiry-canary"

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -n "${HOME:-}" ]] || fail "HOME unset — not under the scratch-HOME fixture"

# --- 1. the stub is provisioned and mints -----------------------------------
[[ -x "$HOME/.local/bin/worker-token" ]] \
    || fail "scratch HOME lacks worker-token — the #3445 probe would fire (fleet-ops#6093)"
mint="$("$HOME/.local/bin/worker-token" --print)" || fail "worker-token stub --print failed"
grep -q '^GITHUB_TOKEN=' <<<"$mint" || fail "stub must mint a GITHUB_TOKEN assignment: $mint"
ok "scratch HOME provisions worker-token (fleet-ops#6093)"

# --- 2. a #3445-gated binary leg survives the stripped env ------------------
# Mirror credential-expiry-canary.test.sh's GET /app leg with the mint env
# forced on (GH_TOKEN stripped, GITHUB_ACTIONS empty, GH=gh): without the
# stub this is exactly the 09-13 red (binary line 78, exit 1). With the
# stub the mint succeeds and the leg passes regardless of the ambient
# GH_TOKEN, so the pin holds on worker shells and hosted runners too.
app_ok='{"id":4728578,"name":"nishfleet-worker","created_at":"2026-08-26T16:30:31Z"}'
WINDOW_NOW=2026-09-08T12:00:00Z
out="$(env -u GH_TOKEN GITHUB_ACTIONS= GH=gh "$bin" --app-returns "$app_ok" --now "$WINDOW_NOW" 2>&1)" \
    || fail "gated binary leg must exit 0 under the bare-box env, got: $out"
ok "#3445-gated binary leg exits 0 with GH_TOKEN stripped (mint via scratch stub)"
