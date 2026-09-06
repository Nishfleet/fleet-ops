#!/usr/bin/env bash
# tests/opus-heartbeat-corpse-exclusion.test.sh
#
# fleet-ops#3983: cap=0 intentional_cap_zero=corpse seats must be excluded
# from the opus-heartbeat-gather seat census so the duty officer does not
# re-file issues about already-retired seats every tick.
#
# Root cause: the gather's seat_table() included ALL seat ledgers in the
# census, including cap=0 intentional_cap_zero=corpse rows that are never
# picked (pick_seat skips cap=0 models). The duty officer saw a dead seat
# every tick and filed a `gh issue create` for it. The repair pipeline
# re-verified the corpse and closed the issue, then the next tick the duty
# officer filed a new one — 8 duplicate MiniMax corpse PRs in 7 days,
# 35.6% of self-maintenance merges, keeping FleetQueueSelfMaintenanceRatioHigh
# firing above the 0.64 threshold.
#
# The metric exporter (libexec/fleet-metrics-export.py _read_dead_credentials)
# already excluded cap=0 rows from fleet_pi_seat_dead_credential_total. The
# gather now mirrors that exclusion: _is_excluded_seat() checks
# seat-caps.json for cap=0 intentional_cap_zero=corpse rows and excludes
# their ledgers from the census.
#
# This test builds a synthetic seats dir with:
#   - A cap=0 intentional_cap_zero=corpse seat (must be EXCLUDED).
#   - A cap>0 seat with a stale corpse_retirement ledger (must be INCLUDED —
#     a cap>0 seat with a dead ledger is a real inconsistency the duty
#     officer should see).
#   - A cap=0 intentional_cap_zero=stale seat (must be INCLUDED — stale
#     rows may still need visibility, only corpse rows are excluded).
#   - A healthy cap>0 seat (must be INCLUDED).
#
# Sandbox: scratch SEATS_DIR + scratch SEAT_CAPS_JSON. No live ledger touched.
#
# The gather script is a hand-placed Nish-ordered organ living at
# /home/nish/.local/libexec/opus-heartbeat-gather — NOT repo-tracked, same
# as the opus-heartbeat launcher/run/fallback siblings. This test exercises
# the INSTALLED gather, matching tests/opus-heartbeat-seat-comeback.test.sh.
# Override via OPUS_HB_GATHER.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 missing"

TMPD="$(mktemp -d -t corpse-excl.XXXXXX)"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# --- synthetic seat-caps.json -------------------------------------------
# fleet-ops#3983: the gather reads seat-caps.json to identify cap=0
# intentional_cap_zero=corpse rows. Only corpse rows are excluded; stale
# rows remain visible.
cat > "$TMPD/seat-caps.json" << 'EOF'
{
  "providers": {
    "commandcode": {
      "cap": 4,
      "class": "free",
      "models": {
        "minimax/minimax-m3-free": {
          "cap": 0,
          "intentional_cap_zero": "corpse",
          "reason": "2026-09-02: HTTP 403 FORBIDDEN 'The free MiniMax M3 and M2.7 models have been retired'"
        },
        "deepseek/deepseek-v4-flash": 2
      }
    },
    "opencode": {
      "cap": 4,
      "class": "free",
      "models": {
        "hy3-free": {
          "cap": 0,
          "intentional_cap_zero": "stale",
          "reason": "2026-09-04: model hy3-free is not supported"
        },
        "muse-spark-1.2-contributor-free": 2
      }
    },
    "hetzner": {
      "cap": 1,
      "class": "free",
      "models": {
        "Qwen/Qwen3.6-35B-A3B-FP8": 1
      }
    },
    "healthy": {
      "cap": 2,
      "class": "free",
      "models": {
        "good-model": 2
      }
    }
  }
}
EOF

# --- synthetic seat ledgers ---------------------------------------------

# 1. cap=0 intentional_cap_zero=corpse seat with a parked corpse ledger.
#    This is the fleet-ops#3983 generator: the duty officer saw this dead
#    seat every tick and filed a duplicate issue. Must be EXCLUDED.
cat > "$SEATDIR/commandcode__minimax_minimax-m3-free.json" << 'EOF'
{"provider":"commandcode","model":"minimax/minimax-m3-free","http_status":null,"retry_after":null,"health_class":"parked","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-09-06T15:15:47Z","source":"corpse_retirement","failure_mode":"corpse_retired","last_error_class":"corpse_retired","bench_reason":"corpse-retired: cap=0 corpse bench, pick_seat never offers (durable, fleet-ops#2716/#3669)","bench_until":"2036-09-03T15:15:47Z","usable_at":"2036-09-03T15:15:47Z","consecutive_failure_count":0,"writer":"write_parked_ledger"}
EOF

# 2. cap>0 seat with a stale corpse_retirement ledger (hetzner). This is a
#    real inconsistency: config says enrolled (cap=1) but the ledger says
#    dead corpse. The duty officer SHOULD see this. Must be INCLUDED.
cat > "$SEATDIR/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" << 'EOF'
{"provider":"hetzner","model":"Qwen/Qwen3.6-35B-A3B-FP8","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-09-04T16:37:23Z","source":"corpse_retirement","failure_mode":"corpse_retired","usable_at":null,"consecutive_failure_count":0}
EOF

# 3. cap=0 intentional_cap_zero=stale seat with a dead ledger (opencode/hy3-free).
#    Stale rows are NOT excluded — they may still need visibility. Must be INCLUDED.
cat > "$SEATDIR/opencode__hy3-free.json" << 'EOF'
{"provider":"opencode","model":"hy3-free","http_status":401,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-09-04T16:30:00Z","source":"seat_health_extension","failure_mode":"credentials_bad","usable_at":null,"consecutive_failure_count":10}
EOF

# 4. Healthy cap>0 seat. Must be INCLUDED.
cat > "$SEATDIR/healthy__good-model.json" << 'EOF'
{"provider":"healthy","model":"good-model","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-09-06T15:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF

# --- Run gather with scratch SEATS_DIR + scratch SEAT_CAPS_JSON ----------
OPUS_HB_STATE="$TMPD" SEATS_DIR="$SEATDIR" \
  SEAT_CAPS_JSON="$TMPD/seat-caps.json" PROM_URL="http://127.0.0.1:9" \
  python3 "$GATHER" >"$TMPD/snapshot.json" 2>"$TMPD/gather.err" \
  || fail "gather failed rc=$? (stderr: $(cat "$TMPD/gather.err"))"

python3 - "$TMPD/snapshot.json" <<'PY' || fail "test assertion failed"
import json, sys

snap = json.load(open(sys.argv[1]))
seats = snap.get("seats") or {}
assert seats.get("present") is True, "seats table must be present"

ids = [r["id"] for r in seats.get("seats", [])]

# fleet-ops#3983: the cap=0 intentional_cap_zero=corpse seat must be EXCLUDED.
assert "commandcode__minimax_minimax-m3-free" not in ids, \
    "cap=0 intentional_cap_zero=corpse seat must be excluded from census (fleet-ops#3983)"

# cap>0 seat with stale corpse_retirement ledger must be INCLUDED.
assert "hetzner__Qwen_Qwen3.6-35B-A3B-FP8" in ids, \
    "cap>0 seat with stale corpse ledger must remain visible (real inconsistency)"

# cap=0 intentional_cap_zero=stale seat must be INCLUDED (only corpse is excluded).
assert "opencode__hy3-free" in ids, \
    "cap=0 intentional_cap_zero=stale seat must remain visible (only corpse excluded)"

# Healthy cap>0 seat must be INCLUDED.
assert "healthy__good-model" in ids, \
    "healthy cap>0 seat must be in census"

# excluded_n counts the 1 corpse exclusion.
assert seats.get("excluded_n") == 1, \
    f"excluded_n must be 1 (the cap=0 corpse), got {seats.get('excluded_n')}"

# dead_n counts the hetzner corpse (cap>0, still visible) + opencode stale.
# The minimax corpse is excluded, so it must NOT be in dead_n.
dead_ids = [r["id"] for r in seats.get("seats", []) if r.get("dead")]
assert "commandcode__minimax_minimax-m3-free" not in dead_ids, \
    "excluded corpse must not count in dead_n"
assert "hetzner__Qwen_Qwen3.6-35B-A3B-FP8" in dead_ids, \
    "cap>0 corpse must count in dead_n (visible inconsistency)"

print("ALL OK: cap=0 intentional_cap_zero=corpse excluded from census (fleet-ops#3983)")
PY

ok "cap=0 intentional_cap_zero=corpse seat excluded from opus-heartbeat-gather census"
ok "cap>0 seat with stale corpse ledger remains visible"
ok "cap=0 intentional_cap_zero=stale seat remains visible"
