#!/usr/bin/env bash
# tests/pi-systemd-run.test.sh
#
# Proves the session-survive wrapper:
#   1. dry-run emits systemd-run --user --collect --no-block (not nohup)
#   2. --stdin becomes StandardInput=file:<abs>
#   3. nohup in the command is refused
#   4. already-active unit is a no-op (does not call systemd-run)
#   5. routing docs name pi-systemd-run so nohup is not the path of least
#      resistance (fleet-ops#54, #255). Hermetic fixtures prove the check;
#      live AGENTS.md / CLAUDE.md / vault standing-rules / ~/.codex/AGENTS.md
#      are asserted on the VPS.
#   6. LIVE (skipped if no user systemd): a job started from a dying parent
#      is still active after that parent exits.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-systemd-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- 1. dry-run shape -------------------------------------------------------
out="$("$bin" --dry-run --unit issue26-shape -- sleep 1)"
printf '%s\n' "$out" | grep -q 'systemd-run' || fail "dry-run must invoke systemd-run, got: $out"
printf '%s\n' "$out" | grep -q -- '--user' || fail "dry-run must pass --user: $out"
printf '%s\n' "$out" | grep -q -- '--collect' || fail "dry-run must pass --collect: $out"
printf '%s\n' "$out" | grep -q -- '--no-block' || fail "dry-run must pass --no-block: $out"
printf '%s\n' "$out" | grep -q -- '--unit=issue26-shape' || fail "dry-run must pass --unit: $out"
printf '%s\n' "$out" | grep -qv 'nohup' || fail "dry-run must not mention nohup: $out"
ok "dry-run is systemd-run --user --collect --no-block"
printf '%s\n' "$out" | grep -q 'ExecStopPost=' || fail "dry-run must set ExecStopPost (fleet-ops#1204): $out"
printf '%s\n' "$out" | grep -q 'TimeoutStopSec=180' || fail "dry-run must set TimeoutStopSec=180: $out"
ok "dry-run wires ExecStopPost salvage"

# --- 2. --stdin becomes StandardInput=file: --------------------------------
pkt="$(mktemp)"
echo "packet" >"$pkt"
out="$("$bin" --dry-run --unit issue26-stdin --stdin "$pkt" -- /bin/true)"
rm -f "$pkt"
printf '%s\n' "$out" | grep -q 'StandardInput=file:' || fail "stdin must set StandardInput=file: $out"
ok "stdin maps to StandardInput=file:"

# --- 3. refuse nohup --------------------------------------------------------
set +e
err="$("$bin" --dry-run --unit x -- nohup sleep 1 2>&1)"
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "nohup must exit 2, got $rc ($err)"
printf '%s\n' "$err" | grep -qi 'nohup' || fail "refuse message must mention nohup: $err"
ok "nohup in command is refused"

# --- 4. already-active no-op (does not call systemd-run) --------------------
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
# $1 is --user
shift
case "$1" in
  is-active) echo active; exit 0 ;;
  show) echo 0; exit 0 ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
cat >"$fake/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "systemd-run was invoked: $*" >&2
exit 99
FAKE
chmod +x "$fake/systemctl" "$fake/systemd-run"
out="$(SYSTEMCTL="$fake/systemctl" SYSTEMD_RUN="$fake/systemd-run" \
    "$bin" --unit already-live -- /bin/true)"
printf '%s\n' "$out" | grep -q 'no-op' || fail "active unit must no-op, got: $out"
ok "already-active unit is a no-op"

# --- 5. routing docs name pi-systemd-run (fleet-ops#54, #255) --------------
# The old "call pi directly / there is no dispatch wrapper" sentence made
# `nohup pi ... &` the obvious background path. README and heartbeat already
# point here; the home/vault/codex routing docs must too. #54 listed three
# live files and missed ~/.codex/AGENTS.md; this list is the lock.
names_pi_systemd_run() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -q 'pi-systemd-run' "$f"
}

before="$repo_root/tests/fixtures/routing-docs/before-no-wrapper.md"
after="$repo_root/tests/fixtures/routing-docs/after-pi-systemd-run.md"
[[ -f "$before" && -f "$after" ]] || fail "missing routing-doc fixtures"
if names_pi_systemd_run "$before"; then
    fail "old 'no dispatch wrapper' wording must fail the check (got a match in $before)"
fi
names_pi_systemd_run "$after" || fail "required pi-systemd-run sentence must pass ($after)"
ok "fixture check rejects the old wording and accepts the required sentence"

names_pi_systemd_run "$repo_root/README.md" \
    || fail "README.md must name pi-systemd-run"
names_pi_systemd_run "$repo_root/prompts/heartbeat.md" \
    || fail "prompts/heartbeat.md must name pi-systemd-run"
grep -q 'never `nohup`' "$repo_root/prompts/heartbeat.md" \
    || fail "heartbeat.md must ban nohup in the spawn step"
ok "in-repo README and heartbeat name pi-systemd-run"

# Live copies agents actually read. GitHub runners do not have these files
# (HOME is /home/runner). On the VPS all four exist and this is the run.
live_docs=(
    /home/nish/AGENTS.md
    /home/nish/.claude/CLAUDE.md
    /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md
    /home/nish/.codex/AGENTS.md
)
live_checked=0
for f in "${live_docs[@]}"; do
    if [[ -f "$f" ]]; then
        names_pi_systemd_run "$f" || fail "$f must name pi-systemd-run so nohup is not the path of least resistance"
        live_checked=$((live_checked + 1))
    fi
done
expected="${#live_docs[@]}"
if [[ "$live_checked" -eq "$expected" ]]; then
    ok "live routing docs name pi-systemd-run ($live_checked files, including ~/.codex/AGENTS.md)"
elif [[ "$live_checked" -eq 0 ]]; then
    echo "SKIP: live routing docs not present (CI runner)"
else
    fail "expected 0 or ${expected} live routing docs, found $live_checked"
fi

# --- 6. live: survives a dying parent --------------------------------------
if ! systemctl --user is-system-running >/dev/null 2>&1 \
    && ! systemctl --user show -p Version >/dev/null 2>&1; then
    echo "SKIP: no user systemd (CI runner) — live survive-parent not run here"
else
    unit="issue26-survive-$$"
    # Parent starts the unit and exits. The child sleep must still be running.
    bash -c "$bin --unit $unit -- /bin/sleep 20"
    # Parent is gone. Give systemd a moment to register the unit.
    sleep 0.4
    state="$(systemctl --user is-active "${unit}.service" 2>/dev/null || true)"
    if [[ "$state" != "active" && "$state" != "activating" ]]; then
        systemctl --user status "${unit}.service" --no-pager >&2 || true
        fail "unit ${unit}.service should still be live after parent exit, state=$state"
    fi
    systemctl --user stop "${unit}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${unit}.service" >/dev/null 2>&1 || true
    ok "unit still live after launching parent exited (state=$state)"
fi

# fleet-ops#1204: nested so hosted CI runs salvage tests without a workflow edit
# (nishfleet-worker cannot push .github/workflows/**). Hermetic cases do not
# need user systemd; the nested file skips its own live SIGTERM drill.
bash "$here/pi-salvage-worktree.test.sh" || fail "pi-salvage-worktree tests failed"
