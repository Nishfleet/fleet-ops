#!/usr/bin/env bash
# tests/fleet-repo-visibility-canary.test.sh
#
# Proves the repo-visibility canary (fleet-ops#542) offline:
#   1. Clean: public products + allowlisted private sinks + archived private
#      -> OK, no file.
#   2. Undeclared private product repo -> exit 1, LOUD, auto-files.
#   3. Allowlisted private sink stays green.
#   4. Archived private repo not on the allowlist is skipped.
#   5. Dedup: open issue already carrying the marker -> no second create.
#   6. gh missing and no fixture -> exit 1 (watcher broken).
#   7. Missing / malformed allowlist -> exit 1.
#   8. Live gh path passes --limit (gh default 30 would hide repos).
#   9. Production allowlist names 0509-telemetry and the live private set.
#  10. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-repo-visibility-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
allow="$repo_root/config/repo-visibility.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$allow" ]] || fail "missing: $allow"

scratch="$(mktemp -d -t repo-visibility-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_REPO_VISIBILITY_REPO="Nishfleet/fleet-ops"
export FLEET_REPO_VISIBILITY_FILE=1

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"repo list"*)
    if [[ -f "${GH_REPO_LIST:-/dev/null}" ]]; then
      cat "${GH_REPO_LIST}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

write_allow() { cat >"$scratch/allow.json"; }
write_list()  { cat >"$scratch/list.json"; }

base_allow() {
  write_allow <<'JSON'
{
  "org": "Nishfleet",
  "limit": 1000,
  "allow_private": [
    {"name": "0509-telemetry", "reason": "telemetry sink"},
    {"name": "fleet2", "reason": "not a product"},
    {"name": "egress-probe", "reason": "utility"}
  ]
}
JSON
}

base_list() {
  write_list <<'JSON'
[
  {"name": "0509", "isPrivate": false, "isArchived": false, "visibility": "PUBLIC"},
  {"name": "fleet-ops", "isPrivate": false, "isArchived": false, "visibility": "PUBLIC"},
  {"name": "0509-telemetry", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"},
  {"name": "fleet2", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"},
  {"name": "egress-probe", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"},
  {"name": "siterep", "isPrivate": true, "isArchived": true, "visibility": "PRIVATE"}
]
JSON
}

run_canary() {
  set +e
  env_out=$(
    FLEET_REPO_VISIBILITY_JSON="$scratch/allow.json" \
    FLEET_REPO_VISIBILITY_LIST="$scratch/list.json" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean --------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_allow; base_list
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'REPO-VISIBILITY-OK' <<<"$env_out" || fail "scenario1: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario1: clean org is green, no file"

# --- 2. undeclared private product -----------------------------------------
: >"$gh_log"; : >"$triage"
base_allow
write_list <<'JSON'
[
  {"name": "0509", "isPrivate": false, "isArchived": false, "visibility": "PUBLIC"},
  {"name": "new-product", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"}
]
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: undeclared private must exit 1, got rc=$env_rc ($env_out)"
grep -q 'REPO-VISIBILITY-VIOLATION' <<<"$env_out" || fail "scenario2: must LOUD ($env_out)"
grep -q 'new-product' <<<"$env_out" || fail "scenario2: must name the repo ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file (gh=$(cat "$gh_log"))"
ok "scenario2: undeclared private product fails loud and auto-files"

# --- 3. allowlisted private sink -------------------------------------------
: >"$gh_log"; : >"$triage"
base_allow
write_list <<'JSON'
[
  {"name": "0509-telemetry", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"}
]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: allowlisted sink must exit 0, got rc=$env_rc ($env_out)"
grep -q 'allow_private: 0509-telemetry' <<<"$env_out" || fail "scenario3: must log allow ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario3: must not file"
fi
ok "scenario3: allowlisted private sink is green"

# --- 4. archived private skipped -------------------------------------------
: >"$gh_log"; : >"$triage"
base_allow
write_list <<'JSON'
[
  {"name": "siterep", "isPrivate": true, "isArchived": true, "visibility": "PRIVATE"}
]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario4: archived private must exit 0, got rc=$env_rc ($env_out)"
grep -q 'skip archived: siterep' <<<"$env_out" || fail "scenario4: must skip archived ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario4: must not file archived"
fi
ok "scenario4: archived private repo is skipped"

# --- 5. dedup --------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_allow
write_list <<'JSON'
[
  {"name": "new-product", "isPrivate": true, "isArchived": false, "visibility": "PRIVATE"}
]
JSON
jq -n --arg b $'body\nfleet-repo-visibility-canary: private-product new-product\n' \
  '[{number: 77, body: $b}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: still a violation, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario5: must not create a second issue (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario5: must log dedup ($env_out)"
unset GH_OPEN_ISSUES
ok "scenario5: open marker is not filed twice"

# --- 6. broken watch (no gh, no fixture) -----------------------------------
: >"$gh_log"; : >"$triage"
base_allow
set +e
broken_out=$(
  FLEET_REPO_VISIBILITY_JSON="$scratch/allow.json" \
  FLEET_OPS_REPO="$scratch" \
  PATH="/usr/bin:/bin" \
  GH="$scratch/missing-gh" \
  "$bin" 2>&1
)
broken_rc=$?
set -e
[[ "$broken_rc" == "1" ]] || fail "scenario6: missing gh must exit 1, got rc=$broken_rc ($broken_out)"
grep -q 'WATCHER-BROKEN' <<<"$broken_out" || fail "scenario6: must LOUD watcher-broken ($broken_out)"
ok "scenario6: broken watch fails loud"

# --- 7. missing / malformed allowlist --------------------------------------
: >"$gh_log"; : >"$triage"
base_list
set +e
missing_out=$(
  FLEET_REPO_VISIBILITY_JSON="$scratch/no-such-allow.json" \
  FLEET_REPO_VISIBILITY_LIST="$scratch/list.json" \
  HOME="$scratch/empty-home" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
missing_rc=$?
set -e
[[ "$missing_rc" == "1" ]] || fail "scenario7a: missing allowlist must exit 1, got rc=$missing_rc ($missing_out)"
grep -q 'WATCHER-BROKEN' <<<"$missing_out" || fail "scenario7a: must LOUD ($missing_out)"

printf 'not-json\n' >"$scratch/bad.json"
set +e
bad_out=$(
  FLEET_REPO_VISIBILITY_JSON="$scratch/bad.json" \
  FLEET_REPO_VISIBILITY_LIST="$scratch/list.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
bad_rc=$?
set -e
[[ "$bad_rc" == "1" ]] || fail "scenario7b: malformed allowlist must exit 1, got rc=$bad_rc ($bad_out)"
grep -q 'WATCHER-BROKEN' <<<"$bad_out" || fail "scenario7b: must LOUD ($bad_out)"
ok "scenario7: missing or malformed allowlist fails loud"

# --- 8. live gh path passes --limit ----------------------------------------
: >"$gh_log"; : >"$triage"
base_allow
export GH_REPO_LIST="$scratch/list.json"
base_list
set +e
live_out=$(
  FLEET_REPO_VISIBILITY_JSON="$scratch/allow.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "scenario8: live gh path must exit 0, got rc=$live_rc ($live_out)"
grep -q 'repo list' "$gh_log" || fail "scenario8: must call gh repo list (gh=$(cat "$gh_log"))"
grep -q -- '--limit' "$gh_log" || fail "scenario8: must pass --limit (gh=$(cat "$gh_log"))"
unset GH_REPO_LIST
ok "scenario8: live gh path passes --limit"

# --- 9. production allowlist -----------------------------------------------
jq -e '.org == "Nishfleet"' "$allow" >/dev/null \
  || fail "scenario9: production org must be Nishfleet"
jq -e '.limit >= 100' "$allow" >/dev/null \
  || fail "scenario9: production limit must be >= 100 (gh default is 30)"
for name in 0509-telemetry fleet2 egress-probe; do
  jq -e --arg n "$name" '.allow_private[] | select(.name == $n)' "$allow" >/dev/null \
    || fail "scenario9: production allowlist missing $name"
done
ok "scenario9: production allowlist names the live private non-product set"

# --- 10. heartbeat wiring --------------------------------------------------
grep -F 'fleet-repo-visibility-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-repo-visibility-canary"
grep -F 'repo_visibility_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture repo_visibility_canary_rc"
grep -F -- '_propagate_crash repo_visibility_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the repo-visibility gate fails loud"
grep -q 'bin/fleet-repo-visibility-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-repo-visibility-canary"
grep -q 'config/repo-visibility.json' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install config/repo-visibility.json"
ok "scenario10: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

ok "fleet-repo-visibility-canary: clean, undeclared, sink, archived, dedup, broken watch, allowlist, --limit, prod, wiring"
