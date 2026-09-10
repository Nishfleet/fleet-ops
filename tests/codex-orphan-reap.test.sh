#!/usr/bin/env bash
# tests/codex-orphan-reap.test.sh
#
# Proves the safety gate and detection in bin/codex-orphan-reap. Runs in
# CI without a real Codex install: stubs lsof/codex/systemctl via PATH
# and uses a real backgrounded sleep as the fake listener so `kill -0`
# succeeds. The live reap+restart+round-trip is owned by the weekly
# window (ExecStartPre on vps-weekly-update.service).
#
# Invariants (every one is a load-bearing rule from fleet-ops#78):
#   1. No orphan listener → exit 0 (idempotent no-op; must not fail the
#      weekly-update ExecStartPre).
#   2. Unmanaged listener + no maint flag + 0 peers + --dry-run → exit 0.
#   3. Unmanaged listener + maint=paused|quiescing + 2 peers → exit 0
#      (--dry-run; the window is in the kill phase).
#   4. Unmanaged listener + no maint flag + 2 peers → REFUSED, exit 10.
#      Never reap outside the window while connections live.
#   5. --force never overrides an active peer count (still exit 10).
#   6. Peer counting: 3 CONNECTED lines sharing 2 NODE ids + 1 LISTEN
#      → 2 peers (socketpairs are one peer, LISTEN is not a peer).
#   7. --dry-run never kills the listener.
#   8. Already-managed listener (pid file matches) + 2 peers + no maint
#      → exit 0, listener still alive. Next week's window must not
#      kill the healthy daemon.
#   9. Drop-in + MANIFEST wiring for the weekly window.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/codex-orphan-reap"
[ -x "$bin" ] || { echo "FAIL: $bin not executable"; exit 2; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t codex-orphan-reap.XXXXXX)"
export HOME="$scratch"
sleep_pid=""
sock_pid=""
cleanup() { kill "$sleep_pid" "$sock_pid" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

mkdir -p "$scratch/.codex/app-server-control" "$scratch/.codex/app-server-daemon"
fake_sock="$scratch/.codex/app-server-control/app-server-control.sock"
export FAKE_SOCK="$fake_sock"
python3 -c '
import os, socket, select
p = os.environ["FAKE_SOCK"]
if os.path.exists(p): os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.listen(8)
while True:
    select.select([s], [], [])
    c, _ = s.accept()
    c.close()
' &
sock_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$fake_sock" ] && break
    sleep 0.1
done
[ -S "$fake_sock" ] || { echo "FAIL: fake socket did not bind"; exit 2; }

sleep 60 &
sleep_pid=$!

stub_dir="$scratch/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/lsof" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -t)
        [ -n "${LSOF_LISTENER:-}" ] && printf '%s\n' "$LSOF_LISTENER"
        ;;
    -a)
        [ -n "${LSOF_PEERS:-}" ] && printf '%s\n' "$LSOF_PEERS"
        ;;
esac
exit 0
STUB
chmod +x "$stub_dir/lsof"

cat >"$stub_dir/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_dir/codex"

export PATH="$stub_dir:$PATH"
export LSOF_LISTENER="$sleep_pid"

write_maint_flag() {
    local status="$1"
    local flag="$scratch/maintenance.json"
    if [ -n "$status" ]; then
        printf '{"status":"%s","host":"test","opened_at":"2026-08-26T00:00:00+05:30","expected_clear_at":"2026-08-26T03:30:00+05:30","reason":"test"}' "$status" > "$flag"
    else
        rm -f "$flag"
    fi
    export CODEX_MAINT_FLAG="$flag"
}

write_daemon_pid() {
    local pid="$1"
    local f="$scratch/.codex/app-server-daemon/app-server.pid"
    if [ -n "$pid" ]; then
        printf '{"pid":%s,"processStartTime":"test"}' "$pid" > "$f"
    else
        rm -f "$f"
    fi
}

run_bin() {
    export CODEX_ORPHAN_REAP_LOG_DIR="$scratch/logs"
    mkdir -p "$CODEX_ORPHAN_REAP_LOG_DIR"
    set +e
    "$bin" "$@"
    rc=$?
    set -e
    printf '%d' "$rc"
}

# 3 CONNECTED lines, 2 unique NODE ids, 1 LISTEN. Matches the live
# orphan on 2026-08-26 (fds 7+9 share a NODE; fd 8 is the other peer).
PEERS_NONE=""
PEERS_TWO=$(printf 'codex  %s  nish  7u  unix  0x0  0t0  644743646  type=STREAM (CONNECTED)\ncodex  %s  nish  8u  unix  0x0  0t0  644743647  type=STREAM (CONNECTED)\ncodex  %s  nish  9u  unix  0x0  0t0  644743646  type=STREAM (CONNECTED)\ncodex  %s  nish  28u  unix  0x0  0t0  644744617  /sock  type=STREAM (LISTEN)\n' \
    "$sleep_pid" "$sleep_pid" "$sleep_pid" "$sleep_pid")

# --- invariant 6: peer counting ------------------------------------------
count=$(printf '%s\n' "$PEERS_TWO" | awk '
    /STREAM/ && /CONNECTED/ && !/LISTEN/ { nodes[$8] = 1 }
    END { print length(nodes) + 0 }
')
[ "$count" = "2" ] || fail "peer counting fixture: expected 2 unique NODEs, got $count"
ok "invariant 6: 3 CONNECTED lines / 2 NODE ids → 2 peers"

# --- invariant 1: no listener --------------------------------------------
export LSOF_LISTENER=""
export LSOF_PEERS=""
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "no listener: expected exit 0, got $rc"
ok "invariant 1: no orphan listener → exit 0 (idempotent)"

# --- invariant 2: --dry-run + 0 peers + no maint → exit 0 ---------------
export LSOF_LISTENER="$sleep_pid"
export LSOF_PEERS="$PEERS_NONE"
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "no maint + 0 peers + --dry-run: expected exit 0, got $rc"
grep -q "ALLOWED: no active peers" "$scratch/logs/last-run.log" \
    || fail "no maint + 0 peers: missing ALLOWED log line"
ok "invariant 2: no maint + 0 peers → exit 0 (--dry-run)"

# --- invariant 3: maint=paused + 2 peers → exit 0 -----------------------
export LSOF_PEERS="$PEERS_TWO"
write_maint_flag "paused"
write_daemon_pid ""
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "maint=paused + 2 peers: expected exit 0, got $rc"
grep -q "ALLOWED: maintenance flag=paused" "$scratch/logs/last-run.log" \
    || fail "maint=paused: missing ALLOWED log line"
ok "invariant 3: maint=paused + 2 peers → exit 0 (kill phase allows)"

write_maint_flag "quiescing"
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "maint=quiescing + 2 peers: expected exit 0, got $rc"
ok "invariant 3b: maint=quiescing + 2 peers → exit 0 (kill phase allows)"

# --- invariant 4: no maint + 2 peers → REFUSED, exit 10 -----------------
export LSOF_PEERS="$PEERS_TWO"
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin)
[ "$rc" = "10" ] || fail "no maint + 2 peers: expected exit 10, got $rc"
grep -q "REFUSED: maintenance=clear peers=2" "$scratch/logs/last-run.log" \
    || fail "no maint + 2 peers: missing REFUSED log line"
grep -q "do NOT reap the orphan outside the maintenance window" "$scratch/logs/last-run.log" \
    || fail "no maint + 2 peers: missing human-readable hint"
ok "invariant 4: no maint + 2 peers → exit 10 (the load-bearing gate)"

# --- invariant 5: --force + no maint + 2 peers → still REFUSED, 10 -----
export LSOF_PEERS="$PEERS_TWO"
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin --force)
[ "$rc" = "10" ] || fail "--force + no maint + 2 peers: expected exit 10, got $rc"
grep -q "refuse to sever" "$scratch/logs/last-run.log" \
    || fail "--force + active peers: missing refuse-to-sever log line"
ok "invariant 5: --force never overrides an active peer count"

export LSOF_PEERS="$PEERS_NONE"
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin --force --dry-run)
[ "$rc" = "0" ] || fail "--force + 0 peers: expected exit 0, got $rc"
grep -q "ALLOWED:" "$scratch/logs/last-run.log" \
    || fail "--force + 0 peers: missing ALLOWED log line"
ok "invariant 5b: --force + 0 peers → exit 0 (0 peers is already allowed)"

# --- invariant 7: --dry-run never reaps ---------------------------------
export LSOF_PEERS="$PEERS_NONE"
write_maint_flag ""
write_daemon_pid ""
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "dry-run no reap: expected exit 0, got $rc"
if ! kill -0 "$sleep_pid" 2>/dev/null; then
    fail "dry-run killed the listener (should not have)"
fi
grep -q "dry-run: would reap" "$scratch/logs/last-run.log" \
    || fail "dry-run: missing would-reap line"
ok "invariant 7: --dry-run never reaps; listener still alive after"

# --- invariant 8: already-managed is never reaped -----------------------
export LSOF_PEERS="$PEERS_TWO"
write_maint_flag ""
write_daemon_pid "$sleep_pid"
rc=$(run_bin)
[ "$rc" = "0" ] || fail "already-managed + 2 peers: expected exit 0, got $rc"
if ! kill -0 "$sleep_pid" 2>/dev/null; then
    fail "already-managed path killed the listener"
fi
grep -q "listener is managed by daemon pid=$sleep_pid" "$scratch/logs/last-run.log" \
    || fail "already-managed: missing managed log line"
ok "invariant 8: already-managed + 2 peers + no maint → exit 0, not killed"

# Even during the window, a managed daemon must not be reaped.
write_maint_flag "paused"
rc=$(run_bin --dry-run)
[ "$rc" = "0" ] || fail "already-managed + paused: expected exit 0, got $rc"
grep -q "listener is managed by daemon pid=$sleep_pid" "$scratch/logs/last-run.log" \
    || fail "already-managed + paused: missing managed log line"
ok "invariant 8b: already-managed during the window → no-op, not reaped"

# --- invariant 9: weekly-window wiring ----------------------------------
dropin="$repo_root/systemd/vps-weekly-update.service.d/10-codex-orphan-reap.conf"
manifest="$repo_root/MANIFEST"
[ -f "$dropin" ] || fail "missing drop-in: $dropin"
grep -q '^ExecStartPre=-/home/nish/.local/bin/codex-orphan-reap$' "$dropin" \
    || fail "drop-in must ExecStartPre=- the reap binary (leading '-' so a failed reap cannot skip apt)"
bin_line="bin/codex-orphan-reap /home/nish/.local/bin/codex-orphan-reap"
drop_line="systemd/vps-weekly-update.service.d/10-codex-orphan-reap.conf /home/nish/.config/systemd/user/vps-weekly-update.service.d/10-codex-orphan-reap.conf"
grep -Fxq "$bin_line" "$manifest" || fail "MANIFEST missing: $bin_line"
grep -Fxq "$drop_line" "$manifest" || fail "MANIFEST missing: $drop_line"
ok "invariant 9: drop-in ExecStartPre=- and MANIFEST entries are locked"

echo "OK: codex-orphan-reap safety gate, managed-skip, and window wiring are locked"
