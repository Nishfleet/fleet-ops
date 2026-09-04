#!/usr/bin/env bash
# tests/worker-prompt-size-ceiling.test.sh
#
# fleet-ops#1902: pi-issue-run empty runs (stdout=0B) were benching healthy
# seats 18x/2h. Root cause: the worker prompt (prompts/worker.md) had bloated
# to ~45 KB with a single 22 KB line — the failed-command shape enumeration
# that is redundant with the 20+ tests/fleet-failed-command-*.test.sh files
# and the bin/fleet-failed-command-flagged session-close lint. Free-tier seats
# with limited context windows returned empty completions (exit 0, stdout=0B,
# tools=0) on the oversized packet, and pi-issue-run benched the seat for a
# transient provider hiccup instead of a real seat fault.
#
# This test is the fleet-ops#366 mechanism: it mechanically prevents the
# re-bloat class by asserting the assembled worker packet stays under a size
# ceiling AND that no single line exceeds a per-line cap. A future prompt
# edit that re-bloats the enumeration (or any other line) is caught here
# before it ships and re-introduces the empty-run class.
#
# The ceiling is generous: 32 KB for the whole packet (the trimmed prompt is
# ~25 KB, the bloated one was ~45 KB) and 4 KB per line (the trimmed
# failed-command line is ~1.8 KB, the bloated one was ~22 KB). Both leave
# headroom for legitimate growth while catching the bloat shape.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "worker prompt not found at $worker"

# --- 1. Packet size ceiling (as intake assembles it: worker.md + TARGET) ------
PACKET_CEILING=32768
packet_size=$( { cat "$worker"; echo; echo "TARGET: repo Nishfleet/fleet-ops issue 1902 unit pi-issue-fleet-ops-1902"; } | wc -c )
if [[ "$packet_size" -gt "$PACKET_CEILING" ]]; then
	fail "worker packet is ${packet_size}B, exceeds ${PACKET_CEILING}B ceiling — prompt bloat re-introduced the fleet-ops#1902 empty-run class. Trim the enumeration (the tests/fleet-failed-command-*.test.sh files + bin/fleet-failed-command-flagged lint are the authoritative shape list)."
fi
ok "worker packet is ${packet_size}B, under ${PACKET_CEILING}B ceiling"

# --- 2. Per-line cap: no single line exceeds 4 KB ----------------------------
# The 22 KB single-line enumeration was the specific bloat shape. A per-line
# cap catches it even if total size stays under the packet ceiling.
LINE_CAP=4096
longest=$(awk '{ if (length > m) m = length } END { print m+0 }' "$worker")
if [[ "$longest" -gt "$LINE_CAP" ]]; then
	fail "longest worker.md line is ${longest}B, exceeds ${LINE_CAP}B per-line cap — a single-line enumeration bloat re-introduced the fleet-ops#1902 empty-run class. Break the line or move the enumeration to a test file."
fi
ok "longest worker.md line is ${longest}B, under ${LINE_CAP}B per-line cap"

# --- 3. Core failed-command rule preserved -----------------------------------
# The trim must keep the core instruction (flag failed commands in user-facing
# text) and the no-match-probe exception. Dropping the rule would be a
# regression worse than the bloat.
grep -q 'failed command' "$worker" || fail "core 'failed command' rule missing from worker.md"
grep -q 'no-match probe' "$worker" || fail "no-match-probe exception missing from worker.md"
grep -q 'fleet-failed-command-flagged' "$worker" || fail "pointer to the session-close lint missing from worker.md"
ok "core failed-command rule, no-match-probe exception, and lint pointer all present"

# --- 4. Line-count ceiling (fleet-ops#3245 / #3120) --------------------------
# The 2026-09-04 trim lands worker.md at <=80 lines. Re-bloat past that is
# the class this issue prevents: every packet carried 261 lines / 32 KB of
# rules before the issue. The 32 KB / 4 KB caps above stay as the loose
# backstop; this is the tight line-count guard.
LINE_CEILING=80
line_count=$(wc -l < "$worker")
if [[ "$line_count" -gt "$LINE_CEILING" ]]; then
	fail "worker.md is ${line_count} lines, exceeds ${LINE_CEILING}-line ceiling (fleet-ops#3245). Trim; do not re-bloat the packet."
fi
ok "worker.md is ${line_count} lines, under ${LINE_CEILING}-line ceiling"

# --- 5. The two lines folded from #3249 -------------------------------------
# (1) todo list + 10-minute stop. (2) the bar is 'extremely well', never 'perfect'.
grep -q "if no item has been completed in 10 minutes" "$worker" \
	|| fail "worker.md must keep the 10-minute stop (fleet-ops#3249 folded into #3245)"
grep -q "extremely well" "$worker" \
	|| fail "worker.md must keep the 'extremely well' bar (fleet-ops#3249 folded into #3245)"
ok "todo 10-minute stop and 'extremely well' bar both present"

echo "worker-prompt-size-ceiling: PASS"
