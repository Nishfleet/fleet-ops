#!/usr/bin/env bash
# tests/fleet-ops-deploy-rescue.test.sh
#
# fleet-ops#3634: self-rescue a deploy clone left on a named branch or dirty
# instead of blocking every merge.
#
# Proves, entirely offline with mocked systemctl and a local git remote:
#   1. A clone on a named non-main branch with a dirty tracked file and an
#      untracked file, with no live process holding the clone as its cwd, is
#      self-rescued: the deploy exits 0, the clone is reset to main ==
#      origin/main, the named branch is pushed to the fake origin carrying
#      the WIP commit, and the patch dir exists under agent-state.
#   2. The same clone with a live process holding it as its cwd still
#      DEPLOY-BLOCKs (exit 1) and is not reset out from under the process.
#
# The real bin/fleet-ops-deploy is exercised.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq missing"
[[ -x "$repo_root/bin/fleet-ops-deploy" ]] || fail "missing bin/fleet-ops-deploy"
[[ -f "$repo_root/bin/fleet-ops-drift.py" ]] || fail "missing bin/fleet-ops-drift.py"
grep -q 'rescue_deploy_clone' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must implement the self-rescue path (fleet-ops#3634)"
grep -q 'clone_held_as_cwd' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must detect a live process holding the clone as cwd (fleet-ops#3634)"
grep -q 'deploy-clone-rescue-' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must write the rescue patch under agent-state/deploy-clone-rescue-<ts>/ (fleet-ops#3634)"

scratch="$(mktemp -d -t fleet-ops-deploy-rescue.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
# fleet-ops#410: do not let the canary --apply the live products/fleet-ops
# symlink while this scratch checkout is under test.
export FLEET_OPS_PRODUCTS_LINK="$scratch/products-fleet-ops-absent"
mkdir -p "$HOME/.local/bin" \
         "$HOME/.config/systemd/user" \
         "$HOME/.pi/agent/prompts" \
         "$HOME/.local/state/fleet-ops"

checkout="$scratch/fleet-ops-checkout"
install="$checkout/install.sh"
canary="$HOME/.local/bin/fleet-ops-drift"
deploy="$checkout/bin/fleet-ops-deploy"

# --- build a minimal deploy checkout -----------------------------------------
mkdir -p "$checkout/bin" "$checkout/systemd" "$checkout/config"
cp "$repo_root/install.sh" "$install"
cp "$repo_root/bin/fleet-ops-drift.py" "$checkout/bin/fleet-ops-drift.py"
cp "$repo_root/bin/fleet-ops-deploy" "$deploy"
chmod +x "$install" "$checkout/bin/fleet-ops-drift.py" "$deploy"

cat >"$checkout/config/intake-repos.json" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON

cat >"$checkout/MANIFEST" <<MANIFEST
systemd/demo.timer $HOME/.config/systemd/user/demo.timer
bin/demo-script $HOME/.local/bin/demo-script
bin/fleet-ops-drift.py $HOME/.local/bin/fleet-ops-drift
bin/intake-reconcile $HOME/.local/bin/intake-reconcile
systemd/intake-reconcile.path $HOME/.config/systemd/user/intake-reconcile.path
systemd/intake-reconcile.timer $HOME/.config/systemd/user/intake-reconcile.timer
MANIFEST

cat >"$checkout/systemd/demo.timer" <<'UNIT'
[Unit]
Description=Demo timer

[Timer]
OnCalendar=*:00/30
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat >"$checkout/systemd/intake-reconcile.path" <<'UNIT'
[Unit]
Description=Reconcile path

[Path]
PathChanged=/tmp/intake-repos.json
Unit=intake-reconcile.service

[Install]
WantedBy=default.target
UNIT

cat >"$checkout/systemd/intake-reconcile.timer" <<'UNIT'
[Unit]
Description=Reconcile timer

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT

# Templates fleet-ops actually ships — the drift canary matches rogue
# instances (pi-intake@rogue.timer) against these by template prefix.
cat >"$checkout/systemd/pi-intake@.timer" <<'UNIT'
[Unit]
Description=Pi intake timer for %i

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT
cat >"$checkout/systemd/pi-scout@.timer" <<'UNIT'
[Unit]
Description=Pi scout timer for %i

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT

cat >"$checkout/bin/demo-script" <<'BIN'
#!/usr/bin/env bash
echo demo
BIN
chmod +x "$checkout/bin/demo-script"

cat >"$checkout/bin/intake-reconcile" <<'BIN'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
json="$here/../config/intake-repos.json"
for repo in $(jq -r '.repos[].name' "$json"); do
  systemctl --user enable --now "pi-intake@$repo.timer" >/dev/null 2>&1 || true
  systemctl --user enable --now "pi-scout@$repo.timer" >/dev/null 2>&1 || true
done
BIN
chmod +x "$checkout/bin/intake-reconcile"

# --- local git repo with a real origin ---------------------------------------
origin_bare="$scratch/origin.git"
git -c init.defaultBranch=main init --bare -q "$origin_bare"
git -C "$checkout" init -q -b main
git -C "$checkout" config user.email "test@example.com"
git -C "$checkout" config user.name "Test"
git -C "$checkout" add .
git -C "$checkout" commit -q -m "initial"
git -C "$checkout" remote add origin "$origin_bare"
git -C "$checkout" push -q origin HEAD:main
git -C "$checkout" fetch -q origin
git -C "$checkout" branch -q --set-upstream-to=origin/main main

# --- fake systemctl ----------------------------------------------------------
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
enabled_file="${FLEET_OPS_FAKE_ENABLED:-/dev/null}"
mkdir -p "$(dirname "$enabled_file")" 2>/dev/null || true
if [ "${1:-}" = "--user" ]; then shift; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  is-enabled) [ -f "$enabled_file" ] && grep -qxF "$1" "$enabled_file" && exit 0; exit 1 ;;
  list-unit-files)
    if [ -f "$enabled_file" ]; then
      while IFS= read -r u; do [ -n "$u" ] && printf '%s enabled enabled\n' "$u"; done < "$enabled_file"
    fi
    exit 0 ;;
  daemon-reload) exit 0 ;;
  enable)
    for u in "$@"; do
      [ -n "$u" ] || continue
      case "$u" in --now) ;; *) printf '%s\n' "$u" >> "$enabled_file" ;; esac
    done
    exit 0 ;;
  start) exit 0 ;;
  is-active) printf 'inactive\n'; exit 3 ;;
  *) printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$systemctl_fake"

enabled_units="$scratch/enabled_units"
: >"$enabled_units"
export FLEET_OPS_FAKE_ENABLED="$enabled_units"

run_deploy() {
  PATH="$scratch:$PATH" \
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DRIFT_BIN="$canary" \
  FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_AGENT_STATE="$scratch/agent-state" \
    "$deploy" 2>&1
}

# --- scenario 1: abandoned clone on a named branch with dirty tracked +
# untracked files is self-rescued (fleet-ops#3634) ---------------------------
git -C "$checkout" checkout -q -b auditor/rescue-drill
echo '# dirty tracked' >> "$checkout/bin/demo-script"
echo 'untracked content' > "$checkout/untracked-file.txt"
[ "$(git -C "$checkout" symbolic-ref --short HEAD)" = "auditor/rescue-drill" ] \
    || fail "scenario1: setup expected named branch auditor/rescue-drill"

if ! out=$(run_deploy); then
    fail "scenario1: deploy should self-rescue and exit 0, got: $out"
fi
[[ "$out" == *"rescued deploy clone"* ]] \
    || fail "scenario1: expected rescue log line (got: $out)"
[ "$(git -C "$checkout" symbolic-ref --short HEAD)" = "main" ] \
    || fail "scenario1: clone must be on main after rescue (got: $(git -C "$checkout" symbolic-ref --short HEAD))"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$(git -C "$checkout" rev-parse origin/main)" ] \
    || fail "scenario1: clone HEAD must equal origin/main after rescue"
[ -z "$(git -C "$checkout" status --porcelain)" ] \
    || fail "scenario1: clone must be clean after rescue (got: $(git -C "$checkout" status --porcelain))"
# The named branch must exist on the fake origin with the WIP commit.
git -C "$checkout" fetch -q origin
git -C "$checkout" rev-parse -q --verify origin/auditor/rescue-drill >/dev/null 2>&1 \
    || fail "scenario1: branch auditor/rescue-drill must exist on the fake origin"
wip_commit=$(git -C "$checkout" rev-parse origin/auditor/rescue-drill)
[[ "$(git -C "$checkout" log -1 --format=%s "$wip_commit")" == *"deploy-clone rescue WIP"* ]] \
    || fail "scenario1: origin branch must carry the WIP commit (got: $(git -C "$checkout" log -1 --format=%s "$wip_commit"))"
# The patch dir must exist with the tracked patch and the untracked file.
rescue_dir=$(ls -d "$scratch/agent-state"/deploy-clone-rescue-* 2>/dev/null | head -1)
[ -n "$rescue_dir" ] || fail "scenario1: patch dir must exist under agent-state"
[ -f "$rescue_dir/tracked.patch" ] || fail "scenario1: tracked.patch must exist in the patch dir"
grep -q 'dirty tracked' "$rescue_dir/tracked.patch" \
    || fail "scenario1: tracked.patch must contain the dirty tracked change"
[ -f "$rescue_dir/untracked/untracked-file.txt" ] \
    || fail "scenario1: untracked file must be saved in the patch dir"
ok "scenario1: abandoned branched+dirty clone is self-rescued (exit 0, main==origin/main, branch pushed, patch saved)"

# --- scenario 2: a live process holding the clone as cwd still blocks -------
git -C "$checkout" checkout -q -b auditor/live-hold
echo '# dirty tracked 2' >> "$checkout/bin/demo-script"
echo 'untracked 2' > "$checkout/untracked-2.txt"
( cd "$checkout" && exec sleep 30 ) &
holder=$!
if out=$(run_deploy); then
    kill "$holder" 2>/dev/null || true
    fail "scenario2: deploy must block when a live process holds the clone as cwd, got: $out"
fi
kill "$holder" 2>/dev/null || true
[[ "$out" == *"DEPLOY-BLOCKED"* ]] \
    || fail "scenario2: expected DEPLOY-BLOCKED (got: $out)"
[[ "$out" == *"live process holds the clone as cwd"* ]] \
    || fail "scenario2: expected live-process reason (got: $out)"
[ "$(git -C "$checkout" symbolic-ref --short HEAD)" = "auditor/live-hold" ] \
    || fail "scenario2: clone must stay on the named branch when a live process holds it"
ok "scenario2: a live process holding the clone as cwd keeps the LOUD block"

ok "fleet-ops-deploy rescue: self-rescue and live-hold block pass offline"
