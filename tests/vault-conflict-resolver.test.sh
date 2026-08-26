#!/usr/bin/env bash
# tests/vault-conflict-resolver.test.sh
#
# fleet-ops#529: the vault sync-conflict handler is a real oneshot, not
# prose. This drill plants *.sync-conflict-* fixtures and proves the four
# safe classes plus divergent quarantine. Hosted CI runs it via
# tests/rule-enforcement.test.sh (worker tokens cannot push workflows).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
resolver="$repo_root/lib/vault-conflict-resolver.py"
manifest="$repo_root/MANIFEST"
service="$repo_root/systemd/vault-conflict-resolver.service"
timer="$repo_root/systemd/vault-conflict-resolver.timer"
vault_rules="/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$resolver" ]] || fail "missing $resolver"
[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$service" ]] || fail "missing $service"
[[ -f "$timer" ]] || fail "missing $timer"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t vault-conflict.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

vault="$scratch/vault"
log="$scratch/resolver.log"
dispatch_bin="$scratch/dispatch"
dispatch_log="$scratch/dispatch.log"
mkdir -p "$vault/00 Inbox/agent-drop/test" "$vault/_system"

cat >"$dispatch_bin" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DISPATCH_LOG:?}"
cat >>"${DISPATCH_LOG}.prompt"
exit 0
STUB
chmod +x "$dispatch_bin"

run_resolver() {
  env \
    FLEET_VAULT="$vault" \
    FLEET_VAULT_CONFLICT_LOG="$log" \
    FLEET_VAULT_CONFLICT_DISPATCH="$dispatch_bin" \
    DISPATCH_LOG="$dispatch_log" \
    python3 "$resolver"
}

# --- 1. MANIFEST + unit lock ----------------------------------------------
bin_line="lib/vault-conflict-resolver.py /home/nish/.local/bin/vault-conflict-resolver"
svc_line="systemd/vault-conflict-resolver.service /home/nish/.config/systemd/user/vault-conflict-resolver.service"
timer_line="systemd/vault-conflict-resolver.timer /home/nish/.config/systemd/user/vault-conflict-resolver.timer"
grep -Fxq "$bin_line" "$manifest" || fail "MANIFEST missing: $bin_line"
grep -Fxq "$svc_line" "$manifest" || fail "MANIFEST missing: $svc_line"
grep -Fxq "$timer_line" "$manifest" || fail "MANIFEST missing: $timer_line"
grep -q '^ExecStart=/usr/bin/python3 /home/nish/.local/bin/vault-conflict-resolver$' "$service" \
  || fail "service ExecStart must invoke the deployed resolver"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer must be wanted by timers.target"
grep -q '^OnUnitActiveSec=10min$' "$timer" \
  || fail "timer must fire every 10 minutes (DISPATCH_COOLDOWN_SEC window)"
ok "MANIFEST and unit files lock the live handler into deploy"

# --- 2. identical ---------------------------------------------------------
ident_dir="$vault/00 Inbox/agent-drop/test"
printf 'same\n' >"$ident_dir/rtest1.md"
printf 'same\n' >"$ident_dir/rtest1.sync-conflict-20260827-100000-TESTDEV.md"
run_resolver
[[ ! -e "$ident_dir/rtest1.sync-conflict-20260827-100000-TESTDEV.md" ]] \
  || fail "identical conflict copy should be deleted"
[[ -f "$ident_dir/rtest1.md" ]] || fail "identical must leave the base"
grep -q 'RESOLVED identical' "$log" || fail "identical must log RESOLVED identical"
ok "identical: conflict copy deleted, base kept"

# --- 3. base-superset -----------------------------------------------------
printf 'hello\nworld\n' >"$ident_dir/rtest2.md"
printf 'hello\n' >"$ident_dir/rtest2.sync-conflict-20260827-100001-TESTDEV.md"
run_resolver
[[ ! -e "$ident_dir/rtest2.sync-conflict-20260827-100001-TESTDEV.md" ]] \
  || fail "base-superset conflict copy should be deleted"
[[ "$(cat "$ident_dir/rtest2.md")" == $'hello\nworld' ]] \
  || fail "base-superset must leave the longer base"
grep -q 'RESOLVED base-superset' "$log" || fail "base-superset must log"
ok "base-superset: conflict copy deleted, longer base kept"

# --- 4. conflict-superset -------------------------------------------------
printf 'hello\n' >"$ident_dir/rtest3.md"
printf 'hello\nworld\n' >"$ident_dir/rtest3.sync-conflict-20260827-100002-TESTDEV.md"
run_resolver
[[ ! -e "$ident_dir/rtest3.sync-conflict-20260827-100002-TESTDEV.md" ]] \
  || fail "conflict-superset copy should be deleted"
[[ "$(cat "$ident_dir/rtest3.md")" == $'hello\nworld' ]] \
  || fail "conflict-superset must replace the base with the longer copy"
grep -q 'RESOLVED conflict-superset' "$log" || fail "conflict-superset must log"
ok "conflict-superset: base replaced atomically, conflict copy deleted"

# --- 5. missing-base restore ----------------------------------------------
printf 'only-copy\n' >"$ident_dir/rtest-missing.sync-conflict-20260827-100004-TESTDEV.md"
run_resolver
[[ -f "$ident_dir/rtest-missing.md" ]] || fail "missing-base must restore the base path"
[[ ! -e "$ident_dir/rtest-missing.sync-conflict-20260827-100004-TESTDEV.md" ]] \
  || fail "missing-base must consume the conflict copy"
[[ "$(cat "$ident_dir/rtest-missing.md")" == $'only-copy' ]] \
  || fail "missing-base restore wrote the wrong bytes"
grep -q 'RESOLVED restored-missing-base' "$log" || fail "missing-base must log"
ok "missing-base: conflict copy restored onto the base path"

# --- 6. divergent -> quarantine + dispatch, base untouched ----------------
printf 'mac-edit\n' >"$ident_dir/rtest4.md"
printf 'vps-edit\n' >"$ident_dir/rtest4.sync-conflict-20260827-100003-TESTDEV.md"
: >"$dispatch_log"
run_resolver
[[ -f "$ident_dir/rtest4.md" ]] || fail "divergent must leave the base"
[[ "$(cat "$ident_dir/rtest4.md")" == $'mac-edit' ]] \
  || fail "divergent must not merge or overwrite the base"
[[ ! -e "$ident_dir/rtest4.sync-conflict-20260827-100003-TESTDEV.md" ]] \
  || fail "divergent conflict copy must leave the vault (or the freeze never clears)"
shopt -s nullglob
quarantined=( "$vault/_system/conflict-quarantine/"*rtest4.conflict-quarantined.md )
shopt -u nullglob
[[ "${#quarantined[@]}" -eq 1 ]] || fail "divergent must land exactly one quarantined copy, got ${#quarantined[@]}"
[[ "$(cat "${quarantined[0]}")" == $'vps-edit' ]] \
  || fail "quarantined copy must preserve the other version"
grep -q 'QUARANTINED' "$log" || fail "divergent must log QUARANTINED"
grep -q 'vault-conflict 600' "$dispatch_log" || fail "divergent must dispatch (log=$(cat "$dispatch_log"))"
ok "divergent: quarantined under a non-freezing name, base untouched, worker dispatched"

# --- 7. leftover *.sync-conflict-* is a failed canary ---------------------
leftover=$(find "$vault" -name '*.sync-conflict-*' -type f | wc -l)
[[ "$leftover" -eq 0 ]] || fail "canary vault still has $leftover *.sync-conflict-* file(s)"
ok "fixture vault has zero leftover *.sync-conflict-* files"

# --- 8. live timer (VPS inner loop; hosted CI skips) ----------------------
if [[ -f "$vault_rules" ]]; then
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export XDG_RUNTIME_DIR
  state=$(systemctl --user is-active vault-conflict-resolver.timer 2>/dev/null || echo inactive)
  [[ "$state" == "active" ]] \
    || fail "VPS vault is present but vault-conflict-resolver.timer is $state — the 2026-08-23 wipe class is back"
  result=$(systemctl --user show vault-conflict-resolver.service --property=Result --value 2>/dev/null || true)
  [[ "$result" == "success" ]] \
    || fail "vault-conflict-resolver.service last Result=$result (not success)"
  ok "live timer is active and last Result=success"
else
  ok "hosted CI: skip live timer (vault not present)"
fi

echo "OK: vault-conflict-resolver four classes + quarantine + live timer"
