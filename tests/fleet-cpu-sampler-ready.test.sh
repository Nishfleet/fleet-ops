#!/usr/bin/env bash
# tests/fleet-cpu-sampler-ready.test.sh
#
# fleet-ops#4956: the #4804 CPU sampler scored `ready` from
# ready-work-cache.json with `data.get("ready", 0)`, but that cache's shape is
# {"ts": .., "data": 144} — no "ready" key — so all 285 samples read 0 and the
# decision rule's backlog conjunct was unscoreable. This drill locks the fix:
#
#   (a) the sampler reads the real backlog from queue-composition-cache.json
#       `data["ready-work"]["total"]` and records which cache it used;
#   (b) the ready-work-cache.json `data` fallback works;
#   (c) a stale cache (> FLEET_CPU_SAMPLER_READY_FRESH_S) scores 0 with
#       ready_source=NO_DATA — a deliberate zero, not a silent 0-by-default;
#   (d) a cache without the key is NO_DATA too (the exact #4804 bug);
#   (e) the retained analysis prints the real ready values and a non-zero
#       saturated_with_backlog_hours when load1 > 2x cores.
#
# Hermetic: temp AGENT_STATE, temp output, stubbed gh, no network/systemd.
# Hosted from tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

sampler="$repo_root/libexec/fleet-cpu-sampler.py"
analysis="$repo_root/libexec/fleet-cpu-analysis.py"
[[ -f "$sampler" ]] || fail "missing $sampler"
[[ -f "$analysis" ]] || fail "missing $analysis"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One sample per run (DURATION_S=1, INTERVAL_S=1): the sampler writes a sample
# on its first tick and exits. This is the fastest readable proof of the read.
sample_once() {
  local state="$1"
  FLEET_CPU_SAMPLER_OUT="$state/out.jsonl" \
  FLEET_CPU_SAMPLER_DURATION_S=1 \
  FLEET_CPU_SAMPLER_INTERVAL_S=1 \
  AGENT_STATE="$state" \
  python3 "$sampler" >/dev/null 2>&1
  [[ -s "$state/out.jsonl" ]] || fail "sampler wrote no sample into $state"
  tail -1 "$state/out.jsonl"
}

field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }

now=$(date -u +%s)

# --- (a) queue-composition cache is the primary source -----------------------
state_a="$work/a"
mkdir -p "$state_a/fleet-metrics"
python3 - "$state_a" "$now" <<'PY'
import json, sys
state, now = sys.argv[1], int(sys.argv[2])
json.dump({"ts": now, "data": {"ready-work": {"total": 154, "self": 13}}},
          open(f"{state}/fleet-metrics/queue-composition-cache.json", "w"))
PY
line_a="$(sample_once "$state_a")"
[[ "$(field "$line_a" ready)" == "154" ]] \
  || fail "(a) ready must be 154 from queue-composition, got $(field "$line_a" ready)"
[[ "$(field "$line_a" ready_source)" == "queue-composition-cache.json" ]] \
  || fail "(a) ready_source must name queue-composition-cache.json, got $(field "$line_a" ready_source)"
ok "(a) ready=154 read from queue-composition-cache.json data[ready-work][total]"

# --- (b) ready-work-cache.json data fallback --------------------------------
state_b="$work/b"
mkdir -p "$state_b/fleet-metrics"
python3 - "$state_b" "$now" <<'PY'
import json, sys
state, now = sys.argv[1], int(sys.argv[2])
json.dump({"ts": now, "data": 144},
          open(f"{state}/fleet-metrics/ready-work-cache.json", "w"))
PY
line_b="$(sample_once "$state_b")"
[[ "$(field "$line_b" ready)" == "144" ]] \
  || fail "(b) fallback ready must be 144, got $(field "$line_b" ready)"
[[ "$(field "$line_b" ready_source)" == "ready-work-cache.json" ]] \
  || fail "(b) fallback source must name ready-work-cache.json, got $(field "$line_b" ready_source)"
ok "(b) ready=144 read from the ready-work-cache.json data fallback"

# --- (c) beyond the producer's refresh bound -> NO_DATA / scored 0 ---------
# The queue-composition cache is only rewritten once PR_CACHE_TTL (1800s) has
# expired, so a 15-min-old cache is still the true backlog and must score; only
# an age past READY_FRESH_S (2400s) is NO_DATA. Both halves are pinned here:
# the #4804 failure was a real number being thrown away, not a stale one kept.
state_c2="$work/c2"
mkdir -p "$state_c2/fleet-metrics"
python3 - "$state_c2" "$now" <<'PY'
import json, sys
state, now = sys.argv[1], int(sys.argv[2])
json.dump({"ts": now - 900, "data": {"ready-work": {"total": 154}}},
          open(f"{state}/fleet-metrics/queue-composition-cache.json", "w"))
PY
line_c2="$(sample_once "$state_c2")"
[[ "$(field "$line_c2" ready)" == "154" ]] \
  || fail "(c) a 15-min-old cache is still the real backlog (producer TTL 1800s), got $(field "$line_c2" ready)"
[[ "$(field "$line_c2" ready_source)" == "queue-composition-cache.json" ]] \
  || fail "(c) 15-min-old cache must still name its source, got $(field "$line_c2" ready_source)"
ok "(c) cache inside the producer TTL (900s) still scores ready=154"

state_c="$work/c"
mkdir -p "$state_c/fleet-metrics"
python3 - "$state_c" "$now" <<'PY'
import json, sys
state, now = sys.argv[1], int(sys.argv[2])
json.dump({"ts": now - 3600, "data": {"ready-work": {"total": 154}}},
          open(f"{state}/fleet-metrics/queue-composition-cache.json", "w"))
PY
line_c="$(sample_once "$state_c")"
[[ "$(field "$line_c" ready)" == "0" ]] || fail "(c) stale cache must score 0"
[[ "$(field "$line_c" ready_source)" == "NO_DATA" ]] \
  || fail "(c) stale cache must report NO_DATA, got $(field "$line_c" ready_source)"
ok "(c) stale cache (1h old) scores ready=0 ready_source=NO_DATA"

# --- (d) key-less cache -> NO_DATA (the #4804 bug class) --------------------
state_d="$work/d"
mkdir -p "$state_d/fleet-metrics"
python3 - "$state_d" "$now" <<'PY'
import json, sys
state, now = sys.argv[1], int(sys.argv[2])
json.dump({"ts": now, "ready": 0, "data": ["agent-ready"]},
          open(f"{state}/fleet-metrics/ready-work-cache.json", "w"))
PY
line_d="$(sample_once "$state_d")"
[[ "$(field "$line_d" ready)" == "0" && "$(field "$line_d" ready_source)" == "NO_DATA" ]] \
  || fail "(d) key-less cache must be NO_DATA, got ready=$(field "$line_d" ready) source=$(field "$line_d" ready_source)"
ok "(d) key-less cache is NO_DATA, never a silent 0-by-default"

# --- (e) analysis shows the real ready values and scores the conjunct -------
jsonl="$work/analyse.jsonl"
python3 - "$jsonl" <<'PY'
import json, sys
out = sys.argv[1]
t0 = 1789047000
with open(out, "w") as f:
    for i in range(3):
        f.write(json.dumps({
            "ts": t0 + 60 * i,
            "load1": 99.0,
            "idle_pct": 5.0,
            "iowait_pct": 1.0,
            "ready": 154,
            "ready_source": "queue-composition-cache.json",
            "procs": {},
        }) + "\n")
PY
stub="$work/bin"
mkdir -p "$stub"
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' >"$stub/gh"
chmod +x "$stub/gh"
report="$(PATH="$stub:$PATH" python3 "$analysis" "$jsonl")"
python3 - "$report" <<'PY' || fail "(e) analysis must print the real ready values and a scored conjunct"
import json, sys
r = json.loads(sys.argv[1])
assert r["ready_max"] == 154, r
assert r["ready_min"] == 154, r
assert "queue-composition-cache.json" in r["ready_sources"], r
assert r["saturated_with_backlog_hours"] > 0, r
PY
ok "(e) analysis prints ready_min/ready_max=154 and saturated_with_backlog_hours>0"

echo "ALL PASSED: fleet-cpu-sampler-ready"
