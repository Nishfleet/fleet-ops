#!/usr/bin/env bash
# tests/deliberate-states-registry.test.sh
#
# fleet-ops#2771: docs/deliberate-states.md must never carry an expired
# deliberate state. The mechanical blind audit (prompts/blind-audit.md,
# "Deliberate-states rule") treats a row whose expiry has passed as a loud
# gap-audit finding and auto-files a spurious issue. The `fleet-paused` row
# lingered with `expiry: 2026-09-02` long after the 2026-08-25/26 fleet
# restoration (fleet-ops#180); the row was factually false and its expiry
# passing would have fired a false gap-audit. This test is the
# class-prevention mechanism (fleet-ops#366): it runs on every PR (hosted
# from the listed tests/fleet-blind-audit.test.sh) and fails as soon as any
# row's expiry has arrived without an explicit `closed` marker, so a stale
# registry row can never survive to trip the blind audit again.
#
# What we prove:
#   1. The registry table parses (state | reason | expiry | owner), using
#      the same rules as the parser inside bin/fleet-blind-audit.
#   2. No row has an expiry that has already arrived (expiry <= today)
#      unless the row carries an explicit `closed` marker.
#   3. The `fleet-paused` row does not exist (or is explicitly closed) —
#      the fleet has been live since the 2026-08-25/26 restoration.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
doc="$repo_root/docs/deliberate-states.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$doc" ]] || fail "missing $doc"

today="$(date -u +%Y-%m-%d)"

# Parse the registry exactly as bin/fleet-blind-audit does: rows under the
# `| state | reason | expiry | owner |` header, skipping the separator line
# and any text that is not a real row. A row is stored as pipe-joined cells
# (cells cannot contain `|` because the table splits on it).
in_table=0
header_seen=0
rows=()
while IFS= read -r ln || [[ -n "$ln" ]]; do
  lower="${ln,,}"
  if [[ $in_table == 0 ]]; then
    if [[ "$lower" =~ ^[[:space:]]*\|?[[:space:]]*state[[:space:]]*\| ]]; then
      in_table=1
      header_seen=1
    fi
    continue
  fi
  # Strip leading/trailing pipes, split cells, drop empties.
  cells=()
  IFS='|' read -ra parts <<< "$ln"
  for c in "${parts[@]}"; do
    c="${c#"${c%%[![:space:]]*}"}"
    c="${c%"${c##*[![:space:]]}"}"
    if [[ -n "$c" ]]; then cells+=("$c"); fi
  done
  (( ${#cells[@]} >= 1 )) || continue
  # Separator row: every cell is dashes/colons.
  sep=1
  for c in "${cells[@]}"; do
    [[ "$c" =~ ^[-:]+$ ]] || { sep=0; break; }
  done
  (( sep == 0 )) || continue
  # A real row has >= 4 columns and does not repeat the header names.
  (( ${#cells[@]} >= 4 )) || continue
  [[ "${cells[0],,}" != "state" ]] || continue
  rows+=("${cells[0]}|${cells[1]}|${cells[2]}|${cells[3]}")
done < "$doc"

[[ $header_seen == 1 ]] || fail "no registry table header (\`| state | reason | expiry | owner |\`) found in $doc"

stale=()
for row in "${rows[@]}"; do
  IFS='|' read -ra cells <<< "$row"
  state="${cells[0]}"
  expiry="${cells[2]}"
  closed=0
  [[ "${row,,}" == *closed* ]] && closed=1

  # 3. fleet-paused must not survive as an active row (fleet is live,
  #    fleet-ops#180 restoration 2026-08-25/26).
  if [[ "$state" == "fleet-paused" ]] && [[ $closed == 0 ]]; then
    stale+=("fleet-paused: row exists and is not marked closed: $row")
  fi

  # 2. An expiry that has arrived (<= today) without a closed marker is a
  #    spurious gap-audit waiting to fire.
  if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if [[ "$expiry" < "$today" || "$expiry" == "$today" ]] && [[ $closed == 0 ]]; then
      stale+=("$state: expiry $expiry has already arrived (today $today) without a closed marker")
    fi
  else
    stale+=("$state: expiry '$expiry' is not an ISO-8601 YYYY-MM-DD date")
  fi
done

# Whole-file guard: any fleet-paused mention outside a closed row is stale.
if grep -qi 'fleet-paused' "$doc"; then
  closed_fp=0
  for row in "${rows[@]}"; do
    if [[ "${row,,}" == *closed* ]] && [[ "${row%%|*}" == "fleet-paused" ]]; then
      closed_fp=1
    fi
  done
  if (( closed_fp != 1 )); then
    stale+=("docs/deliberate-states.md must not mention fleet-paused (fleet is live since the 2026-08-25/26 restoration, fleet-ops#180) unless the row is marked closed")
  fi
fi

if (( ${#stale[@]} > 0 )); then
  for s in "${stale[@]}"; do
    echo "  - $s" >&2
  done
  fail "deliberate-states registry has ${#stale[@]} stale row(s); fix docs/deliberate-states.md or mark rows closed"
fi

ok "no deliberate-state row with passed expiry (or a stale fleet-paused row)"
echo
echo "deliberate-states-registry test: OK"