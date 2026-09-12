#!/usr/bin/env bash
# fleet-ops#4220 on the proxy (fleet-ops#4263): a senior-review packet routes to
# the LiteLLM senior group. The cursor/xai-oauth seat ladder this file used to
# drive was the deleted picker; the proxy senior group owns fallback now.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
lib="$repo_root/lib/litellm-seat.sh"
got=$(GITHUB_ACTIONS=true bash -uc 'source "$0" >/dev/null 2>&1; find_senior_seat' "$lib") \
  || fail "find_senior_seat must succeed under set -u in CI"
[[ "$got" == "$(printf 'litellm\tsenior')" ]] || fail "find_senior_seat must return litellm<TAB>senior, got '$got'"
ok "senior-review routes to the LiteLLM senior group (no unbound crash under set -u)"
