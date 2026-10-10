#!/usr/bin/env bash
# Seat for a Claude Code worker or judge lane. A thin wrapper over
# scripts/pick-claude-seat.sh (which owns the two-hour bucket, the usage read and
# the 95% skip); it adds one answer that script does not give.
#
# stdout: `keep` or `default` (as pick-claude-seat.sh: leave CLAUDE_CONFIG_DIR
# alone, or unset it), or `full` when the chosen seat is still at or over
# CLAUDE_SEAT_SKIP_AT (default 95) percent of its five-hour limit. pick-claude-seat.sh
# keeps the bucket seat when both seats are full; this wrapper reads the usage it
# logs and turns that case into `full`, so the caller falls back to another
# engine instead of starting a run that will hit the wall. An unreadable usage
# is not full: the picked seat is used.
#
# The threshold is CLAUDE_SEAT_SKIP_AT, one rule for every caller: strong-only
# (senior) work and the reviews leave it at 95, the Gate's fill mode sets it to
# CLAUDE_FILL_BELOW (default 80). A seat over the fill threshold therefore gets no
# new fill jobs but still takes strong-only jobs up to 95.
#
# With --usage the one line is `<keep|default|full> <a|b> <five_hour|n/a>`, for
# the Gate's log line and for fill mode, which needs the number (it does not
# fill on an unreadable usage).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
skip_at=${CLAUDE_SEAT_SKIP_AT:-95}
err=$(mktemp)
trap 'rm -f "$err"' EXIT

mode=$("$here/pick-claude-seat.sh" 2>"$err") || mode=keep
cat "$err" >&2
seat=$(sed -n 's/^claude seat: .* seat=\([ab]\) .*$/\1/p' "$err" | tail -n 1)
used=$(sed -n 's/^claude seat: .* five_hour=\([0-9][0-9.]*\)$/\1/p' "$err" | tail -n 1)
if [ -n "$used" ] && jq -en --argjson n "$used" --argjson t "$skip_at" '$n >= $t' >/dev/null 2>&1; then
  mode=full
fi
if [ "${1:-}" = --usage ]; then
  echo "$mode ${seat:-?} ${used:-n/a}"
else
  echo "$mode"
fi
