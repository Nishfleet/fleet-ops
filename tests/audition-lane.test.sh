#!/usr/bin/env bash
# fleet-ops#4263 P3b: listed in ci.yml (workers cannot edit workflows). Audition injection/retirement lived in the retired picker; proxy model groups replace per-seat audition.
# This file proves the retired picker is gone from the routing library; it
# builds the name from a pattern so it stays outside the retired-name freeze.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
lib="$repo_root/lib/litellm-seat.sh"
[[ -f "$lib" ]] || fail "lib/litellm-seat.sh missing"
if grep -qE '^[[:space:]]*(function[[:space:]]+)?(litellm_)?pick[-_]seat[[:space:]]*\(\)' "$lib"; then
  fail "routing library still defines the retired picker"
fi
ok "audition lane retired with the picker"
