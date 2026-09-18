#!/usr/bin/env bash
# fleet-ops#7374: every seat-ledger reader and writer resolves to ONE directory
# (lanes/seats, where seat-health.ts writes real observations). A second copy
# under $STATE_DIR/seat-health parked every worker seat until 2036 and starved
# the fleet for 2.5 days (2026-09-15..17). This test fails the moment any
# organ or unit points the ledger somewhere else again.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
say() { printf '%s\n' "$*"; }
# 1. no unit may override the ledger dir to the dead copy
if grep -rn 'PI_SEAT_HEALTH_LEDGER_DIR=.*pi-packet/seat-health' "$ROOT/systemd" "$ROOT/bin" "$ROOT/lib" 2>/dev/null | grep -v '^\S*:\s*#'; then
    say "FAIL: a unit or script still pins PI_SEAT_HEALTH_LEDGER_DIR to pi-packet/seat-health"; fail=1
fi
# 2. no default may fall back to $STATE_DIR/seat-health
if grep -rn 'PI_SEAT_HEALTH_LEDGER_DIR:-\$STATE_DIR/seat-health' "$ROOT/bin" "$ROOT/lib" 2>/dev/null; then
    say "FAIL: a default still resolves the ledger to \$STATE_DIR/seat-health"; fail=1
fi
# 3. the lib and comeback-release agree on lanes/seats
grep -q 'LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-$HOME/workspaces/agent-state/lanes/seats}"' "$ROOT/lib/litellm-seat.sh" || { say "FAIL: lib default is not lanes/seats"; fail=1; }
# 4. behavioural: under a fake HOME the lib's seat_ledger_path lands in lanes/seats
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
got=$(HOME="$tmp" PI_PACKET_STATE="$tmp/pi-packet" bash -c 'source "$1/lib/litellm-seat.sh" >/dev/null 2>&1; seat_ledger_path litellm worker-cheap' _ "$ROOT")
[[ "$got" == "$tmp/workspaces/agent-state/lanes/seats/litellm__worker-cheap.json" ]] || { say "FAIL: seat_ledger_path resolved to $got"; fail=1; }
(( fail == 0 )) && say "PASS: seat ledger has a single directory (lanes/seats)"
exit $fail
