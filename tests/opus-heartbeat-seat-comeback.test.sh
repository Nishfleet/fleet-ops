#!/usr/bin/env bash
# tests/opus-heartbeat-seat-comeback.test.sh
#
# fleet-ops#2152: seat comeback arithmetic in opus-heartbeat-gather.
# Three bugs:
#   1. retry_after (a duration in seconds) was parsed as an epoch timestamp,
#      landing 1857600 on 1970-01-22, so retry_after_overdue was ALWAYS True.
#   2. .spawn-bench bench-marker files inflated walled_n and comeback_overdue_n.
#   3. test__test / test__test-model synthetic fixtures inflated the real
#      seat census.
#
# This test builds a synthetic seats dir with known fixtures and asserts:
#   - retry_after is treated as delta-seconds from observed_at, not an epoch.
#     A seat whose retry_after deadline is in the future must NOT be overdue.
#   - .spawn-bench files are excluded from walled_n and comeback_overdue_n.
#   - test__ fixtures (provider == "test") are excluded from the census.
#   - comeback_overdue_n reflects only genuinely stuck real seats.
#
# Sandbox: scratch SEATS_DIR with fixture files only. No live ledger touched.
#
# The gather script is a hand-placed Nish-ordered organ (machinery-allowlist
# class A, "watch during absence", until 2026-09-08) living at
# /home/nish/.local/libexec/opus-heartbeat-gather — NOT repo-tracked, same
# as the opus-heartbeat launcher/run/fallback siblings. This test exercises
# the INSTALLED gather, matching tests/opus-heartbeat-thorough-mode.test.sh
# and tests/opus-heartbeat-allowlist-gate.test.sh. Override via OPUS_HB_GATHER.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 missing"

TMPD="$(mktemp -d -t seat-comeback.XXXXXX)"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# --- synthetic fixtures ----------------------------------------------------
# NOW reference: we use fixed timestamps well outside the 21-day window so
# the test is stable regardless of when it runs.

# 1. Real walled seat with retry_after=1857600 (21.5-day DURATION) and a
#    usable_at 21.5 days in the FUTURE. Old code treated retry_after as
#    epoch 1857600 (1970) -> retry_after_overdue=True (spurious). New code
#    computes deadline = observed_at + retry_after -> Sept 19 -> overdue=False.
cat > "$SEATDIR/cline__cline-pass_deepseek-v4-flash.json" << 'EOF'
{"provider":"cline","model":"cline-pass/deepseek-v4-flash","http_status":402,"retry_after":1857600,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-28T19:23:38.684Z","source":"cli_spawn","failure_mode":"quota_exhausted","usable_at":"2026-09-19T07:23:38.684Z","consecutive_failure_count":21}
EOF

# 2. Real walled seat whose usable_at is in the PAST (genuinely stuck).
#    No retry_after. comeback_overdue=True via usable_at_overdue.
cat > "$SEATDIR/commandcode__minimax_minimax-m3-free.json" << 'EOF'
{"provider":"commandcode","model":"minimax/minimax-m3-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T01:17:02Z","source":"after_provider_response","failure_mode":"overload_503","usable_at":"2026-08-29T01:17:02Z","consecutive_failure_count":5}
EOF

# 3. .spawn-bench pseudo-seat (bench marker, NOT a real seat). Must be
#    excluded from walled_n and comeback_overdue_n. Has usable_at in the
#    past, health_class=unknown, observed_at=null.
cat > "$SEATDIR/commandcode__minimax_minimax-m3-free.spawn-bench.json" << 'EOF'
{"provider":"commandcode","model":"minimax/minimax-m3-free","usable_at":"2026-08-29T16:36:06Z","reason":"no_block:rc=0","written_at":"2026-08-29T16:31:06Z","backoff_s":300}
EOF

# 4. test__test synthetic fixture (provider == "test"). Must be excluded.
cat > "$SEATDIR/test__test.json" << 'EOF'
{"provider":"test","model":"test","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-29T03:43:09.561Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-29T03:58:09.561Z","consecutive_failure_count":2}
EOF

# 5. Healthy seat — should appear in seat_table but NOT in walled_comebacks.
cat > "$SEATDIR/healthy__model.json" << 'EOF'
{"provider":"healthy","model":"model","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T01:52:16.557Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF

# 6. Real walled seat with retry_after=60 (1 min) and observed_at 2 hours ago.
#    Deadline = observed + 60s = 2h+1min ago -> retry_after_overdue=True.
cat > "$SEATDIR/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":60,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-28T01:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-28T01:01:00Z","consecutive_failure_count":1}
EOF

# --- Run gather in THOROUGH mode with scratch SEATS_DIR ------------------
# PROM_URL to dead port so promql degrades gracefully (defensive gather).
# OPUS_HB_THOROUGH=1 so the thorough battery (incl. seat_probes_walled_comebacks)
# is included in the snapshot.
OPUS_HB_STATE="$TMPD" OPUS_HB_THOROUGH=1 SEATS_DIR="$SEATDIR" PROM_URL="http://127.0.0.1:9" \
  python3 "$GATHER" >"$TMPD/snapshot.json" 2>"$TMPD/gather.err" \
  || fail "gather failed rc=$? (stderr: $(cat "$TMPD/gather.err"))"

python3 - "$TMPD/snapshot.json" <<'PY' || fail "test assertion failed"
import json, sys

snap = json.load(open(sys.argv[1]))

# --- seat_table assertions ---
seats = snap.get("seats") or {}
assert seats.get("present") is True, "seats table must be present"
# 6 fixture files total, 2 excluded (1 spawn-bench + 1 test__), 1 healthy
# -> n = 4 real seats, healthy_n = 1, walled_n = 3, excluded_n = 2
assert seats.get("n") == 4, f"seat n must be 4 (6 fixtures - 2 excluded), got {seats.get('n')}"
assert seats.get("healthy_n") == 1, f"healthy_n must be 1, got {seats.get('healthy_n')}"
assert seats.get("walled_n") == 3, f"walled_n must be 3, got {seats.get('walled_n')}"
assert seats.get("excluded_n") == 2, f"excluded_n must be 2, got {seats.get('excluded_n')}"
ids = [r["id"] for r in seats.get("seats", [])]
assert "healthy__model" in ids, f"healthy seat missing from table: {ids}"
assert not any("spawn-bench" in i for i in ids), f"spawn-bench leaked into seat table: {ids}"
assert not any(i.startswith("test__") for i in ids), f"test__ fixture leaked into seat table: {ids}"
print("OK: seat_table excludes spawn-bench and test__ fixtures")

# --- t_seat_probes_walled_comebacks assertions (thorough) ---
thorough = snap.get("thorough")
assert thorough is not None, "thorough snapshot missing (run with OPUS_HB_THOROUGH=1)"
cb = thorough.get("slots", {}).get("seat_probes_walled_comebacks", {})
assert cb.get("present") is True, "walled_comebacks slot must be present"
assert cb.get("walled_n") == 3, f"walled_comebacks walled_n must be 3, got {cb.get('walled_n')}"
assert cb.get("excluded_n") == 2, f"excluded_n must be 2, got {cb.get('excluded_n')}"

# comeback_overdue: only seat #2 (usable_at in past) and seat #6 (retry_after
# deadline in past) should be overdue. Seat #1 (retry_after=1857600, deadline
# Sept 19) must NOT be overdue.
assert cb.get("comeback_overdue_n") == 2, (
    f"comeback_overdue_n must be 2 (only genuinely stuck seats), "
    f"got {cb.get('comeback_overdue_n')}"
)

walled = cb.get("walled", [])
# Find the cline seat (the one with retry_after=1857600)
cline = [r for r in walled if "cline-pass_deepseek" in r.get("id", "")]
assert len(cline) == 1, f"cline seat not found in walled list"
cline = cline[0]
assert cline.get("retry_after") == 1857600, f"cline retry_after mismatch: {cline.get('retry_after')}"
# The fix: retry_after_epoch must be observed_at_epoch + retry_after (NOT 1857600
# as an epoch). observed_at=2026-08-28T19:23:38.684Z + 1857600s = 2026-09-19T07:23:38.684Z
import datetime
obs = datetime.datetime.fromisoformat("2026-08-28T19:23:38.684000+00:00")
obs_epoch = obs.timestamp()
expected_deadline = int(obs_epoch + 1857600)
assert cline.get("retry_after_epoch") == expected_deadline, (
    f"retry_after_epoch must be observed_at_epoch + retry_after ({expected_deadline}), "
    f"got {cline.get('retry_after_epoch')}"
)
assert cline.get("retry_after_overdue") is False, (
    f"cline seat retry_after_overdue must be False (deadline in future), "
    f"got {cline.get('retry_after_overdue')}"
)
assert cline.get("usable_at_overdue") is False, (
    f"cline seat usable_at_overdue must be False (usable_at Sept 19 in future), "
    f"got {cline.get('usable_at_overdue')}"
)
print("OK: retry_after treated as delta-seconds from observed_at, not epoch")

# Find the commandcode seat (usable_at in past -> overdue)
cmdcode = [r for r in walled if "commandcode__minimax" in r.get("id", "") and "spawn-bench" not in r.get("id", "")]
assert len(cmdcode) == 1, f"commandcode seat not found: {[r.get('id') for r in walled]}"
cmdcode = cmdcode[0]
assert cmdcode.get("usable_at_overdue") is True, "commandcode usable_at must be overdue (past)"
print("OK: genuinely-stuck seat (past usable_at) flagged overdue")

# Find the opencode seat (retry_after=60, observed 2h ago -> deadline in past)
opencode = [r for r in walled if "opencode__mimo" in r.get("id", "")]
assert len(opencode) == 1, f"opencode seat not found: {[r.get('id') for r in walled]}"
opencode = opencode[0]
assert opencode.get("retry_after") == 60, f"opencode retry_after mismatch: {opencode.get('retry_after')}"
assert opencode.get("retry_after_overdue") is True, (
    f"opencode retry_after_overdue must be True (deadline in past)"
)
print("OK: retry_after deadline in past flagged overdue")

print("ALL OK: seat comeback arithmetic fixed (fleet-ops#2152)")
PY
