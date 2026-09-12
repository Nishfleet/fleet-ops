#!/usr/bin/env bash
# tests/pi-issue-run-journal-instrumentation.test.sh
#
# fleet-ops#4903: pi-issue-run must write a phase=start line at entry and a
# phase=exit line at every exit path to the journal (via systemd-cat), so a
# <60s death is attributable from `journalctl -t pi-issue-run`. Also verifies
# the two exit-0 fixes:
#   (a) infra death (mid-session provider death) exits 0, not 1 — re-queues
#       via intake (ExecStopPost), not Restart=.
#   (b) a run that shipped a PR but pi exited non-zero exits 0 — the PR is
#       already open, the failure chain fires for nothing.
#
# Runs entirely offline: stubbed models.json, seat-caps.json, ledger dir,
# a fake pi, a fake systemd-cat, and PI_ISSUES_DIR redirected into scratch.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-journal.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14: stub a working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Stub systemd-cat: capture stdin to a file so the test can assert phase= lines.
cat >"$stub_bin/systemd-cat" <<'STUB'
#!/usr/bin/env bash
# Capture: --identifier=foo --priority=info, then stdin is the message.
cat >>"${SYSTEMD_CAT_CAPTURE:-/dev/null}"
STUB
chmod +x "$stub_bin/systemd-cat"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "cursor": {
      "models": [
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    },
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "cursor": { "cap": 1, "class": "subscription", "models": { "cursor-grok-4.6-high": 1 } },
    "devin": { "cap": 4, "class": "subscription", "models": { "swe-1-7": 4 } }
  }
}
JSON

# Use the real seatlib so pick-seat / mark_seat_spawn_fail work.
export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"
export FLEET_DEBUG_PLAYBOOK_GATE=0
export FLEET_DEBUG_PLAYBOOK_SESSION_DIR="$scratch/sessions"

# --- case 1: journal instrumentation on a mid-session infra death (exit 0) ---
inst="0509-4903a"
mkdir -p "$FLEET_DEBUG_PLAYBOOK_SESSION_DIR"
{
  printf 'difficulty: keystone\n'
  printf 'Implement one GitHub issue: Nishfleet/0509#4903 case A.\n'
} >"$ISSUES_DIR/${inst}.in"

# Fake pi: exit 1 with the cursor mid-session-death marker in stderr.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
echo "Cursor exited with code 143: " >&2
sleep 0.2
exit 1
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

export SYSTEMD_CAT_CAPTURE="$scratch/journal-A.log"
set +e
bash "$bin" "$inst" >"$scratch/runA.out" 2>"$scratch/runA.err"
rcA=$?
set -e

# (a) infra death must exit 0 (re-queue via intake, not Restart=).
[[ "$rcA" == "0" ]] \
  || fail "case A: mid-session infra death must exit 0, got rc=$rcA err=$(cat "$scratch/runA.err")"

# (b) journal must have phase=start and phase=exit lines.
[[ -f "$scratch/journal-A.log" ]] || fail "case A: systemd-cat captured nothing"
grep -q "phase=start" "$scratch/journal-A.log" \
  || fail "case A: journal missing phase=start: $(cat "$scratch/journal-A.log")"
grep -q "phase=exit" "$scratch/journal-A.log" \
  || fail "case A: journal missing phase=exit: $(cat "$scratch/journal-A.log")"
grep -q "phase=exit rc=0" "$scratch/journal-A.log" \
  || fail "case A: phase=exit must show rc=0: $(cat "$scratch/journal-A.log")"
grep -q "reason=infra-death-requeue" "$scratch/journal-A.log" \
  || fail "case A: phase=exit must show reason=infra-death-requeue: $(cat "$scratch/journal-A.log")"
ok "case A: mid-session infra death exits 0 with journal phase=start/exit rc=0 reason=infra-death-requeue"

# --- case 2: PR shipped + pi exit non-zero -> exit 0 (success) ----------------
inst="0509-4903b"
# Clear case A's bench so pick-seat re-offers the seat.
rm -f "$LEDGER"/*.json "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
{
  printf 'Implement one GitHub issue: Nishfleet/0509#4903 case B.\n'
} >"$ISSUES_DIR/${inst}.in"

# Fake pi: exit 1 with a generic error (NOT a mid-session death — no 143 /
# SIGTERM / Killed keywords) but write a PR URL to stdout (the PR was created
# before pi exited non-zero for a non-infra reason).
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
echo "https://github.com/Nishfleet/0509/pull/9999"
echo "simulated pi failure: boom" >&2
exit 1
STUB
chmod +x "$stub_bin/pi"

export SYSTEMD_CAT_CAPTURE="$scratch/journal-B.log"
set +e
bash "$bin" "$inst" >"$scratch/runB.out" 2>"$scratch/runB.err"
rcB=$?
set -e

# (a) PR shipped + pi non-zero must exit 0 (success, no failure chain).
[[ "$rcB" == "0" ]] \
  || fail "case B: PR shipped + pi non-zero must exit 0, got rc=$rcB err=$(cat "$scratch/runB.err")"

# (b) journal must have phase=start and phase=exit with reason=success-pr-shipped.
[[ -f "$scratch/journal-B.log" ]] || fail "case B: systemd-cat captured nothing"
grep -q "phase=start" "$scratch/journal-B.log" \
  || fail "case B: journal missing phase=start: $(cat "$scratch/journal-B.log")"
grep -q "phase=exit rc=0" "$scratch/journal-B.log" \
  || fail "case B: phase=exit must show rc=0: $(cat "$scratch/journal-B.log")"
grep -q "reason=success-pr-shipped" "$scratch/journal-B.log" \
  || fail "case B: phase=exit must show reason=success-pr-shipped: $(cat "$scratch/journal-B.log")"
ok "case B: PR shipped + pi non-zero exits 0 with journal reason=success-pr-shipped"

# --- case 3: generic pi failure (not infra, no PR) -> exit 1 with reason ------
inst="0509-4903c"
rm -f "$LEDGER"/*.json "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
{
  printf 'Implement one GitHub issue: Nishfleet/0509#4903 case C.\n'
} >"$ISSUES_DIR/${inst}.in"

# Fake pi: exit 1 with a generic error (no infra keywords, no PR URL).
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
echo "simulated pi failure: boom" >&2
exit 1
STUB
chmod +x "$stub_bin/pi"

export SYSTEMD_CAT_CAPTURE="$scratch/journal-C.log"
set +e
bash "$bin" "$inst" >"$scratch/runC.out" 2>"$scratch/runC.err"
rcC=$?
set -e

# (a) generic failure must still exit 1 (work failure, not infra).
[[ "$rcC" == "1" ]] \
  || fail "case C: generic pi failure must exit 1, got rc=$rcC err=$(cat "$scratch/runC.err")"

# (b) journal must have phase=exit rc=1 with a reason.
[[ -f "$scratch/journal-C.log" ]] || fail "case C: systemd-cat captured nothing"
grep -q "phase=start" "$scratch/journal-C.log" \
  || fail "case C: journal missing phase=start: $(cat "$scratch/journal-C.log")"
grep -q "phase=exit rc=1" "$scratch/journal-C.log" \
  || fail "case C: phase=exit must show rc=1: $(cat "$scratch/journal-C.log")"
grep -qE "reason=pi-failed|reason=" "$scratch/journal-C.log" \
  || fail "case C: phase=exit must show a reason: $(cat "$scratch/journal-C.log")"
ok "case C: generic pi failure exits 1 with journal phase=exit rc=1 reason=pi-failed"

echo "PASS: pi-issue-run-journal-instrumentation"
