#!/usr/bin/env bash
# Drive the reusable-auto-merge-arm freeze gate. Loaded by the
# follow-up PR once it lands (the worker App cannot ship it; see
# #1457 follow-up).
set -euo pipefail
if gh issue list --repo "${{ github.repository }}" \\
      --state open --limit 100 \\
      --search "stop-the-line: in:title frozen in:title" \\
      --json number --jq length 2>/dev/null | grep -qE "^([1-9][0-9]*)$"; then
  echo "frozen=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "frozen=false" >> "$GITHUB_OUTPUT"
