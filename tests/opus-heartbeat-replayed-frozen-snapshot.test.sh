#!/usr/bin/env bash
# tests/opus-heartbeat-replayed-frozen-snapshot.test.sh
#
# fleet-ops#1453 acceptance: "Prove with one replayed frozen-queue
# snapshot". This test replays the live #1453 moment (a snapshot that
# DID prove the queue frozen — dispatches_last_2h <= 1 AND ready_work
# > 50 — at the exact same heartbeat tick where Opus tried the narrow
# repair-dispatch lever) and asserts the launcher would have ALLOWED
# the line where the live run SKIPped it.
#
# The live run at 2026-08-28T03:30:43Z SKIPped the line because the
# snapshot in /home/nish/.local/state/opus-heartbeat/snapshot.json at
# that tick had dispatches_last_2h=1 AND ready_work=224 — the gate
# (with the new defaults OPUS_HB_FROZEN_DISPATCHES=1,
# OPUS_HB_FROZEN_READY=50) would have ALLOWED it. That is the proof:
# the lever exists, fires exactly when the queue cannot be trusted,
# and stays forbidden otherwise (companion test 2 proves the inverse).
#
# This test is the "replayed frozen-queue snapshot" proof; it does not
# invoke Opus (that needs an auth token) — it drives the launcher via
# the --check-allowlist subcommand introduced by this PR.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LAUNCHER="${OPUS_HB_LAUNCHER:-/home/nish/.local/libexec/opus-heartbeat}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$LAUNCHER" ]] || fail "launcher not executable: $LAUNCHER"
[[ -s "$SNAP_LIVE" ]] || fail "live snapshot missing at $SNAP_LIVE — heartbeat gather has not run yet?"

# The live #1453 line: pi-systemd-run --unit repair-chain-verify ...
LIVE_LINE='pi-systemd-run --unit repair-chain-verify --stdin /tmp/repair-chain-verify.md -- pi --print --provider straitly --model deepseek/deepseek-v4-pro'

# Sanity: the live snapshot must exist. We do NOT overwrite it — we
# read it, mutate the copy in memory, write the mutated copy to a
# scratch dir, point OPUS_HB_STATE at the scratch dir, and exercise the
# gate. The live snapshot is restored by the test runner's trap.
SCRATCH="$(mktemp -d -t opus-1453-replay.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
cp -f "$SNAP_LIVE" "$SCRATCH/snapshot.json"

# Replay the live tick's frozen-queue state: the snapshot at the
# 03:30Z tick had dispatches_last_2h=1 and ready_work=224. With the new
# gate defaults (`<= 1` and `> 50`) that satisfies the frozen trigger.
# We mutate the copy to make it crystal-clear that the proof is on the
# replayed state, not on the (possibly drifted) live state.
python3 - "$SCRATCH/snapshot.json" <<'PY'
import json, sys, os
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    snap = json.load(fh)
snap["fleet"]["ready_work"] = 224.0
snap["waste"]["dispatches_last_2h"] = 1
snap["waste"]["claims_last_2h"] = 1
snap["waste"]["redispatches_last_2h"] = 0
snap["waste"]["empty_runs_last_2h"] = 2
snap["claims_last_2h"] = {"present": True, "n": 1, "samples": []}
# Mark the snapshot epoch as the live #1453 tick for traceability.
snap["epoch"] = 1756355442  # 2026-08-28T03:30:42Z, the live tick
snap["ts"]    = "2026-08-28T03:30:42Z"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(snap, fh, separators=(",", ":"), default=str)
PY

# Drive the launcher against the replayed snapshot. Exit 0 = ALLOW,
# which is the proof: under the frozen trigger, the same line that was
# SKIPped live would now fire.
out="$(OPUS_HB_STATE="$SCRATCH" "$LAUNCHER" --check-allowlist "$LIVE_LINE" 2>&1)" \
  || fail "expected ALLOW (rc=0) on replayed frozen-queue snapshot, got rc=$?: $out"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "expected 'ALLOW queue_frozen=1' prefix on replayed frozen snapshot, got: $out" ;;
esac
echo "Replay transcript:"
echo "  snapshot : $SCRATCH/snapshot.json (dispatches=1, ready=224 — live #1453 tick)"
echo "  line     : $LIVE_LINE"
echo "  launcher : $LAUNCHER"
echo "  output   : $out"
ok "replayed live #1453 frozen-queue snapshot ALLOWS the dispatch (proof)"

# Negative control: flip the snapshot just outside the frozen boundary
# (dispatches=2) — the same line MUST SKIP. This pins the gate's
# exclusivity: the lever only fires when the trigger holds, never on
# the cusp of recovery.
python3 - "$SCRATCH/snapshot.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    snap = json.load(fh)
snap["waste"]["dispatches_last_2h"] = 2  # one above the threshold
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(snap, fh, separators=(",", ":"), default=str)
PY
set +e
out="$(OPUS_HB_STATE="$SCRATCH" "$LAUNCHER" --check-allowlist "$LIVE_LINE" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "negative control: expected rc=1 with dispatches=2, got rc=$rc: $out"
case "$out" in
  SKIP-QUEUE-NOT-FROZEN*) : ;;
  *) fail "negative control: expected SKIP-QUEUE-NOT-FROZEN, got: $out" ;;
esac
ok "negative control: same line at dispatches=2 SKIP-QUEUE-NOT-FROZEN (gate stays shut)"

exit 0
