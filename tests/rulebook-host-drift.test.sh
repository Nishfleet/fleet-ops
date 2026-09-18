#!/usr/bin/env bash
# tests/rulebook-host-drift.test.sh
#
# fleet-ops#5644: the live rulebook surfaces scoped two standing rules
# (Unattended write-autonomy; Full credential parity) to 'on
# `hostinger-kvm4`'. The fleet host moved to `netcup-rs2000` on 2026-08-10
# (vault decisions-ledger: "hostinger-kvm4 is RETIRED ... netcup-rs2000 is
# the sole fleet host"), so those bullets stopped binding any existing
# host — and they are the only place the VPS write-autonomy and
# credential-parity postures are stated.
#
# Gate: the live rulebook surfaces agents actually read must NEVER name the
# retired host. Hermetic fixtures prove the check works both ways; the live
# files are asserted on the VPS (GitHub runners do not have them).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

retired_host='hostinger-kvm4'

names_retired_host() {
    grep -q "$retired_host" "$1"
}

before="$repo_root/tests/fixtures/retired-host/before-stale-host.md"
after="$repo_root/tests/fixtures/retired-host/after-rescoped-host.md"
[[ -f "$before" && -f "$after" ]] || fail "missing retired-host fixtures"
if ! names_retired_host "$before"; then
    fail "stale-host fixture must contain the retired host name (got no match in $before)"
fi
if names_retired_host "$after"; then
    fail "rescoped wording must not name the retired host (got a match in $after)"
fi
ok "fixture check rejects the stale host name and accepts the rescoped wording"

# Live copies agents actually read. Skip cleanly when absent (GitHub
# runners); on the VPS all of them exist and this is the run.
live_docs=(
    /home/nish/AGENTS.md
    /home/nish/.claude/CLAUDE.md
    /home/nish/.codex/AGENTS.md
    /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md
)
live_checked=0
for f in "${live_docs[@]}"; do
    if [[ -f "$f" ]]; then
        if names_retired_host "$f"; then
            fail "$f names the retired host 'hostinger-kvm4' — every doc naming it as the live VPS reads as netcup-rs2000 (vault decisions-ledger 2026-08-28); re-scope to 'this VPS' (fleet-ops#5644)"
        fi
        live_checked=$((live_checked + 1))
    fi
done
if [[ "$live_checked" -eq "${#live_docs[@]}" ]]; then
    ok "all ${#live_docs[@]} live rulebook surfaces exist and name no retired host"
fi

# fleet-ops#5735: ~/.cursor/rules/shared-memory.mdc's nish-fleet-model-routing
# block still named Sol as the orchestrator and routed through the superseded
# DeepSeek/MiniMax/Luna launcher ladder. No generator renders that block (the
# standing-rules renderers were cut 2026-09-18, f8b567588, and never targeted
# this file; agent-surfaces.yaml block_types has no fleet-model-routing entry;
# the memory-compound tooling that renders the file's other blocks is
# quarantined), so the retired-ladder gate lives here on the live file.
# Markers are the routing CLAIMS, not the names: legit retired-notices say
# "Sol is retired" / "ladder ... history only" and must not trip this gate.
retired_ladder_markers=(
    'Sol at `medium` orchestrates'
    'serially by `implementation-worker-grok-auto`'
    'normal DeepSeek/OpenCode'
)

before_ladder="$repo_root/tests/fixtures/retired-ladder/before-drifted-ladder.mdc"
after_ladder="$repo_root/tests/fixtures/retired-ladder/after-pi-direct.mdc"
[[ -f "$before_ladder" && -f "$after_ladder" ]] || fail "missing retired-ladder fixtures"
for m in "${retired_ladder_markers[@]}"; do
    grep -qF "$m" "$before_ladder" || fail "drifted-ladder fixture must contain '$m' (got no match in $before_ladder)"
    if grep -qF "$m" "$after_ladder"; then
        fail "pi-direct fixture must not contain '$m' (got a match in $after_ladder)"
    fi
done
ok "fixture check rejects the retired-ladder routing claims and accepts the pi-direct wording"

cursor_mdc=/home/nish/.cursor/rules/shared-memory.mdc
if [[ -f "$cursor_mdc" ]]; then
    for m in "${retired_ladder_markers[@]}"; do
        if grep -qF "$m" "$cursor_mdc"; then
            fail "$cursor_mdc still carries the retired-ladder routing claim '$m' — Sol is retired (fleet-ops#4148) and the launcher ladder is history-only (fleet-ops docs/standing-rules.md shared-fleet-routing); rewrite the nish-fleet-model-routing block to the pi-direct wording (fleet-ops#5735)"
        fi
    done
    ok "live cursor shared-memory.mdc carries no retired-ladder routing claim"
fi

ok "hosting-drift gate holds"
