#!/usr/bin/env bash
# tests/manifest-shape.test.sh
#
# Proves the GitHub App manifest for nishfleet-worker is shape-correct.
# Runs in CI without the app existing on GitHub — purely a shape check.
#
# Invariants (GitHub App manifest schema as of 2026 — fleet-ops#409):
#   1. JSON is valid (jq parses it).
#   2. App name == 'nishfleet-worker'.
#   3. default_permissions are exactly {contents:write, pull_requests:write,
#      issues:write, metadata:read} and nothing else.
#   4. No webhook: hook_attributes is omitted (GitHub rejects an empty
#      hook block; webhook-off means the key is absent).
#   5. default_events is []. Top-level events is absent (pre-2026 name).
#   6. callback_urls is an array whose only entry is the local listener.
#   7. redirect_url is that same callback (GitHub sends the one-time
#      conversion code here — not the org homepage).
#   8. Stale keys are absent: default_callback_url, permissions, events.
#   9. request_oauth_on_install == false.
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
jq -e --argjson e "$expected" '.default_permissions == $e' "$manifest" >/dev/null \
  || fail "default_permissions object mismatch: got $(jq -c .default_permissions "$manifest")"
for k in contents pull_requests issues metadata; do
  v="$(jq -r --arg k "$k" '.default_permissions[$k]' "$manifest")"
  case "$k" in
    metadata) [[ "$v" == "read"  ]] || fail "metadata must be 'read', got '$v'";;
    *)        [[ "$v" == "write" ]] || fail "$k must be 'write', got '$v'";;
  esac
done
# Defence-in-depth: 4 keys exactly, no wildcard future keys.
count="$(jq '.default_permissions | keys | length' "$manifest")"
[[ "$count" == "4" ]] || fail "expected exactly 4 default_permissions, got $count (full: $(jq -c '.default_permissions' "$manifest"))"

# Webhook OFF: omit the hook block entirely. GitHub rejects hook_attributes
# with an empty url, and rejects events nested inside it.
jq -e 'has("hook_attributes") | not' "$manifest" >/dev/null \
  || fail "hook_attributes must be omitted when webhook is off"

def_evs="$(jq -c '.default_events' "$manifest")"
[[ "$def_evs" == "[]" ]] || fail "default_events must be [] (got $def_evs)"

for stale in default_callback_url permissions events; do
  jq -e --arg k "$stale" 'has($k) | not' "$manifest" >/dev/null \
    || fail "stale pre-2026 key must be absent: $stale"
done

cb="$(jq -r '.callback_urls[0]' "$manifest")"
[[ "$cb" =~ ^https?://127\.0\.0\.1(:[0-9]+)?/callback$ ]] \
  || fail "callback_urls[0] must point at the local bootstrap listener, got '$cb'"
n_cb="$(jq '.callback_urls | length' "$manifest")"
[[ "$n_cb" == "1" ]] || fail "callback_urls must have exactly 1 entry, got $n_cb"

redir="$(jq -r '.redirect_url' "$manifest")"
[[ "$redir" == "$cb" ]] \
  || fail "redirect_url must be the callback endpoint (GitHub sends the one-time code here), got '$redir'"

[[ "$(jq -r '.request_oauth_on_install' "$manifest")" == "false" ]] \
  || fail "request_oauth_on_install must be false"

[[ "$(jq -r '.public' "$manifest")" == "false" ]] || fail "public must be false"

echo "OK: app-manifest.json shape is locked (nishfleet-worker, 4 perms, no webhooks, redirect=callback)"

# fleet-ops#409: handshake lock (exchange logging, empty POST, --serve).
# Invoked from here so CI runs it without a workflow-file edit (the
# nishfleet-worker app cannot push .github/workflows/**).
bash "$here/worker-app-bootstrap.test.sh"
