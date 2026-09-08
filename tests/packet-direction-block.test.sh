#!/usr/bin/env bash
# tests/packet-direction-block.test.sh
#
# fleet-ops#4562 (accept 4): the 0509 scout RESEARCH CONTEXT gains a
# **Direction** block fed from the decisions ledger — the block carries the
# `source: direction#4518` citation, degrades to an explicit (unavailable)
# marker when the ledger is missing, and is present in the assembled packet.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/packet-assembly.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "lib/packet-assembly.sh not found"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ledger="$tmp/decisions-ledger.md"
cat >"$ledger" <<'M'
## 2026-09-08 — unrelated entry

Some other decision.

## 2026-09-09 — 0509 direction: Acquisition, metric signups/week (senior panel, MATRIX-decided, Nish-vetoable)

Option 2 ACQUISITION, unpaid distribution only, no paid spend. Ticket: fleet-ops#4518.

## 2026-09-10 — later entry

Must NOT leak into the Direction block.
M

run_block() {
  PACKET_DIRECTION_LEDGER_FILE="$ledger" PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction" \
    bash -c 'source "$0"; packet_direction_block' "$lib"
}

# --- 1. block carries the verdict text and the citation line ----------------
out="$(run_block)"
grep -q 'source: direction#4518' <<<"$out" || fail "block missing source: direction#4518 citation"
grep -q 'ACQUISITION' <<<"$out" || fail "block missing the ledger verdict text"
ok "Direction block carries the ledger verdict + source: direction#4518"

# --- 2. section scope: verdict in, later entry out --------------------------
grep -q 'later entry' <<<"$out" && fail "block leaked a later ledger section"
grep -q 'unrelated entry' <<<"$out" && fail "block leaked an earlier ledger section"
ok "Direction block is scoped to exactly the direction ledger section"

# --- 3. missing ledger degrades loud-but-safe -------------------------------
out2="$(PACKET_DIRECTION_LEDGER_FILE="$tmp/absent.md" PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction" \
  bash -c 'source "$0"; packet_direction_block' "$lib")"
grep -q 'Direction (unavailable)' <<<"$out2" || fail "missing ledger did not print the unavailable marker"
grep -q 'do NOT invent one' <<<"$out2" || fail "unavailable block does not forbid inventing a citation"
ok "missing ledger degrades to the explicit unavailable marker"

# --- 4. assembled 0509 scout packet includes the Direction block ------------
# Minimal fakes so packet_assemble_0509_scout's other sources resolve or
# degrade (market signal staleness is fine — we only read the packet text).
export HOME="$tmp"
mkdir -p "$tmp/agent-state/cron-output" "$tmp/agent-state/0509-transformation" "$tmp/tooling/nish-vault"
fresh_signal="$tmp/agent-state/cron-output/0509-daily-market-signal-$(date -u +%Y-%m-%d).md"
printf '# fresh\n- signal\n' >"$fresh_signal"
printf 'bets\n' >"$tmp/agent-state/0509-transformation/current.md"

pkt="$tmp/packet.md"
PACKET_DIRECTION_LEDGER_FILE="$ledger" PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction" \
  bash -c 'source "$0"; packet_assemble_0509_scout "'"$repo_root"'/prompts/scout.md" 0509 "'"$pkt"'"' "$lib" >/dev/null 2>&1 || true
[[ -s "$pkt" ]] || fail "packet not assembled"
grep -q '## Direction' "$pkt" || fail "assembled packet has no Direction block"
grep -q 'direction#4518' "$pkt" || fail "assembled packet Direction block lacks the citation"
ok "assembled 0509 scout packet includes the Direction block with the citation"

echo "all packet-direction-block checks passed"
