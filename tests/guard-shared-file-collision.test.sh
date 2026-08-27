#!/usr/bin/env bash
# tests/guard-shared-file-collision.test.sh
#
# Proves the shared-file collision guard:
#   1. Ignores non-file tools.
#   2. Ignores files that are not shared.
#   3. Warns (exit 0) when an open PR touches the file.
#   4. Emits a Claude hook JSON with additionalContext.
#   5. Resolves ~/.claude/hooks shims to their canonical source files.
#   6. Handles MultiEdit / multiple files.
#
# Runs offline using a hermetic PR cache fixture.  No gh, no network, no
# real ~/.claude/hooks.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
lib="$repo_root/lib/guard_shared_file_collision.py"
wrapper="$repo_root/bin/guard_shared_file_collision"
hook="$repo_root/bin/guard_shared_file_collision_hook.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$wrapper" ]] || fail "not executable: $wrapper"
[[ -f "$hook" ]] || fail "missing $hook"

scratch=$(mktemp -d -t guard-sfc.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

export GUARD_SHARED_FILE_PR_CACHE="$scratch/pr-cache.json"
export XDG_RUNTIME_DIR="$scratch/run"

# --- build a fake git repo the guard will discover ---------------------------
repo="$scratch/repo"
mkdir -p "$repo/lib" "$repo/bin" "$repo/config" "$repo/.claude/hooks" "$repo/systemd"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" remote add origin "https://github.com/Nishfleet/fleet-ops.git"

# Files that look like the real shared files.
touch "$repo/lib/seat-lib.sh"
touch "$repo/config/seat-caps.json"
touch "$repo/systemd/fleet-heartbeat.service"
touch "$repo/bin/guard_shared_file_collision_hook.py"

# A fake ~/.claude/hooks file installed from the repo (symlink pattern).
mkdir -p "$scratch/home/.claude/hooks"
ln -s "$repo/bin/guard_shared_file_collision_hook.py" "$scratch/home/.claude/hooks/guard_shared_file_collision.py"

# Fixture: one open PR touching lib/seat-lib.sh, another touching bin/guard_*.py.
cat >"$GUARD_SHARED_FILE_PR_CACHE" <<'JSON'
[
  {
    "number": 44,
    "title": "fix(seat): cap-map allowlist",
    "author": {"login": "app/nishfleet-worker"},
    "files": [
      {"path": "lib/seat-lib.sh", "additions": 4, "deletions": 1, "changeType": "MODIFIED"}
    ]
  },
  {
    "number": 48,
    "title": "fix(seat): another cap-map patch",
    "author": {"login": "nish3451"},
    "files": [
      {"path": "lib/seat-lib.sh", "additions": 2, "deletions": 0, "changeType": "MODIFIED"}
    ]
  },
  {
    "number": 999,
    "title": "feat: new shared-file guard",
    "author": {"login": "app/nishfleet-worker"},
    "files": [
      {"path": "bin/guard_shared_file_collision_hook.py", "additions": 1, "deletions": 0, "changeType": "ADDED"}
    ]
  }
]
JSON

run_guard() {
    local json="$1"
    set +e
    out=$(printf '%s' "$json" | "$wrapper" 2>&1)
    rc=$?
    set -e
}

# --- 1. non-file tools are ignored -------------------------------------------
run_guard '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[[ "$rc" == 0 ]] || fail "non-file tool must exit 0, got rc=$rc"
[[ -z "$out" ]] || fail "non-file tool must produce no output, got: $out"
ok "non-file tool is ignored"

# --- 2. a non-shared file is ignored -----------------------------------------
run_guard "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$repo/README.md\"}}"
[[ "$rc" == 0 ]] || fail "non-shared file must exit 0, got rc=$rc"
[[ -z "$out" ]] || fail "non-shared file must produce no output, got: $out"
ok "non-shared file is ignored"

# --- 3. a shared file with open PR collisions warns --------------------------
run_guard "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$repo/lib/seat-lib.sh\"}}"
[[ "$rc" == 0 ]] || fail "collision must exit 0 (warn only), got rc=$rc"
printf '%s\n' "$out" | grep -q 'shared-file collision guard' || fail "expected warning, got: $out"
printf '%s\n' "$out" | grep -q '#44' || fail "expected PR #44 in warning, got: $out"
printf '%s\n' "$out" | grep -q '#48' || fail "expected PR #48 in warning, got: $out"
ok "shared file with open PRs warns and names the PRs"

# --- 4. stdout is the Claude hook JSON with additionalContext ----------------
json_out=$(printf '%s\n' "$out" | tail -n 1)
[[ "$json_out" == '{"hookSpecificOutput"'* ]] || fail "stdout must be a hook JSON, got: $json_out"
ok "warning is emitted as hookSpecificOutput.additionalContext"

# --- 5. no collision on a file no PR touches ---------------------------------
run_guard "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/systemd/fleet-heartbeat.service\"}}"
[[ "$rc" == 0 ]] || fail "no-collision edit must exit 0, got rc=$rc"
[[ -z "$out" ]] || fail "no-collision edit must produce no output, got: $out"
ok "shared file with no open-PR hits is silent"

# --- 6. MultiEdit with one matching file warns --------------------------------
run_guard "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"edits\":[{\"file_path\":\"$repo/README.md\"},{\"file_path\":\"$repo/lib/seat-lib.sh\"}]}}"
[[ "$rc" == 0 ]] || fail "MultiEdit with a match must exit 0, got rc=$rc"
printf '%s\n' "$out" | grep -q 'lib/seat-lib.sh' || fail "MultiEdit warning must name the hit file, got: $out"
ok "MultiEdit with one shared collision warns"

# --- 7. ~/.claude/hooks shim resolves to canonical source --------------------
run_guard "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$scratch/home/.claude/hooks/guard_shared_file_collision.py\"}}"
[[ "$rc" == 0 ]] || fail "shim edit must exit 0, got rc=$rc"
# The installed hook is a symlink to the repo's bin/guard_shared_file_collision_hook.py,
# so the guard resolves to the canonical fleet-ops source and matches the PR.
printf '%s\n' "$out" | grep -q 'guard' || fail "installed hook edit must warn about guard collision, got: $out"
ok ".claude/hooks installed file resolves to fleet-ops canonical source"

# --- 8. hook shim runs the same canonical logic ------------------------------
out2=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/lib/seat-lib.sh"}}\n' "$repo" | python3 "$hook" 2>&1)
[[ $? == 0 ]] || fail "hook shim must exit 0"
printf '%s\n' "$out2" | grep -q '#44' || fail "hook shim must warn about #44, got: $out2"
ok "hook shim invokes canonical lib and warns"

echo "OK: shared-file collision guard passes offline drill (fleet-ops#539)"
