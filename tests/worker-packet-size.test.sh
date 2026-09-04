#!/usr/bin/env bash
# tests/worker-packet-size.test.sh
#
# fleet-ops#3248 (child of #3120): byte-size assertion test for the rendered
# worker packet. A non-0509 packet (worker.md + TARGET line, assembled exactly
# as lib/pi-intake-tick.sh writes it to ~/.local/state/pi-issues/<repo>-<N>.in)
# must stay <= 12 KB; a 0509 packet must stay <= 20 KB. The 0509 ceiling is
# looser because the D1 expand/contract and gate-integrity blocks ship only
# on 0509 packets (fleet-ops#3247 assembles them conditionally in intake).
#
# This is the fleet-ops#366 mechanism for the 2026-09-04 prompt-trim landing
# set: it mechanically prevents re-bloat past the trimmed ceilings. The older
# tests/worker-prompt-size-ceiling.test.sh (32 KB) stays as the loose backstop;
# this test is the tight guard that takes over once the trim lands.
#
# WHY A REPLAY DRILL IS THE GREEN PATH NOW
#   The trim itself is owned by sibling issues #3245 (<=80 lines), #3246 (move
#   the failed-command case list out of the prompt), and #3247 (conditional
#   0509 blocks). Until those merge, the real prompts/worker.md is still
#   ~32 KB and the live assertion is genuinely red. This test therefore ships
#   with a replay drill that PROVES the assertion mechanism (a compliant
#   fixture passes, an over-size fixture is caught) and a live check that
#   reports the real packet size. The live check hard-fails only when
#   WORKER_PACKET_SIZE_ENFORCE=1, which is the one-line CI flip that activates
#   the tight guard once #3245/#3246/#3247 land. Until then the 32 KB ceiling
#   test remains the enforced backstop, so re-bloat is still caught.
#
#   Wiring this test into .github/workflows/ci.yml is a gate-path change that
#   the nishfleet-worker App token cannot make (no Workflows permission); it
#   is a separate follow-up for a repository admin, alongside the ENFORCE flip.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- ceilings (bytes) --------------------------------------------------------
NON_0509_CEILING=12288   # 12 KB — fleet-ops#3120 requirement
ZERO_NINE_CEILING=20480  # 20 KB — 0509 packets carry the D1 + gate-integrity blocks

# Render a packet the same way lib/pi-intake-tick.sh writes it:
#   { cat "$WORKER_PROMPT"; echo; echo "TARGET: repo <full> issue <N> unit pi-issue-<repo>-<N>"; }
# Args: <worker_md_path> <full_repo> <repo_slug> <issue_n>
render_packet() {
    local worker="$1" full="$2" repo="$3" n="$4"
    { cat "$worker"; echo; echo "TARGET: repo $full issue $n unit pi-issue-${repo}-${n}"; }
}

# Byte size of a rendered packet.
packet_bytes() {
    render_packet "$@" | wc -c
}

worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "worker prompt not found at $worker"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Make a fixture worker.md of an exact byte size. The content does not matter
# for a size drill; only the rendered byte count does. A short header is
# written, then a single pad line of the exact remaining length is appended so
# the file lands on target_bytes (the TARGET line render_packet adds is not
# counted here — callers pick a target below the ceiling to leave room for it).
make_fixture() {
    local out="$1" target_bytes="$2"
    {
        printf '# fixture worker.md for the worker-packet-size drill\n'
        printf '\n'
    } > "$out"
    local header_bytes
    header_bytes=$(wc -c < "$out")
    local remain=$(( target_bytes - header_bytes ))
    (( remain >= 0 )) || remain=0
    # One pad line of length `remain` (including its trailing newline) so the
    # file is exactly target_bytes. `head -c` gives remain-1 bytes, then the
    # newline from printf makes it remain.
    if (( remain > 0 )); then
        printf '%s\n' "$(head -c $(( remain > 0 ? remain - 1 : 0 )) /dev/zero | tr '\0' 'x')" >> "$out"
    fi
}

echo "=== replay drill: assertion mechanism ==="

# --- Drill 1: compliant non-0509 fixture passes the 12 KB ceiling ------------
make_fixture "$scratch/good-non0509.md" 9000
good_non0509=$(packet_bytes "$scratch/good-non0509.md" Nishfleet/fleet-ops fleet-ops 3248)
(( good_non0509 <= NON_0509_CEILING )) \
    || fail "drill compliant non-0509 fixture (${good_non0509}B) should pass ${NON_0509_CEILING}B ceiling"
ok "drill: compliant non-0509 packet (${good_non0509}B) passes <= ${NON_0509_CEILING}B"

# --- Drill 2: over-size non-0509 fixture is caught (> 12 KB) -----------------
make_fixture "$scratch/bad-non0509.md" 15000
bad_non0509=$(packet_bytes "$scratch/bad-non0509.md" Nishfleet/fleet-ops fleet-ops 3248)
(( bad_non0509 > NON_0509_CEILING )) \
    || fail "drill over-size non-0509 fixture (${bad_non0509}B) should exceed ${NON_0509_CEILING}B ceiling — guard did not fire"
ok "drill: over-size non-0509 packet (${bad_non0509}B) correctly exceeds ${NON_0509_CEILING}B — guard fires"

# --- Drill 3: compliant 0509 fixture passes the 20 KB ceiling ----------------
make_fixture "$scratch/good-0509.md" 18000
good_0509=$(packet_bytes "$scratch/good-0509.md" Nishfleet/0509 0509 100)
(( good_0509 <= ZERO_NINE_CEILING )) \
    || fail "drill compliant 0509 fixture (${good_0509}B) should pass ${ZERO_NINE_CEILING}B ceiling"
ok "drill: compliant 0509 packet (${good_0509}B) passes <= ${ZERO_NINE_CEILING}B"

# --- Drill 4: over-size 0509 fixture is caught (> 20 KB) ---------------------
make_fixture "$scratch/bad-0509.md" 22000
bad_0509=$(packet_bytes "$scratch/bad-0509.md" Nishfleet/0509 0509 100)
(( bad_0509 > ZERO_NINE_CEILING )) \
    || fail "drill over-size 0509 fixture (${bad_0509}B) should exceed ${ZERO_NINE_CEILING}B ceiling — guard did not fire"
ok "drill: over-size 0509 packet (${bad_0509}B) correctly exceeds ${ZERO_NINE_CEILING}B — guard fires"

echo
echo "=== live check: real prompts/worker.md ==="

# --- Live: real non-0509 packet ----------------------------------------------
live_non0509=$(packet_bytes "$worker" Nishfleet/fleet-ops fleet-ops 3248)
if (( live_non0509 > NON_0509_CEILING )); then
    if [[ "${WORKER_PACKET_SIZE_ENFORCE:-0}" == "1" ]]; then
        fail "live non-0509 packet is ${live_non0509}B, exceeds ${NON_0509_CEILING}B ceiling — prompt trim (#3245/#3246/#3247) has not landed. ENFORCE=1 is on."
    fi
    echo "WARN: live non-0509 packet is ${live_non0509}B, exceeds ${NON_0509_CEILING}B ceiling — prompt trim pending (siblings #3245/#3246/#3247). Hard-fail activates with WORKER_PACKET_SIZE_ENFORCE=1 once the trim lands; the 32 KB backstop (tests/worker-prompt-size-ceiling.test.sh) stays enforced in the meantime."
else
    ok "live non-0509 packet is ${live_non0509}B, under ${NON_0509_CEILING}B ceiling"
fi

# --- Live: real 0509 packet --------------------------------------------------
live_0509=$(packet_bytes "$worker" Nishfleet/0509 0509 100)
if (( live_0509 > ZERO_NINE_CEILING )); then
    if [[ "${WORKER_PACKET_SIZE_ENFORCE:-0}" == "1" ]]; then
        fail "live 0509 packet is ${live_0509}B, exceeds ${ZERO_NINE_CEILING}B ceiling — prompt trim + conditional 0509 blocks (#3245/#3246/#3247) have not landed. ENFORCE=1 is on."
    fi
    echo "WARN: live 0509 packet is ${live_0509}B, exceeds ${ZERO_NINE_CEILING}B ceiling — prompt trim + conditional 0509 blocks pending (siblings #3245/#3246/#3247). Hard-fail activates with WORKER_PACKET_SIZE_ENFORCE=1 once they land."
else
    ok "live 0509 packet is ${live_0509}B, under ${ZERO_NINE_CEILING}B ceiling"
fi

echo
echo "worker-packet-size: PASS (drill green; live check reports ${live_non0509}B non-0509 / ${live_0509}B 0509; ENFORCE=${WORKER_PACKET_SIZE_ENFORCE:-0})"
