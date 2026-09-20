#!/usr/bin/env bash
# fleet-ops#7902 / fleet-ops#366: prevention gate for the unescaped %s escape family.
# Asserts the systemd unit template contains exactly 2 `date +%%s` (escaped)
# and ZERO unescaped `date +%s` occurrences.
set -euo pipefail

SERVICE_FILE="systemd/pi-intake-repair@.service"

if [[ ! -f "$SERVICE_FILE" ]]; then
    echo "FAIL: $SERVICE_FILE not found" >&2
    exit 1
fi

# Count escaped occurrences (what we want)
escaped_count=$(grep -cF 'date +%%s' "$SERVICE_FILE" || true)
if [[ "$escaped_count" -ne 2 ]]; then
    echo "FAIL: expected exactly 2 'date +%%s' lines, found $escaped_count" >&2
    grep -nF 'date +%%s' "$SERVICE_FILE" >&2
    exit 1
fi

# Count unescaped occurrences (what we forbid)
unescaped_lines=$(grep -nF 'date +%s' "$SERVICE_FILE" || true)
unescaped_count=$(echo "$unescaped_lines" | grep -c '.' || true)
if [[ -n "$unescaped_lines" && "$unescaped_count" -gt 0 ]]; then
    echo "FAIL: found $unescaped_count unescaped 'date +%s' occurrence(s):" >&2
    echo "$unescaped_lines" >&2
    exit 1
fi

echo "OK: $escaped_count escaped 'date +%%s' line(s), 0 unescaped 'date +%s'"
exit 0