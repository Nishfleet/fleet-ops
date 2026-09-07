#!/usr/bin/env bash
# tests/scout-prompt-difficulty.test.sh
#
# Proves the scout and scout-repair prompts classify as `light` difficulty
# via the real lib/seat-lib.sh packet_difficulty(), so pi-scout-run sets
# need_capable=0 and pick_seat may use healthy commodity lanes (ollama, bai,
# cline, hetzner, opencode free lanes) instead of being locked to the small
# "capable" set (devin, xai-oauth, minimax, straitly, cursor) that is
# frequently full or walled.
#
# Root cause this locks (fleet-ops#3072): the crude task_weight() heuristic
# false-positives on scout/scout-repair prompt BOILERPLATE (e.g. "do not
# file a fix-shaped issue", "fix what you safely can") and returns "heavy",
# forcing need_capable=1. With every capable seat at-capacity or walled,
# pick_seat returned NO USABLE SEAT and the scout + scout-repair units
# exited non-zero on both lanes for 18h. The prompts do NOT edit code
# (scout.md: "never edit repo code"; scout-repair.md: "NEVER weaken the
# unit"), so an explicit `difficulty: light` manifest line overrides the
# heuristic (fleet-ops#1133/#1383). This test fails if the marker is
# removed or packet_difficulty regresses.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Sources the real seat-lib.sh but only exercises
# packet_difficulty (no seat-caps/models/ledger reads).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"

scout_prompt="$repo_root/prompts/scout.md"
repair_prompt="$repo_root/prompts/scout-repair.md"
[[ -f "$scout_prompt" ]]  || fail "missing $scout_prompt"
[[ -f "$repair_prompt" ]] || fail "missing $repair_prompt"

# packet_difficulty is a pure function over the prompt file; sourcing the
# lib does not require seat-caps/models to be present for this path.
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$scout_prompt")
[[ "$got" == "light" ]] \
  || fail "scout.md must classify as light (got: $got); without the difficulty: light marker the task_weight heuristic false-positives on prompt boilerplate and pi-scout-run sets need_capable=1, locking the scout out of every healthy commodity lane (fleet-ops#3072)"
ok "scout.md classifies as light (difficulty: light marker overrides task_weight false-positive)"

got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$repair_prompt")
[[ "$got" == "light" ]] \
  || fail "scout-repair.md must classify as light (got: $got); without the difficulty: light marker the task_weight heuristic false-positives on prompt boilerplate and pi-scout-repair-run sets need_capable=1, so the repair unit cannot even spawn to diagnose a walled scout tick (fleet-ops#3072)"
ok "scout-repair.md classifies as light (difficulty: light marker overrides task_weight false-positive)"

# Guard the marker itself: the line must be present verbatim so a future
# edit that drops it (or reformats it into prose) is caught here, not in
# production when the scout units next fail.
grep -qE '^difficulty:[[:space:]]*light[[:space:]]*$' "$scout_prompt" \
  || fail "scout.md must carry a literal 'difficulty: light' manifest line"
grep -qE '^difficulty:[[:space:]]*light[[:space:]]*$' "$repair_prompt" \
  || fail "scout-repair.md must carry a literal 'difficulty: light' manifest line"
ok "both prompts carry the literal difficulty: light manifest line"

echo "scout-prompt-difficulty: all checks passed"
