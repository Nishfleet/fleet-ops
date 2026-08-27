#!/usr/bin/env bash
# tests/fleet-pi-extensions-canary.test.sh
#
# Proves the proven-extension allowlist canary (fleet-ops#536) offline:
#   1. Clean: live ids all in proven, banned stay disabled -> OK, no file.
#   2. Unproven .ts dropped into extensions/ -> exit 1, LOUD, auto-files.
#   3. Banned id re-enabled as .ts -> exit 1, LOUD, auto-files.
#   4. Unproven settings.json package -> exit 1, auto-files.
#   5. Unproven settings.json extensions path -> exit 1, auto-files.
#   6. .bak and .disabled files are ignored.
#   7. Dedup: open issue already carrying the marker -> no second create.
#   8. Missing allowlist -> exit 1, WATCHER-BROKEN.
#   9. Production VPS live set matches the committed allowlist.
#  10. Heartbeat-tier1 wires the canary and propagates a gate fail-loud.
#
# Official Pi docs (extensions.md, settings.md, packages.md) have no
# proven-install gate: settings.extensions is additive extra paths, and
# `pi config` only toggles already-installed package resources.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-pi-extensions-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
allowlist="$repo_root/config/pi-extensions-allowlist.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$allowlist" ]] || fail "missing: $allowlist"

scratch="$(mktemp -d -t pi-ext-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_PI_EXTENSIONS_REPO="Nishfleet/fleet-ops"
export FLEET_PI_EXTENSIONS_FILE=1

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
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

ext_dir="$scratch/extensions"
settings="$scratch/settings.json"
al="$scratch/allowlist.json"
mkdir -p "$ext_dir"

write_allowlist() { cat >"$al"; }
write_settings()  { cat >"$settings"; }

base_allowlist() {
  write_allowlist <<'JSON'
{
  "version": 1,
  "proven": [
    {"id": "seat-health", "kind": "global-file", "proof": "fixture"},
    {"id": "spawn-guard-core", "kind": "global-file", "proof": "fixture"},
    {"id": "git:github.com/stnly/pi-grok", "kind": "package", "proof": "fixture"}
  ],
  "banned": [
    {"id": "auto-commit-on-exit", "kind": "global-file", "reason": "git add -A"},
    {"id": "git-checkpoint", "kind": "global-file", "reason": "stash collision"}
  ]
}
JSON
}

run_canary() {
  set +e
  env_out=$(
    FLEET_PI_EXTENSIONS_DIR="$ext_dir" \
    FLEET_PI_SETTINGS_JSON="$settings" \
    FLEET_PI_EXTENSIONS_ALLOWLIST="$al" \
    FLEET_OPS_REPO="$scratch" \
    FLEET_PI_PROJECT_ROOTS="" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

run_canary_with_roots() {
  local roots="$1"
  set +e
  env_out=$(
    FLEET_PI_EXTENSIONS_DIR="$ext_dir" \
    FLEET_PI_SETTINGS_JSON="$settings" \
    FLEET_PI_EXTENSIONS_ALLOWLIST="$al" \
    FLEET_OPS_REPO="$scratch" \
    FLEET_PI_PROJECT_ROOTS="$roots" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean: proven wired, banned disabled, bak ignored ------------------
: >"$gh_log"; : >"$triage"
base_allowlist
rm -rf "$ext_dir"; mkdir -p "$ext_dir"
printf 'export default function () {}\n' >"$ext_dir/seat-health.ts"
printf 'export default function () {}\n' >"$ext_dir/spawn-guard-core.ts"
printf 'disabled leftover\n' >"$ext_dir/auto-commit-on-exit.ts.disabled-20260825-git-add-A"
printf 'bak leftover\n' >"$ext_dir/seat-health.ts.bak-429-quota-20260826"
mkdir -p "$ext_dir/not-an-ext"
printf 'no index\n' >"$ext_dir/not-an-ext/utils.ts"
write_settings <<'JSON'
{ "packages": ["git:github.com/stnly/pi-grok"] }
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'PI-EXTENSIONS-OK' "$triage" || fail "scenario1: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on the clean state"
ok "scenario1: proven wired, disabled/bak/no-index ignored"

# --- 2. unproven .ts dropped ----------------------------------------------
: >"$gh_log"; : >"$triage"
base_allowlist
printf 'export default function () {}\n' >"$ext_dir/snake.ts"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'PI-EXTENSIONS-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'unproven-wired id=snake' "$triage" || fail "scenario2: must name snake"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q 'snake' "$gh_log" || fail "scenario2: filed title must name snake"
ok "scenario2: unproven .ts screams and auto-files"
rm -f "$ext_dir/snake.ts"

# --- 3. banned id re-enabled ----------------------------------------------
: >"$gh_log"; : >"$triage"
base_allowlist
printf 'export default function () {}\n' >"$ext_dir/auto-commit-on-exit.ts"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: expected rc=1, got $env_rc ($env_out)"
grep -q 'banned-wired id=auto-commit-on-exit' "$triage" || fail "scenario3: missing banned-wired"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: banned re-enable screams and auto-files"
rm -f "$ext_dir/auto-commit-on-exit.ts"

# --- 4. unproven package in settings.json ---------------------------------
: >"$gh_log"; : >"$triage"
base_allowlist
write_settings <<'JSON'
{ "packages": ["git:github.com/stnly/pi-grok", "npm:@unproven/snake"] }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=npm:@unproven/snake' "$triage" || fail "scenario4: must name the package"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: unproven package screams"
write_settings <<'JSON'
{ "packages": ["git:github.com/stnly/pi-grok"] }
JSON

# --- 5. unproven extra path in settings.json extensions[] -----------------
: >"$gh_log"; : >"$triage"
base_allowlist
write_settings <<'JSON'
{ "packages": ["git:github.com/stnly/pi-grok"], "extensions": ["/tmp/evil.ts"] }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=/tmp/evil.ts' "$triage" || fail "scenario5: must name the extra path"
ok "scenario5: unproven settings.extensions path screams"
write_settings <<'JSON'
{ "packages": ["git:github.com/stnly/pi-grok"] }
JSON

# --- 6. subdirectory with index.ts is a live extension --------------------
: >"$gh_log"; : >"$triage"
base_allowlist
mkdir -p "$ext_dir/subagent"
printf 'export default function () {}\n' >"$ext_dir/subagent/index.ts"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=subagent' "$triage" || fail "scenario6: dir with index.ts must count"
ok "scenario6: unproven */index.ts screams"
rm -rf "$ext_dir/subagent"

# --- 7. dedup against an open issue with the marker -----------------------
: >"$gh_log"; : >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\npi-extensions-canary: snake unproven-wired\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_allowlist
printf 'export default function () {}\n' >"$ext_dir/snake.ts"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario7: expected rc=1, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario7: must not file a duplicate"
ok "scenario7: open issue with marker dedupes"
unset GH_OPEN_ISSUES
rm -f "$ext_dir/snake.ts"

# --- 8. missing allowlist -> watcher broken --------------------------------
: >"$gh_log"; : >"$triage"
set +e
env_out=$(
  FLEET_PI_EXTENSIONS_DIR="$ext_dir" \
  FLEET_PI_SETTINGS_JSON="$settings" \
  FLEET_PI_EXTENSIONS_ALLOWLIST="$scratch/no-such-allowlist.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
env_rc=$?
set -e
[[ "$env_rc" == "1" ]] || fail "scenario8: expected rc=1, got $env_rc ($env_out)"
grep -q 'PI-EXTENSIONS-WATCHER-BROKEN' "$triage" || fail "scenario8: missing WATCHER-BROKEN"
ok "scenario8: missing allowlist fails loud"

# --- 9. production live set matches committed allowlist --------------------
: >"$gh_log"; : >"$triage"
prod_ext="/home/nish/.pi/agent/extensions"
prod_settings="/home/nish/.pi/agent/settings.json"
if [[ -d "$prod_ext" ]]; then
  set +e
  prod_out=$(
    FLEET_PI_EXTENSIONS_DIR="$prod_ext" \
    FLEET_PI_SETTINGS_JSON="$prod_settings" \
    FLEET_PI_EXTENSIONS_ALLOWLIST="$allowlist" \
    FLEET_OPS_REPO="$repo_root" \
    FLEET_PI_PROJECT_ROOTS="" \
    FLEET_PI_EXTENSIONS_FILE=0 \
    "$bin" 2>&1
  )
  prod_rc=$?
  set -e
  [[ "$prod_rc" == "0" ]] || fail "scenario9: production must be clean, got rc=$prod_rc ($prod_out)"
  ok "scenario9: production live set matches committed allowlist"
else
  ok "scenario9: production extensions dir absent (hosted CI) — skip live join"
fi

# --- 10. heartbeat wiring --------------------------------------------------
grep -F 'fleet-pi-extensions-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-pi-extensions-canary"
grep -F 'pi_extensions_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture pi_extensions_canary_rc"
grep -F -- 'exit "$pi_extensions_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the extensions gate fails loud"
grep -q 'bin/fleet-pi-extensions-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-pi-extensions-canary"
ok "scenario10: heartbeat-tier1 wires the canary, fail-loud on gate, MANIFEST installs it"

# --- 11. project-local .pi/extensions/*.ts under a project root -----------
# (fleet-ops#635) Pi auto-loads .pi/extensions/*.ts from the cwd once the
# project is trusted. A real check that walks the FLEET_PI_PROJECT_ROOTS
# list catches unproven project-local extensions that global-only misses.
proj_root="$scratch/projects"
mkdir -p "$proj_root/proja/.pi/extensions" "$proj_root/projb/.pi/extensions" "$proj_root/projc/.pi/extensions"
: >"$gh_log"; : >"$triage"
base_allowlist
printf 'export default function () {}\n' >"$proj_root/proja/.pi/extensions/snake.ts"
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "1" ]] || fail "scenario11: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=snake' "$triage" || fail "scenario11: must name snake"
grep -q 'issue create' "$gh_log" || fail "scenario11: must auto-file"
ok "scenario11: project-local .pi/extensions/*.ts unproven -> loud + file"
rm -f "$proj_root/proja/.pi/extensions/snake.ts"

# --- 12. project-local .pi/extensions/*/index.ts (subdir form) ------------
: >"$gh_log"; : >"$triage"
base_allowlist
mkdir -p "$proj_root/projb/.pi/extensions/subagent"
printf 'export default function () {}\n' >"$proj_root/projb/.pi/extensions/subagent/index.ts"
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "1" ]] || fail "scenario12: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=subagent' "$triage" || fail "scenario12: must name subagent"
ok "scenario12: project-local .pi/extensions/*/index.ts unproven -> loud"
rm -rf "$proj_root/projb/.pi/extensions/subagent"

# --- 13. project-local .pi/settings.json packages[] -----------------------
: >"$gh_log"; : >"$triage"
base_allowlist
cat >"$proj_root/projc/.pi/settings.json" <<'JSON'
{ "packages": ["npm:@unproven/snake"] }
JSON
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "1" ]] || fail "scenario13: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=npm:@unproven/snake' "$triage" || fail "scenario13: must name the package"
ok "scenario13: project-local .pi/settings.json package unproven -> loud"
rm -f "$proj_root/projc/.pi/settings.json"

# --- 14. project-local .pi/settings.json extensions[] ---------------------
: >"$gh_log"; : >"$triage"
base_allowlist
cat >"$proj_root/projc/.pi/settings.json" <<'JSON'
{ "extensions": ["./.pi/extra-evil.ts"] }
JSON
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "1" ]] || fail "scenario14: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=./.pi/extra-evil.ts' "$triage" || fail "scenario14: must name the extra path"
ok "scenario14: project-local .pi/settings.json extensions[] unproven -> loud"
rm -f "$proj_root/projc/.pi/settings.json"

# --- 15. project-local .bak and .disabled are ignored --------------------
: >"$gh_log"; : >"$triage"
base_allowlist
printf 'disabled leftover\n' >"$proj_root/projc/.pi/extensions/snake.ts.disabled-20260827"
printf 'bak leftover\n' >"$proj_root/projc/.pi/extensions/snake.ts.bak-20260827"
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "0" ]] || fail "scenario15: expected rc=0 (bak+disabled ignored), got $env_rc ($env_out)"
! grep -q 'unproven-wired id=snake' "$triage" || fail "scenario15: must NOT flag snake from .bak/.disabled"
! grep -q 'issue create' "$gh_log" || fail "scenario15: must NOT file"
ok "scenario15: project-local .bak and .disabled are ignored"
rm -rf "$proj_root"

# --- 16. multi-root colon-separated list ---------------------------------
: >"$gh_log"; : >"$triage"
base_allowlist
m1="$scratch/m1"; m2="$scratch/m2"
mkdir -p "$m1/repo-x/.pi/extensions" "$m2/repo-y/.pi/extensions"
printf 'export default function () {}\n' >"$m1/repo-x/.pi/extensions/snake.ts"
printf 'export default function () {}\n' >"$m2/repo-y/.pi/extensions/snake.ts"
run_canary_with_roots "$m1:$m2"
[[ "$env_rc" == "1" ]] || fail "scenario16: expected rc=1, got $env_rc ($env_out)"
grep -q 'unproven-wired id=snake' "$triage" || fail "scenario16: must name snake once"
ok "scenario16: multi-root colon list works"
rm -rf "$m1" "$m2"

# --- 17. project-local clean = empty FLEET_PI_PROJECT_ROOTS short-circuits -
: >"$gh_log"; : >"$triage"
base_allowlist
# clean global state, no project scan -> OK
run_canary_with_roots ""
[[ "$env_rc" == "0" ]] || fail "scenario17: empty roots + clean global expected rc=0, got $env_rc"
grep -q 'PI-EXTENSIONS-OK' "$triage" || fail "scenario17: missing OK"
ok "scenario17: empty FLEET_PI_PROJECT_ROOTS short-circuits the project scan"

# --- 18. banned project-local extension fails loud ------------------------
: >"$gh_log"; : >"$triage"
base_allowlist
mkdir -p "$proj_root/.pi/extensions"
printf 'export default function () {}\n' >"$proj_root/.pi/extensions/auto-commit-on-exit.ts"
run_canary_with_roots "$proj_root"
[[ "$env_rc" == "1" ]] || fail "scenario18: expected rc=1, got $env_rc ($env_out)"
grep -q 'banned-wired id=auto-commit-on-exit' "$triage" || fail "scenario18: must name banned id"
ok "scenario18: project-local banned extension fails loud"
rm -rf "$proj_root"

ok "fleet-pi-extensions-canary: unproven, banned, package, extra path, bak, dedup, prod clean, project-local .pi/extensions and .pi/settings.json (fleet-ops#635)"
