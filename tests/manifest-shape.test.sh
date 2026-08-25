#!/usr/bin/env bash
# tests/manifest-shape.test.sh
#
# Proves the GitHub App manifest for nishfleet-worker is shape-correct.
# Runs in CI without the app existing on GitHub — purely a shape check.
#
# Invariants:
#   1. JSON is valid (jq parses it).
#   2. App name == 'nishfleet-worker'.
#   3. Permissions are exactly {contents:write, pull_requests:write,
#      issues:write, metadata:read} and nothing else.
#   4. No webhook: hook_attributes.url is empty, hook_attributes.active
#      is false, hook_attributes.events is [].
#   5. default_events is []. events is []. No webhook events are exposed
#      regardless of GitHub settings.
#   6. callback_url is a 127.0.0.1 URL (the local bootstrap listener).
#   7. request_oauth_on_install == false.
#
# Lock-and-leave. If any invariant fails, the test exits 1 and CI fails.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/credentials/app-manifest.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$manifest" ]] || fail "manifest not found: $manifest"

jq '.' "$manifest" >/dev/null || fail "manifest is not valid JSON"

[[ "$(jq -r '.name' "$manifest")" == "nishfleet-worker" ]] \
  || fail "app name must be 'nishfleet-worker'"

# Compare as deep equality (jq's == handles objects). String-compare breaks
# because jq re-sorts keys; deep-equal does not.
expected='{"contents":"write","pull_requests":"write","issues":"write","metadata":"read"}'
jq -e --argjson e "$expected" '.permissions == $e' "$manifest" >/dev/null \
  || fail "permissions object mismatch: got $(jq -c .permissions "$manifest")"
for k in contents pull_requests issues metadata; do
  v="$(jq -r --arg k "$k" '.permissions[$k]' "$manifest")"
  case "$k" in
    metadata) [[ "$v" == "read"  ]] || fail "metadata must be 'read', got '$v'";;
    *)        [[ "$v" == "write" ]] || fail "$k must be 'write', got '$v'";;
  esac
done
# Defence-in-depth: 4 keys exactly, no wildcard future keys.
count="$(jq '.permissions | keys | length' "$manifest")"
[[ "$count" == "4" ]] || fail "expected exactly 4 permissions, got $count (full: $(jq -c '.permissions' "$manifest"))"

# Webhook OFF in every place it could be set.
[[ "$(jq -r '.hook_attributes.url'   "$manifest")" == "" ]] || fail "hook_attributes.url must be empty"
[[ "$(jq -r '.hook_attributes.active' "$manifest")" == "false" ]] || fail "hook_attributes.active must be false"
hook_ev="$(jq -c '.hook_attributes.events' "$manifest")"
[[ "$hook_ev" == "[]" ]] || fail "hook_attributes.events must be [] (got $hook_ev)"

def_evs="$(jq -c '.default_events' "$manifest")"
[[ "$def_evs" == "[]" ]] || fail "default_events must be [] (got $def_evs)"

evs="$(jq -c '.events' "$manifest")"
[[ "$evs" == "[]" ]] || fail "events must be [] (got $evs)"

cb="$(jq -r '.default_callback_url' "$manifest")"
[[ "$cb" =~ ^https?://127\.0\.0\.1(:[0-9]+)?/callback$ ]] \
  || fail "default_callback_url must point at the local bootstrap listener, got '$cb'"

[[ "$(jq -r '.request_oauth_on_install' "$manifest")" == "false" ]] \
  || fail "request_oauth_on_install must be false"

[[ "$(jq -r '.public' "$manifest")" == "false" ]] || fail "public must be false"

echo "OK: app-manifest.json shape is locked (nishfleet-worker, 4 perms, no webhooks, callback=127.0.0.1)"
