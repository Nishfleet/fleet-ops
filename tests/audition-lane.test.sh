#!/usr/bin/env bash
# tests/audition-lane.test.sh
#
# fleet-ops#3322 audition lane. Proves the three organs the issue names:
#   1. lib/audition-sync.py (helper invoked by lib/pi-intake-tick.sh):
#      injects candidates not yet in the LIVE caps as cap-1 audition seats,
#      retires seats that hit 10 sessions / 7 days / $1, records a dated
#      drop so a candidate is not re-tried for 30 days, and never auditions
#      a prepaid-quota provider.
#   2. lib/seat-lib.sh pick_seat: an audition seat is only eligible on
#      packet_difficulty light (never heavy/keystone).
#   3. libexec/fleet-metrics-export.py: the yield ledger carries cost_usd
#      (total usage.cost over the window) for every seat, and emits the
#      per-seat fleet_sessions_to_pr_pct gauge.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Scratch state so live caps/ledger cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
sync_py="$repo_root/lib/audition-sync.py"
exporter="$repo_root/libexec/fleet-metrics-export.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$sync_py" ]] || fail "missing $sync_py"
[[ -f "$exporter" ]] || fail "missing $exporter"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch=$(mktemp -d -t audition-lane.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. audition-sync.py helper ------------------------------------------
cat >"$scratch/candidates.json" <<'JSON'
{
  "candidates": [
    {"provider": "mergegateway", "model": "deepseek/deepseek-v4-flash", "class": "metered", "source": "x"},
    {"provider": "mergegateway", "model": "minimax/minimax-m3", "class": "metered", "source": "x"},
    {"provider": "devin", "model": "glm-5-2", "class": "prepaid-quota", "source": "x"}
  ]
}
JSON

# Injection: prepaid devin skipped, mergegateway candidates injected.
cat >"$scratch/caps-inject.json" <<'JSON'
{"providers": {"devin": {"cap": 4, "class": "prepaid-quota", "models": {"glm-5-2": 3}}}}
JSON
cat >"$scratch/yield-empty.json" <<'JSON'
{}
JSON
MODEL_CANDIDATES_JSON="$scratch/candidates.json" \
  SEAT_CAPS_JSON="$scratch/caps-inject.json" \
  SEAT_YIELD_JSON="$scratch/yield-empty.json" \
  python3 "$sync_py" >/dev/null 2>&1 || fail "audition-sync injection run failed"
jq -e '.providers.mergegateway.audition == true' "$scratch/caps-inject.json" >/dev/null \
  || fail "mergegateway must be injected as an audition seat"
jq -e '.providers.mergegateway.models["deepseek/deepseek-v4-flash"] == 1' "$scratch/caps-inject.json" >/dev/null \
  || fail "mergegateway deepseek model must be cap 1"
jq -e '.providers.mergegateway.models["minimax/minimax-m3"] == 1' "$scratch/caps-inject.json" >/dev/null \
  || fail "mergegateway minimax model must be cap 1"
jq -e '.providers.devin.models["glm-5-2"] == 3' "$scratch/caps-inject.json" >/dev/null \
  || fail "devin (prepaid) must be untouched"
ok "audition-sync: injects non-prepaid candidates, never prepaid-quota"

# Bare-list format: the WFR model-discovery pre-pass (fleet-ops#3321) writes
# config/model-candidates.json as a BARE JSON list [...], not a
# {"candidates": [...]} wrapper. audition-sync.py must read both.
cat >"$scratch/candidates-bare.json" <<'JSON'
[
  {"provider": "mergegateway", "model": "google/gemini-3.7-flash", "class": "metered", "price_in": 0.0, "source": "models.dev"},
  {"provider": "ollama", "model": "deepseek-v4-flash", "class": "free", "price_in": 0.0, "source": "models.dev"}
]
JSON
cat >"$scratch/caps-bare.json" <<'JSON'
{"providers": {}}
JSON
MODEL_CANDIDATES_JSON="$scratch/candidates-bare.json" \
  SEAT_CAPS_JSON="$scratch/caps-bare.json" \
  SEAT_YIELD_JSON="$scratch/yield-empty.json" \
  python3 "$sync_py" >/dev/null 2>&1 || fail "audition-sync bare-list run failed"
jq -e '.providers.mergegateway.audition == true' "$scratch/caps-bare.json" >/dev/null \
  || fail "bare-list: mergegateway must be injected"
jq -e '.providers.mergegateway.models["google/gemini-3.7-flash"] == 1' "$scratch/caps-bare.json" >/dev/null \
  || fail "bare-list: gemini model must be cap 1"
jq -e '.providers.ollama == null' "$scratch/caps-bare.json" >/dev/null \
  || fail "bare-list: prepaid ollama must be skipped"
ok "audition-sync: reads the WFR pre-pass bare-list format (fleet-ops#3321)"

# Retirement: 10 sessions -> promote (yield >= median) or drop.
cat >"$scratch/caps-retire.json" <<'JSON'
{"providers": {"mergegateway": {"cap": 1, "class": "metered", "audition": true, "audition_started": "2026-09-01T00:00:00Z", "audition_sessions": 0, "audition_cost_usd": 0, "models": {"deepseek/deepseek-v4-flash": 1, "minimax/minimax-m3": 1}}}}
JSON
cat >"$scratch/yield-retire.json" <<'JSON'
{"mergegateway/deepseek/deepseek-v4-flash": {"yield": 0.8, "sessions": 10, "cost_usd": 0.5}, "mergegateway/minimax/minimax-m3": {"yield": 0.1, "sessions": 10, "cost_usd": 0.2}, "devin/glm-5-2": {"yield": 0.9, "sessions": 20, "cost_usd": 0.1}}
JSON
verdicts=$(MODEL_CANDIDATES_JSON="$scratch/candidates.json" \
  SEAT_CAPS_JSON="$scratch/caps-retire.json" \
  SEAT_YIELD_JSON="$scratch/yield-retire.json" \
  python3 "$sync_py" 2>/dev/null) || fail "audition-sync retire run failed"
grep -q "PROMOTE mergegateway/deepseek/deepseek-v4-flash" <<<"$verdicts" \
  || fail "high-yield seat must promote, got: $verdicts"
grep -q "DROP mergegateway/minimax/minimax-m3 audition-failed" <<<"$verdicts" \
  || fail "low-yield seat must drop, got: $verdicts"
jq -e '.providers.mergegateway == null' "$scratch/caps-retire.json" >/dev/null \
  || fail "retired provider block must be removed"
jq -e '._audition_drops["mergegateway/minimax/minimax-m3"] != null' "$scratch/caps-retire.json" >/dev/null \
  || fail "drop must be recorded with a date"
ok "audition-sync: retires at 10 sessions, promote vs drop by fleet median"

# Drop TTL: a dropped candidate is not re-injected within 30 days.
cat >"$scratch/caps-ttl.json" <<'JSON'
{"providers": {}, "_audition_drops": {"mergegateway/minimax/minimax-m3": "2026-09-05T00:00:00Z"}}
JSON
MODEL_CANDIDATES_JSON="$scratch/candidates.json" \
  SEAT_CAPS_JSON="$scratch/caps-ttl.json" \
  SEAT_YIELD_JSON="$scratch/yield-empty.json" \
  python3 "$sync_py" >/dev/null 2>&1 || fail "audition-sync ttl run failed"
jq -e '.providers.mergegateway.models["minimax/minimax-m3"] == null' "$scratch/caps-ttl.json" >/dev/null \
  || fail "dropped candidate must not be re-injected within TTL"
jq -e '.providers.mergegateway.models["deepseek/deepseek-v4-flash"] == 1' "$scratch/caps-ttl.json" >/dev/null \
  || fail "non-dropped candidate must still be injected"
ok "audition-sync: dropped candidate not re-tried for 30 days"

# --- 2. seat-lib pick_seat light-only gate --------------------------------
# Only the audition seat exists, so on light it is picked and on heavy it is
# excluded (light-only gate) -> NO USABLE SEAT.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "mergegateway": {
      "models": [ { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    }
  }
}
JSON
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["mergegateway"],
  "walled_comeback": {
    "min_probe_interval_s": 900, "rate_limit_s": 900, "daily_quota_s": 3600,
    "monthly_quota_s": 86400, "free_balance_exhausted_s": 86400, "credentials_bad_s": 604800
  },
  "providers": {
    "mergegateway": { "cap": 1, "class": "free", "audition": true, "models": { "deepseek/deepseek-v4-flash": 1 } }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$scratch/ledger" "$scratch/state"

# On light, the audition seat is eligible and picked (free-first ladder).
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "" light' "$lib" 2>/dev/null) || true
[[ "$out" == *"mergegateway"$'\t'"deepseek/deepseek-v4-flash"* ]] \
  || fail "audition seat must be picked on light, got: $out"
ok "seat-lib: audition seat eligible on difficulty light"

# On heavy, the audition seat must be skipped (light-only).
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 1 "" heavy' "$lib" 2>/dev/null) || true
if [[ "$out" == *"mergegateway"* ]]; then
    fail "audition seat must NOT be picked on heavy, got: $out"
fi
ok "seat-lib: audition seat excluded on difficulty heavy"

# --- 3. metrics-export cost_usd + sessions_to_pr_pct ---------------------
python3 - "$exporter" "$scratch" <<'PY' || fail "metrics-export audition logic failed"
import importlib.util, json, sys
from pathlib import Path

exporter, scratch = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

sessions = Path(scratch) / "sessions"
sessions.mkdir(parents=True, exist_ok=True)
m.SESSIONS_DIR = sessions
m.SEAT_YIELD_JSON = Path(scratch) / "seat-yield.json"
m.SEAT_YIELD_CACHE = Path(scratch) / "seat-yield-cache.json"
m.SEAT_CAPS_DEFAULT = Path(scratch) / "seat-caps.json"
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")

Path(m.SEAT_CAPS_DEFAULT).write_text(json.dumps({
    "providers": {
        "mergegateway": {"cap": 1, "models": {"deepseek/deepseek-v4-flash": 1}}
    }
}))

def session(provider, model, ts, has_pr, cost=None):
    issue = f"pi-issue-{provider}-{model.replace('/', '-')}"
    d = sessions / issue
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"2026-09-04T{ts}.jsonl"
    final_text = (
        "https://github.com/Nishfleet/0509/pull/1234" if has_pr
        else "No PR produced by this session"
    )
    content = [{"type": "text", "text": final_text}]
    base = f'2026-09-04T{ts}Z'
    usage = {"cost": {"total": cost}} if cost is not None else {}
    lines = [
        json.dumps({"type": "session", "version": 3, "timestamp": base, "id": f"{issue}-{ts}"}),
        json.dumps({"type": "model_change", "provider": provider, "modelId": model, "timestamp": base}),
        json.dumps({"type": "message", "message": {"role": "assistant", "content": content, "usage": usage}, "timestamp": base}),
    ]
    path.write_text("\n".join(lines))
    return path

# 20 sessions, 5 PR, 10 at $0.20 -> cost_usd = 2.00, sessions_to_pr_pct = 0.25.
for i in range(20):
    session("mergegateway", "deepseek/deepseek-v4-flash", f"00:00:{i:02d}",
            i % 4 == 0, cost=0.20 if i % 2 == 1 else None)

result = m._compute_seat_yield()
seat = "mergegateway/deepseek/deepseek-v4-flash"
assert seat in result, "audition seat must be in yield ledger"
assert result[seat]["sessions"] == 20
assert result[seat]["pr_count"] == 5
# 10 of 20 sessions at $0.20 -> cost_usd = 2.00 (total, not mean).
assert abs(result[seat]["cost_usd"] - 2.00) < 1e-9, result[seat]["cost_usd"]
j = json.loads(Path(m.SEAT_YIELD_JSON).read_text())
assert abs(j[seat]["cost_usd"] - 2.00) < 1e-9, j[seat]["cost_usd"]
print("OK: yield ledger carries cost_usd (total usage.cost over window)")

lines = []
m._emit_seat_yield(lines, result)
out = "\n".join(lines)
assert "# HELP fleet_sessions_to_pr_pct" in out, out
assert 'fleet_sessions_to_pr_pct{seat="mergegateway/deepseek/deepseek-v4-flash"} 0.250000' in out, out
assert out.count("# HELP fleet_sessions_to_pr_pct") == 1
print("OK: _emit_seat_yield emits per-seat fleet_sessions_to_pr_pct")
PY

ok "fleet-ops#3322: audition lane — sync helper, light-only gate, cost_usd + sessions_to_pr_pct"
