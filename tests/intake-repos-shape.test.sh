#!/usr/bin/env bash
# tests/intake-repos-shape.test.sh
#
# Locks the shape and invariants of config/intake-repos.json — the declared
# set of repos enrolled in pi-intake/pi-scout (fleet-ops#25 coverage decision,
# consumed by the fleet-ops#32 reconciler).
#
# This is a SHAPE lock, not a live precondition check. It runs in CI on a
# hosted runner with no VPS checkouts and no gh access to private repos, so it
# cannot verify labels or checkouts exist. The live precondition check is the
# reconciler's job (#32). What this test guards:
#
#   1. JSON is valid (jq parses it).
#   2. checkout_root is the path intake/worker assume (/home/nish/workspaces/products).
#   3. required_labels is exactly the three labels the pi-intake@.service
#      ExecCondition silently no-ops without — agent-ready, agent-in-progress,
#      agent-blocked — in that order.
#   4. repos is a non-empty array of objects each with a non-empty `name`.
#   5. No duplicate repo names within `repos`.
#   6. `repos` is sorted ascending by name (deterministic — reconciler diffs
#      must be stable).
#   7. No repo in `repos` also appears in `excluded` (contradiction).
#   8. fleet2 is NEVER in `repos` — permanent standing-rule guard. Adding it
#      back is the one enrolment decision that must fail closed even before a
#      human reviews it.
#   9. Each `excluded` entry has a non-empty `reason` and `permanent` is a bool.
#
# Lock-and-leave. If any invariant fails, the test exits 1 and CI fails.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
file="$repo_root/config/intake-repos.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$file" ]] || fail "intake-repos.json not found: $file"

jq '.' "$file" >/dev/null || fail "intake-repos.json is not valid JSON"

# 2. checkout_root
[[ "$(jq -r '.checkout_root' "$file")" == "/home/nish/workspaces/products" ]] \
  || fail "checkout_root must be /home/nish/workspaces/products, got $(jq -r '.checkout_root' "$file")"

# 3. required_labels — exactly the three, in order.
expected_labels='["agent-ready","agent-in-progress","agent-blocked"]'
got_labels="$(jq -c '.required_labels' "$file")"
[[ "$got_labels" == "$expected_labels" ]] \
  || fail "required_labels must be $expected_labels, got $got_labels"

# 4. repos is a non-empty array of {name: non-empty string}.
repo_count="$(jq '.repos | length' "$file")"
[[ "$repo_count" -gt 0 ]] || fail "repos must be non-empty"
names="$(jq -r '.repos[].name' "$file")"
while IFS= read -r n; do
  [[ -n "$n" ]] || fail "every repo entry must have a non-empty name"
done <<< "$names"

# 5. no duplicates within repos.
dupes="$(printf '%s\n' "$names" | LC_ALL=C sort | uniq -d)"
[[ -z "$dupes" ]] || fail "duplicate repo names in repos: $dupes"

# 6. repos sorted ascending by name (LC_ALL=C — byte order, deterministic
#    regardless of host locale; the reconciler's diffs must be stable).
sorted="$(printf '%s\n' "$names" | LC_ALL=C sort)"
[[ "$(printf '%s\n' "$names")" == "$(printf '%s\n' "$sorted")" ]] \
  || fail "repos must be sorted ascending by name (LC_ALL=C byte order)"

# 7. no repo in both repos and excluded.
excluded_names="$(jq -r '.excluded[].name' "$file")"
overlap="$(printf '%s\n%s\n' "$names" "$excluded_names" | LC_ALL=C sort | uniq -d)"
[[ -z "$overlap" ]] || fail "repo appears in both repos and excluded: $overlap"

# 8. fleet2 is never in repos (permanent standing-rule guard).
if printf '%s\n' "$names" | grep -qx 'fleet2'; then
  fail "fleet2 must never be enrolled (standing rule: no second dispatcher, ever)"
fi

# 9. every excluded entry has a non-empty reason and boolean permanent.
excl_count="$(jq '.excluded | length' "$file")"
[[ "$excl_count" -gt 0 ]] || fail "excluded must be non-empty (fleet2 guard lives here)"
for i in $(seq 0 $((excl_count - 1))); do
  reason="$(jq -r --argjson i "$i" '.excluded[$i].reason' "$file")"
  [[ -n "$reason" ]] || fail "excluded[$i] must have a non-empty reason"
  perm="$(jq -r --argjson i "$i" '.excluded[$i].permanent' "$file")"
  [[ "$perm" == "true" || "$perm" == "false" ]] \
    || fail "excluded[$i].permanent must be a boolean, got '$perm'"
  ename="$(jq -r --argjson i "$i" '.excluded[$i].name' "$file")"
  [[ -n "$ename" ]] || fail "excluded[$i] must have a non-empty name"
done

# fleet2 specifically must be present in excluded with permanent=true, so the
# standing-rule guard is explicit in the file itself, not just the test.
fleet2_excluded="$(jq -r '[.excluded[] | select(.name=="fleet2" and .permanent==true)] | length' "$file")"
[[ "$fleet2_excluded" == "1" ]] \
  || fail "fleet2 must be listed in excluded with permanent=true (standing rule)"

echo "OK: intake-repos.json shape locked ($repo_count repos, $excl_count excluded, fleet2 guard live)"

# fleet-ops#29: the agent-blocked label is a live queue, not a parking lot.
# CI's tests job does not yet have a named step for tests/blocked-reconcile.test.sh
# (workflow files are out of band for the worker App). Run them here so a
# regression cannot merge green.
bash "$here/blocked-reconcile.test.sh"
# fleet-ops#39: claim-reconcile self-heals split-brain and garbage claim
# branches. A named tests/claim-reconcile.test.sh step in ci.yml is out of
# band for the worker App (Contents cannot push workflow files). Run it
# here so a regression cannot merge green.
bash "$here/claim-reconcile.test.sh"
# fleet-ops#32 / #129: same pattern for the declared-set reconciler — the
# intake-repos.json shape is meaningless without bin/intake-reconcile, so
# gate on both. The P14 tests job runs this file; a named
# tests/intake-reconcile.test.sh step in .github/workflows/ci.yml is out
# of band for the worker App (Contents cannot push workflow files).
# Workers implementing these issues must NEVER touch the live user
# manager; the test runs entirely against stubbed systemctl + gh.
bash "$here/intake-reconcile.test.sh"
