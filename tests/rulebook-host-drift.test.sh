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

ok "hosting-drift gate holds"
