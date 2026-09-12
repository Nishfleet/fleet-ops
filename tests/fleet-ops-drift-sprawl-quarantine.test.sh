#!/usr/bin/env bash
# tests/fleet-ops-drift-sprawl-quarantine.test.sh
#
# fleet-ops#5602: a stray sibling artifact (.bak* / .orig next to a
# MANIFEST-managed path) must NOT hold the merge-to-live gate red until a
# judge hand-archives it. The drift canary quarantines the artifact under
# agent-state/backups/manifest-sprawl/, names the writer in QUARANTINE.log
# and the LOUD line, auto-files the class once (deduped), and re-checks —
# the gate is red at most the tick that found the sprawl.
#
# Drill (offline: FLEET_OPS_SKIP_FETCH=1, stub gh + systemctl, overlaid
# workspaces root — never touches the live box):
#   1. .bak sibling -> canary rc=0 same tick, artifact moved, writer named,
#      issue filed with the sprawl marker.
#   2. Next tick clean -> rc=0, no DRIFT-QUARANTINE, no re-file.
#   3. .orig sibling -> install.sh --check flags it; canary quarantines it.
#   4. Residual non-sprawl drift -> still rc=1 DRIFT-INSTALL.
#
# Hosted by tests/ci-standards-audit.test.sh (the worker App cannot push
# .github/workflows/**); pinned in tests/p14-test-listing-gate.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

canary_src="$repo_root/bin/fleet-ops-drift.py"
[[ -f "$canary_src" ]] || fail "missing bin/fleet-ops-drift.py"
grep -q 'quarantine_sprawl_diffs' "$canary_src" \
    || fail "drift canary must define quarantine_sprawl_diffs (fleet-ops#5602)"
grep -q 'DRIFT-QUARANTINE' "$canary_src" \
    || fail "drift canary must emit DRIFT-QUARANTINE"
grep -q 'manifest-sprawl-quarantine: fleet-ops#5602' "$canary_src" \
    || fail "drift canary must carry the sprawl-quarantine marker"
grep -q 'base\.orig' "$repo_root/install.sh" \
    || fail "install.sh check_bak_sprawl must also flag .orig siblings (fleet-ops#5602)"

scratch="$(mktemp -d -t drift-sprawl.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.config/systemd/user"

ws="$scratch/workspaces"
canon="$ws/tooling/fleet-ops-deploy-clone"
mkdir -p "$canon"

# Real install.sh exercises the real --check (incl. check_bak_sprawl).
cp "$repo_root/install.sh" "$canon/install.sh"
chmod +x "$canon/install.sh"

# One managed file; its live dest is a symlink into the canonical checkout.
managed_dir="$HOME/managed-root"
managed_dest="$managed_dir/probe.conf"
mkdir -p "$managed_dir"
printf 'probe v1\n' >"$canon/probe.conf"
cat >"$canon/MANIFEST" <<MANIFEST
probe.conf $managed_dest
MANIFEST
ln -s "$canon/probe.conf" "$managed_dest"

# Canon is a clean git repo on main with origin/main == HEAD so
# check_checkout passes and `git show origin/main:<src>` resolves.
git -C "$canon" init -q -b main
git -C "$canon" config user.email "test@example.com"
git -C "$canon" config user.name "test"
git -C "$canon" add -A
git -C "$canon" commit -q -m "scratch canon"
git -C "$canon" update-ref refs/remotes/origin/main "$(git -C "$canon" rev-parse HEAD)"

# Stub gh: log every invocation, serve an open-issues JSON, fake-create.
gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
: >"$gh_log"
echo '[]' >"$scratch/open.json"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/3999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"

# Stub systemctl: nothing enabled, everything benign.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
args=("$@")
if [[ "${args[0]:-}" == "--user" ]]; then shift; fi
case "${1:-}" in
  list-unit-files) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$systemctl_fake"

qdir="$ws/agent-state/backups/manifest-sprawl"
actions_log="$ws/agent-state/actions.log"
mkdir -p "$(dirname "$actions_log")"
# A console-log line naming the artifact proves the writer-attribution seam.
printf '[2026-09-12T00:00:00Z] [fleet-drill] parked %s.bak-judge-drill-20260912\n' \
  "$managed_dest" >"$actions_log"

export FLEET_OPS_WORKSPACES_ROOT="$ws"
export FLEET_OPS_CANONICAL_CHECKOUT="$canon"
export PATH="$scratch:$PATH"

run_canary() {
  set +e
  canary_out=$(
    HOME="$HOME" \
    FLEET_OPS_CHECKOUT="$canon" \
    FLEET_OPS_WORKSPACES_ROOT="$ws" \
    FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
    FLEET_OPS_QUARANTINE_DIR="$qdir" \
    FLEET_OPS_ACTIONS_LOG="$actions_log" \
    FLEET_OPS_SKIP_FETCH=1 \
    FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
    FLEET_OPS_TRIAGE="$scratch/triage.md" \
    FLEET_OPS_AUDIT_LOG="$scratch/audit.log" \
    FLEET_OPS_DRIFT_FILE=1 \
    FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    FLEET_OPS_DRIFT_CLOSE=0 \
    FLEET_OPS_RETARGET_BIN="$scratch/no-such-helper" \
    FLEET_OPS_DRIFT_BIN= \
    GH="$gh_fake" \
    GH_LOG="$gh_log" \
    GH_OPEN_ISSUES="$scratch/open.json" \
    python3 "$canary_src" 2>&1
  )
  canary_rc=$?
  set -e
}

# --- 1. .bak sibling -> quarantined same tick, writer named, gate green ------
: >"$gh_log"
: >"$scratch/triage.md"
bak="$managed_dir/probe.conf.bak-judge-drill-20260912"
printf 'stale backup\n' >"$bak"
run_canary
[[ "$canary_rc" -eq 0 ]] \
    || fail "scenario1: canary must self-heal to rc=0, got rc=$canary_rc out=$canary_out"
[[ "$canary_out" == *"DRIFT-QUARANTINE"* ]] \
    || fail "scenario1: expected DRIFT-QUARANTINE, got: $canary_out"
[[ "$canary_out" == *"$qdir"* ]] \
    || fail "scenario1: quarantine line must name the quarantine dir, got: $canary_out"
[[ "$canary_out" == *"nametag=bak-judge-drill-20260912"* ]] \
    || fail "scenario1: writer nametag must name the .bak tag, got: $canary_out"
[[ ! -e "$bak" ]] \
    || fail "scenario1: .bak must be gone from the managed dir"
[[ -f "$qdir/probe.conf.bak-judge-drill-20260912" ]] \
    || fail "scenario1: .bak must sit in the quarantine dir (ls: $(ls "$qdir" 2>/dev/null))"
grep -q "moved_to=$qdir/probe.conf.bak-judge-drill-20260912" "$qdir/QUARANTINE.log" \
    || fail "scenario1: QUARANTINE.log must record moved_to (got: $(cat "$qdir/QUARANTINE.log" 2>/dev/null))"
grep -q "writer=.*bak-judge-drill" "$qdir/QUARANTINE.log" \
    || fail "scenario1: QUARANTINE.log must name the writer"
grep -q 'issue create' "$gh_log" \
    || fail "scenario1: must auto-file the quarantined class (log=$(cat "$gh_log"))"
grep -q 'manifest-sprawl-quarantine: fleet-ops#5602' "$gh_log" \
    || fail "scenario1: filed issue must carry the sprawl marker (log=$(cat "$gh_log"))"
[[ "$canary_out" == *"drift canary: clean"* ]] \
    || fail "scenario1: canary must end clean after quarantine, got: $canary_out"
ok "scenario1: .bak sibling quarantined, writer named, gate never red"

# --- 2. next tick: clean, no re-quarantine, no duplicate filing -------------
: >"$gh_log"
run_canary
[[ "$canary_rc" -eq 0 ]] \
    || fail "scenario2: post-quarantine tick must be green, got rc=$canary_rc out=$canary_out"
[[ "$canary_out" != *"DRIFT-QUARANTINE"* ]] \
    || fail "scenario2: nothing left to quarantine, got: $canary_out"
[[ "$canary_out" == *"install.sh --check: clean"* ]] \
    || fail "scenario2: expected clean --check, got: $canary_out"
! grep -q 'issue create' "$gh_log" \
    || fail "scenario2: must not re-file on a green tick (log=$(cat "$gh_log"))"
ok "scenario2: next tick is clean — gate was red for zero ticks"

# --- 3. .orig sibling: install.sh flags it, canary quarantines it -----------
orig="$managed_dir/probe.conf.orig-hotpatch-20260912"
printf 'editor residue\n' >"$orig"
set +e
check_out=$(cd "$canon" && HOME="$HOME" ./install.sh --check 2>&1)
check_rc=$?
set -e
[[ "$check_rc" -eq 1 ]] \
    || fail "scenario3: install.sh --check must flag the .orig sibling, got rc=$check_rc out=$check_out"
[[ "$check_out" == *".orig next to managed MANIFEST file"* ]] \
    || fail "scenario3: --check must emit the .orig sprawl line, got: $check_out"
run_canary
[[ "$canary_rc" -eq 0 ]] \
    || fail "scenario3: canary must self-heal .orig sprawl to rc=0, got rc=$canary_rc out=$canary_out"
[[ ! -e "$orig" && -f "$qdir/probe.conf.orig-hotpatch-20260912" ]] \
    || fail "scenario3: .orig must be quarantined (ls: $(ls "$qdir" 2>/dev/null))"
ok "scenario3: .orig sibling flagged by --check and quarantined by the canary"

# --- 4. residual non-sprawl drift still fails loud --------------------------
# A missing dest is `DIFF: <dest> -> <missing> (want <repo>)` — not sprawl,
# so the canary must still hold the gate red on it.
rm -f "$managed_dest"
run_canary
[[ "$canary_rc" -eq 1 ]] \
    || fail "scenario4: real drift must still fail rc=1, got rc=$canary_rc out=$canary_out"
[[ "$canary_out" == *"DRIFT-INSTALL"* ]] \
    || fail "scenario4: expected DRIFT-INSTALL for residual drift, got: $canary_out"
[[ "$canary_out" == *"MANIFEST install drift"* ]] \
    || fail "scenario4: expected MANIFEST install drift report, got: $canary_out"
ok "scenario4: non-sprawl drift still holds the gate red"

echo "PASS: fleet-ops-drift-sprawl-quarantine (fleet-ops#5602)"
