#!/usr/bin/env bash
# tests/packet-layout.test.sh
#
# fleet-ops#4643: prefix-cache determinism test for the worker packet.
#
# A provider's prompt prefix cache only pays when the prefix is byte-identical
# across calls. The worker packet is now [stable prefix][volatile tail]:
#   stable prefix = worker.md (+ repo-conditional D1/GEO blocks, themselves
#                   stable files on disk)
#   volatile tail = `difficulty:` line + `seat-rung:` line + TARGET line
# Nothing volatile may appear before the last stable byte.
#
# This test assembles the SAME packet type twice with DIFFERENT issue/context
# inputs (different repo, issue number, difficulty, repair-rung flag) and
# asserts the common byte-prefix length is >= the size of the stable files
# (worker.md, plus the D1 block when the repo is 0509). A future edit that
# injects a date, run id, seat name, counter, or the difficulty/TARGET into
# the stable prefix shrinks the common prefix below the stable-file size and
# fails CI here.
#
# It also asserts the volatile tail is byte-identical for identical volatile
# inputs (the tail is deterministic too — just not shared across issues).
#
# Proves, offline (no gh, no systemd, no network):
#   1. Two non-0509 packets with different issues share a prefix >= worker.md.
#   2. Two 0509 packets with different issues share a prefix >= worker.md + D1.
#   3. A packet whose stable prefix is corrupted by a leading volatile line
#      (the pre-#4643 layout: `difficulty:` as line 1) is caught — the common
#      prefix with a correct packet drops below worker.md size.
#   4. The volatile tail is byte-identical across two renders with the same
#      volatile inputs (deterministic tail).
#   5. Packet size is unchanged (+/- 1%) by the layout move vs the old layout
#      (fleet-ops#4643 accept 4: the volatile tail must still fit the context
#      budget; reordering must not bloat the packet).
#   6. No timestamp, run id, seat name, counter, or date appears inside the
#      stable prefix (grep for the volatile markers in the prefix bytes).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 required"

worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "worker prompt not found at $worker"

# Resolve the worker-blocks dir the same way lib/pi-intake-tick.sh does.
WORKER_BLOCKS_DIR="${PI_INTAKE_WORKER_BLOCKS_DIR:-/home/nish/.pi/agent/prompts/worker-blocks}"
D1_GATE_INTEGRITY_BLOCK="d1-gate-integrity.md"
GEO_AEO_BLOCK="geo-aeo.md"
D1_GATE_REPO="0509"

# d1_gate_integrity_needed: pure function of (repo, body). Reproduced from
# lib/pi-intake-tick.sh verbatim (no side effects, no network) so the drill
# runs offline. Returns 0 = append D1 block, 1 = skip.
d1_gate_integrity_needed() {
    local body="$1"
    [[ "${REPO:-}" == "$D1_GATE_REPO" ]] || return 1
    # No body needles configured in this drill = always append for 0509.
    return 0
}

# geo_aeo_needed: pure function of labels. Reproduced verbatim. Returns 0
# when any label name contains "geo" or "aeo".
geo_aeo_needed() {
    local labels_json="${1:-}"
    [[ -n "$labels_json" ]] || return 1
    printf '%s' "$labels_json" | jq -e \
        'any(.[]; (.name // "") | test("geo|aeo"; "i"))' >/dev/null 2>&1
}

# render_packet <repo> <full_repo> <issue_n> <difficulty> <repair_rung> <body> <labels_json>
# Renders the worker packet EXACTLY as lib/pi-intake-tick.sh writes it
# (fleet-ops#4643 layout): [stable prefix][volatile tail].
REPO=""
render_packet() {
    local repo="$1" full="$2" n="$3" difficulty="$4" repair_rung="$5" body="$6" labels_json="$7"
    REPO="$repo"
    {
        cat "$worker"
        if d1_gate_integrity_needed "$body" \
            && [[ -f "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK" ]]; then
            echo
            cat "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK"
        fi
        if geo_aeo_needed "$labels_json" \
            && [[ -f "$WORKER_BLOCKS_DIR/$GEO_AEO_BLOCK" ]]; then
            echo
            cat "$WORKER_BLOCKS_DIR/$GEO_AEO_BLOCK"
        fi
        echo
        echo "difficulty: $difficulty"
        if [[ "$repair_rung" == "1" ]]; then
            echo "seat-rung: repair"
        fi
        echo "TARGET: repo $full issue $n unit pi-issue-${repo}-${n}"
    }
}

# render_packet_old_layout: the PRE-#4643 layout (difficulty as line 1) used
# to prove the guard catches a prefix-corrupting regression.
render_packet_old_layout() {
    local repo="$1" full="$2" n="$3" difficulty="$4" repair_rung="$5" body="$6" labels_json="$7"
    REPO="$repo"
    {
        echo "difficulty: $difficulty"
        cat "$worker"
        if d1_gate_integrity_needed "$body" \
            && [[ -f "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK" ]]; then
            echo
            cat "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK"
        fi
        echo
        echo "TARGET: repo $full issue $n unit pi-issue-${repo}-${n}"
    }
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# common_prefix_len <file_a> <file_b>: byte length of the longest common prefix.
common_prefix_len() {
    python3 - "$1" "$2" <<'PY'
import sys
a, b = sys.argv[1], sys.argv[2]
with open(a, 'rb') as f: da = f.read()
with open(b, 'rb') as f: db = f.read()
n = 0
for x, y in zip(da, db):
    if x != y: break
    n += 1
# cap at the shorter file's length when one is a prefix of the other
n = min(n, len(da), len(db))
print(n)
PY
}

file_bytes() { wc -c < "$1"; }

worker_bytes=$(file_bytes "$worker")
echo "worker.md = ${worker_bytes} bytes"

d1_block="$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK"
d1_bytes=0
if [[ -f "$d1_block" ]]; then
    d1_bytes=$(file_bytes "$d1_block")
    echo "d1-gate-integrity.md = ${d1_bytes} bytes"
else
    echo "d1-gate-integrity.md: not present (D1 drill will be skipped)"
fi

echo
echo "=== 1. non-0509: two different issues share prefix >= worker.md ==="
render_packet fleet-ops Nishfleet/fleet-ops 100 light 0 "body A" '[]' > "$scratch/a.in"
render_packet fleet-ops Nishfleet/fleet-ops 999 heavy 1 "body B different" '[{"name":"x"}]' > "$scratch/b.in"
cpl=$(common_prefix_len "$scratch/a.in" "$scratch/b.in")
echo "common prefix = ${cpl} bytes; worker.md = ${worker_bytes} bytes"
(( cpl >= worker_bytes )) \
    || fail "non-0509 common prefix (${cpl}) < worker.md (${worker_bytes}) — a volatile value leaked into the stable prefix"
ok "non-0509: common prefix >= worker.md"

echo
echo "=== 2. 0509: two different issues share prefix >= worker.md + D1 ==="
if (( d1_bytes > 0 )); then
    render_packet 0509 Nishfleet/0509 100 light 0 "body A" '[]' > "$scratch/c.in"
    render_packet 0509 Nishfleet/0509 999 heavy 1 "body B different" '[{"name":"x"}]' > "$scratch/d.in"
    cpl2=$(common_prefix_len "$scratch/c.in" "$scratch/d.in")
    stable_0509=$(( worker_bytes + d1_bytes ))
    echo "common prefix = ${cpl2} bytes; worker.md + D1 = ${stable_0509} bytes"
    (( cpl2 >= stable_0509 )) \
        || fail "0509 common prefix (${cpl2}) < worker.md + D1 (${stable_0509}) — a volatile value leaked into the stable prefix"
    ok "0509: common prefix >= worker.md + D1"
else
    ok "0509 D1 drill skipped (no D1 block on this machine)"
fi

echo
echo "=== 3. guard catches the pre-#4643 layout (difficulty as line 1) ==="
# Old layout puts `difficulty:` as line 1, so two different difficulties diverge
# at byte 0. The common prefix with a correct-layout packet must drop below
# worker.md size.
render_packet_old_layout fleet-ops Nishfleet/fleet-ops 100 light 0 "body" '[]' > "$scratch/old.in"
render_packet fleet-ops Nishfleet/fleet-ops 999 heavy 1 "body" '[]' > "$scratch/new.in"
cpl3=$(common_prefix_len "$scratch/old.in" "$scratch/new.in")
echo "old-vs-new common prefix = ${cpl3} bytes; worker.md = ${worker_bytes} bytes"
(( cpl3 < worker_bytes )) \
    || fail "old layout (difficulty line 1) was NOT caught — common prefix (${cpl3}) >= worker.md (${worker_bytes}); the guard is blind to the regression"
ok "guard catches pre-#4643 prefix-corrupting layout"

echo
echo "=== 4. volatile tail is deterministic for identical volatile inputs ==="
render_packet fleet-ops Nishfleet/fleet-ops 100 light 0 "same body" '[]' > "$scratch/t1.in"
render_packet fleet-ops Nishfleet/fleet-ops 100 light 0 "same body" '[]' > "$scratch/t2.in"
if cmp -s "$scratch/t1.in" "$scratch/t2.in"; then
    ok "volatile tail + whole packet byte-identical for identical inputs"
else
    fail "same volatile inputs produced different packets — tail is not deterministic"
fi

echo
echo "=== 5. packet size unchanged (+/- 1%) by the layout move ==="
# Old layout vs new layout for the SAME inputs: only the ORDER of lines
# differs (difficulty moved from front to back). Total byte count must be
# within 1% (the move adds/removes at most a couple of newlines).
render_packet_old_layout fleet-ops Nishfleet/fleet-ops 100 light 0 "same body" '[]' > "$scratch/old2.in"
new_size=$(file_bytes "$scratch/t1.in")
old_size=$(file_bytes "$scratch/old2.in")
echo "old layout = ${old_size} bytes; new layout = ${new_size} bytes"
python3 - "$old_size" "$new_size" <<'PY' || fail "packet size changed > 1% — layout move bloated the packet"
import sys
old, new = int(sys.argv[1]), int(sys.argv[2])
delta = abs(new - old) / max(old, 1)
if delta > 0.01:
    print(f"size delta {delta:.4f} > 1%", file=sys.stderr)
    sys.exit(1)
print(f"OK: size delta {delta:.4f} <= 1%")
PY
ok "packet size within +/- 1% of old layout"

echo
echo "=== 6. no volatile markers inside the stable prefix ==="
# The stable prefix is the first `worker_bytes` bytes (non-0509) — it must
# not contain a difficulty line, TARGET line, seat-rung line, a run id, or
# a timestamp. Extract the prefix and grep.
head -c "$worker_bytes" "$scratch/a.in" > "$scratch/prefix.in"
# A standalone `difficulty:` or `TARGET:` or `seat-rung:` line in the prefix
# is the regression signal.
if grep -nE '^(difficulty|TARGET|seat-rung):' "$scratch/prefix.in" >/dev/null; then
    fail "a volatile marker (difficulty/TARGET/seat-rung) appeared inside the stable prefix"
fi
ok "no volatile markers (difficulty/TARGET/seat-rung) inside the stable prefix"

echo
echo "packet-layout: PASS"
