#!/usr/bin/env bash
# tests/legal-basics-surfaces.test.sh
#
# Locks the shape of config/legal-basics-surfaces.json — the declared set of
# live public product surfaces that must expose privacy, terms, and a
# reachable contact path (fleet-ops#1233).
#
# Same form as tests/intake-repos-shape.test.sh (bash + jq against a repo
# JSON file). Not a live HTTP check. Dated evidence:
# reports/legal-basics-sweep-2026-08-27.md.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
file="$repo_root/config/legal-basics-surfaces.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$file" ]] || fail "legal-basics-surfaces.json not found: $file"

jq '.' "$file" >/dev/null || fail "legal-basics-surfaces.json is not valid JSON"

count="$(jq '.surfaces | length' "$file")"
[[ "$count" -gt 0 ]] || fail "surfaces must be non-empty"

ids="$(jq -r '.surfaces[].id' "$file")"
while IFS= read -r id; do
  [[ -n "$id" ]] || fail "every surface must have a non-empty id"
done <<< "$ids"

dupes="$(printf '%s\n' "$ids" | LC_ALL=C sort | uniq -d)"
[[ -z "$dupes" ]] || fail "duplicate surface ids: $dupes"

sorted="$(printf '%s\n' "$ids" | LC_ALL=C sort)"
[[ "$(printf '%s\n' "$ids")" == "$(printf '%s\n' "$sorted")" ]] \
  || fail "surfaces must be sorted ascending by id (LC_ALL=C byte order)"

idx=0
while [[ "$idx" -lt "$count" ]]; do
  for key in id repo origin privacy_path terms_path contact stores_user_data; do
    jq -e --argjson i "$idx" --arg k "$key" '.surfaces[$i] | has($k)' "$file" >/dev/null \
      || fail "surfaces[$idx] missing $key"
  done
  origin="$(jq -r --argjson i "$idx" '.surfaces[$i].origin' "$file")"
  [[ "$origin" =~ ^https://[A-Za-z0-9.-]+$ ]] \
    || fail "surfaces[$idx].origin must be https://host with no path, got '$origin'"
  for key in privacy_path terms_path; do
    path="$(jq -r --argjson i "$idx" --arg k "$key" '.surfaces[$i][$k]' "$file")"
    [[ "$path" == /* ]] || fail "surfaces[$idx].$key must start with /, got '$path'"
  done
  kind="$(jq -r --argjson i "$idx" '.surfaces[$i].contact.kind' "$file")"
  [[ "$kind" == "mailto" || "$kind" == "page" ]] \
    || fail "surfaces[$idx].contact.kind must be mailto or page, got '$kind'"
  value="$(jq -r --argjson i "$idx" '.surfaces[$i].contact.value' "$file")"
  [[ -n "$value" ]] || fail "surfaces[$idx].contact.value must be non-empty"
  flag="$(jq -r --argjson i "$idx" '.surfaces[$i].stores_user_data' "$file")"
  [[ "$flag" == "true" || "$flag" == "false" ]] \
    || fail "surfaces[$idx].stores_user_data must be a boolean, got '$flag'"
  idx=$((idx + 1))
done

for need in 0509 aiconverter inish siterep tinystudio-io; do
  printf '%s\n' "$ids" | grep -qx "$need" \
    || fail "issue #1233 named product missing from surfaces: $need"
done

echo "OK: legal-basics-surfaces.json shape locked ($count surfaces)"
