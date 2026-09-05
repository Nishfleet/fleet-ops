#!/usr/bin/env bash
# fleet-ops#3238: the packet's difficulty header comes from the issue, not the packet size.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"; lib="$repo_root/lib/seat-lib.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
grep -qF 'issue_difficulty() {' "$tick" || fail "issue_difficulty() not defined in tick"
grep -qF 'echo "difficulty: $(issue_difficulty "${labels[$i]}" "$title" "$body")"' "$tick" || fail "tick must emit the difficulty header as the packet's first line"
ok "Test 1: helper defined and wired at packet-write"
eval "$(sed -n '/^DIFFICULTY_HEAVY_BODY_BYTES=/,/^}/p' "$tick")"
[[ "$(issue_difficulty '["agent-ready","critical-path"]' 'trim worker.md — part 1/5' '- required: one thing
- accept: done')" == "light" ]] || fail "one requirement, short body must be light"
[[ "$(issue_difficulty '["agent-ready"]' 'big packet' "$(for i in 1 2 3 4; do echo "- required: thing $i"; done)")" == "heavy" ]] || fail "more than 2 required lines must be heavy"
[[ "$(issue_difficulty '["agent-ready","heavy"]' 'x' 'short')" == "heavy" ]] || fail "heavy label must be heavy"
[[ "$(issue_difficulty '["agent-ready"]' 'keystone: rewrite the router' 'short')" == "keystone" ]] || fail "keystone: title prefix must be keystone"
[[ "$(issue_difficulty '["agent-ready","keystone"]' 'x' 'short')" == "keystone" ]] || fail "keystone label must be keystone"
[[ "$(issue_difficulty '["agent-ready"]' 'Manager loop for heavy/keystone issues — part 3/9' '- required: one thing')" == "light" ]] || fail "a title merely mentioning keystone must NOT be keystone"
[[ "$(issue_difficulty '[]' 'x' "$(head -c 7000 /dev/zero | tr '\0' 'a')")" == "heavy" ]] || fail "body over 6000 bytes must be heavy"
ok "Test 2: classification rules"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
head -c 30000 /dev/zero | tr '\0' 'a' > "$scratch/worker.md"; { cat "$scratch/worker.md"; echo; echo "TARGET: repo Nishfleet/fleet-ops issue 1 unit pi-issue-fleet-ops-1"; } > "$scratch/p.in"
w=$(bash -c 'source "$0"; PI_PACKET_BASE_PROMPT="$1" task_weight "$2"' "$lib" "$scratch/worker.md" "$scratch/p.in")
[[ "$w" == "light" ]] || fail "task_weight fallback must not count the base prompt bytes (got $w)"
ok "Test 3: seat-lib fallback subtracts the base prompt"
echo "PASS: pi-intake-tick-difficulty-from-issue"
