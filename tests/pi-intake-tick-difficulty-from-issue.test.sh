#!/usr/bin/env bash
# fleet-ops#3238: the packet's difficulty header comes from the issue, not the packet size.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"; lib="$repo_root/lib/litellm-seat.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
grep -qF 'issue_difficulty() {' "$tick" || fail "issue_difficulty() not defined in tick"
# fleet-ops#3281: intake captures the difficulty once (needed for the heavy-class
# memory drop-in) and emits it as the packet's first line. Assert both the
# capture and the header write.
grep -qF 'difficulty="$(issue_difficulty "${labels[$i]}" "$title" "$body")"' "$tick" || fail "tick must capture the difficulty once for the memory drop-in"
grep -qF 'echo "difficulty: $difficulty"' "$tick" || fail "tick must emit the difficulty header as the packet's first line"
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
# fleet-ops#4248: an explicit `difficulty:` marker in the issue body must reach
# the packet header. Nish's lever for the Cursor $400 senior pool is exactly
# this line; before the fix intake recomputed the header and the marker was
# silently dropped (observed 2026-09-07: 0509#1919 body line 1
# "difficulty: senior-review" -> packet first line "difficulty: light" ->
# ran on devin/swe-1-7 at weight=light).
[[ "$(issue_difficulty '["agent-ready"]' 'guard the offer timeline' 'difficulty: senior-review

- required: one thing')" == "senior-review" ]] || fail "an explicit difficulty: senior-review marker must win"
[[ "$(issue_difficulty '["agent-ready"]' 'x' 'senior-review: true
- required: one thing')" == "senior-review" ]] || fail "the senior-review: true boolean form must win"
[[ "$(issue_difficulty '["agent-ready"]' 'x' 'keystone: true
- required: one thing')" == "keystone" ]] || fail "the keystone: true boolean form must win"
[[ "$(issue_difficulty '["agent-ready"]' 'x' "difficulty: light
$(for i in 1 2 3 4; do echo "- required: thing $i"; done)")" == "light" ]] || fail "an explicit marker must beat the size heuristic"
[[ "$(issue_difficulty '["agent-ready","heavy"]' 'x' 'difficulty: light
short')" == "heavy" ]] || fail "a curated heavy LABEL must not be downgraded by a body marker"
[[ "$(issue_difficulty '["agent-ready","keystone"]' 'x' 'difficulty: light
short')" == "keystone" ]] || fail "a curated keystone LABEL must not be downgraded by a body marker"
[[ "$(issue_difficulty '["agent-ready"]' 'x' 'difficulty: bogus
- required: one thing')" == "light" ]] || fail "an unknown marker value must fall through to the heuristic"
[[ "$(issue_difficulty '["agent-ready"]' 'x' 'we set difficulty: senior-review last week
- required: one thing')" == "light" ]] || fail "a difficulty word mid-sentence must NOT route as a marker"
ok "Test 2b: explicit body marker is honoured, labels still win, typos fall through"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
head -c 30000 /dev/zero | tr '\0' 'a' > "$scratch/worker.md"; { cat "$scratch/worker.md"; echo; echo "TARGET: repo Nishfleet/fleet-ops issue 1 unit pi-issue-fleet-ops-1"; } > "$scratch/p.in"
w=$(bash -c 'source "$0"; PI_PACKET_BASE_PROMPT="$1" task_weight "$2"' "$lib" "$scratch/worker.md" "$scratch/p.in")
[[ "$w" == "light" ]] || fail "task_weight fallback must not count the base prompt bytes (got $w)"
ok "Test 3: seatlib fallback subtracts the base prompt"
echo "PASS: pi-intake-tick-difficulty-from-issue"
