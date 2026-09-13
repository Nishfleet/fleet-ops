#!/usr/bin/env bash
# tests/fleet-usd-spend.test.sh
#
# fleet-ops#4459: rate card in config/seat-caps.json, measure.sh usd_24h line,
# and the fleet_usd_24h prom metric from the same rate-card x session-usage
# math (lib/fleet_usd.py, shared by measure.sh and the exporter so they cannot
# drift).
#
# What we prove (offline, no gh, no prometheus):
#   1. The metered rate-card seats carry usd_per_1m_{input,output,cached} and a
#      _rate_card source citing a URL and a date (required: never fabricate;
#      source-cite + date).
#   2. .providers.crof.usd_per_1m_input is non-null with a source (acceptance).
#   3. measure.sh | grep -E '^usd_24h:' prints metered= and flat_share= and
#      unavailable= (acceptance), with a fixture session dir (no gh).
#   4. lib/fleet_usd.py computes the same marginal USD the exporter emits:
#      a metered crof session of 1M input / 1M output / 1M cached = $0.183.
#   5. The exporter's _emit_usd_24h emits fleet_usd_24h{kind=metered} (acceptance:
#      fleet_usd_24h present in the prom output family).
#   6. A seat with no rate card and no flat plan reports UNAVAILABLE:<why>, never
#      a fabricated $0.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"
lib="$repo_root/lib/fleet_usd.py"
exporter="$repo_root/libexec/fleet-metrics-export.py"
measure="$repo_root/measure.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]]  || fail "seat-caps.json not found: $caps"
[[ -f "$lib" ]]   || fail "lib/fleet_usd.py not found: $lib"
[[ -f "$exporter" ]] || fail "exporter not found: $exporter"
[[ -f "$measure" ]] || fail "measure.sh not found: $measure"
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# 2. crof acceptance field + source.
crof_in="$(jq -r '.providers.crof.usd_per_1m_input' "$caps" 2>/dev/null || true)"
[[ -n "$crof_in" && "$crof_in" != "null" ]] || fail "crof.usd_per_1m_input is null/missing"
crof_src="$(jq -r '.providers.crof._rate_card // ""' "$caps" 2>/dev/null || true)"
[[ -n "$crof_src" ]] || fail "crof._rate_card source missing"
[[ "$crof_src" =~ 2026-09-08 ]] || fail "crof._rate_card lacks a date (required: cite a URL and date)"
echo "$crof_src" | grep -qiE "http|pi-models" || fail "crof._rate_card lacks a source URL"

# 1. Every metered seat with a rate card cites a date'd source.
for p in crof minimax runinfra entrim straitly xai-oauth; do
    has_rate="$(jq -r ".providers[\"$p\"].usd_per_1m_input // 0" "$caps")"
    if [[ "$has_rate" != "0" && "$has_rate" != "null" && -n "$has_rate" ]]; then
        src="$(jq -r ".providers[\"$p\"]._rate_card // \"\"" "$caps")"
        [[ -n "$src" ]] || fail "$p has a metered rate but no _rate_card source"
        [[ "$src" =~ 2026-09-08 ]] || fail "$p._rate_card lacks a date"
    fi
done
ok "rate card present + dated sources (crof, minimax, runinfra, entrim, straitly, xai-oauth)"

# 3. measure.sh usd_24h line (fixture session dir, MEASURE_REPOS empty to avoid gh).
scratch="$(mktemp -d -t fme-usd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/sessions/pi-issue-fleet-ops-0001"
# Fixture timestamp must stay inside the trailing-24h metering window; a
# hardcoded date ages out and metered silently reads 0 (seen 2026-09-09 10:34Z).
fixture_ts="$(date -u -d '-1 hour' +%FT%TZ)"
cat > "$scratch/sessions/pi-issue-fleet-ops-0001/test.jsonl" <<EOF
{"type":"session","timestamp":"$fixture_ts","id":"a"}
{"type":"model_change","provider":"crof","modelId":"deepseek-v4-flash-0731"}
{"type":"message","timestamp":"$fixture_ts","message":{"role":"assistant","usage":{"input":1000000,"output":1000000,"cacheRead":1000000,"totalTokens":3000000}}}
EOF
out="$(FLEET_SESSIONS_DIR="$scratch/sessions" MEASURE_REPOS="" bash "$measure" 2>/dev/null || true)"
usd_line="$(printf '%s\n' "$out" | grep -E '^usd_24h:' || true)"
[[ -n "$usd_line" ]] || fail "measure.sh did not print a ^usd_24h: line; got: $out"
echo "$usd_line" | grep -qE 'metered=' || fail "usd_24h line missing metered="
echo "$usd_line" | grep -qE 'flat_share=' || fail "usd_24h line missing flat_share="
echo "$usd_line" | grep -qE 'unavailable=' || fail "usd_24h line missing unavailable="
ok "measure.sh prints: $usd_line"

# 4-5. lib/fleet_usd.py math + exporter emits fleet_usd_24h.
pyout="$(
SEAT_CAPS_JSON="$caps" FLEET_SESSIONS_DIR="$scratch/sessions" python3 - <<PY
import os, pathlib, sys
sys.path.insert(0, "$repo_root/lib")
import fleet_usd
rc = fleet_usd.load_rate_card("$caps")
agg, _, _ = fleet_usd.compute_usd_24h("$scratch/sessions", rc)
print("metered=%.6f crof_in=%s" % (sum(v for p,v in agg.items()), rc["crof"]["input"]))
PY
)"
echo "$pyout" | grep -q "metered=0.183000" || fail "fleet_usd math wrong for 1M/1M/1M crof (expected 0.183000): $pyout"
ok "lib/fleet_usd.py computes 0.183 for 1M/1M/1M crof (matching rate card)"

# 4b. compute_usd_24h caches by file mtime so the 5-min exporter tick is cheap
#     (the shared lib must not re-parse every session jsonl each run). Warm call
#     returns identical results and hits the cache (fast, no re-parse).
cache_out="$(
python3 - <<PY
time, os, sys, pathlib = __import__("time"), __import__("os"), __import__("sys"), __import__("pathlib")
sys.path.insert(0, "$repo_root/lib")
import fleet_usd
fleet_usd._USD_FILE_CACHE.clear()
rc = fleet_usd.load_rate_card("$caps")
sess = pathlib.Path("$scratch/sessions")
a1,_,_ = fleet_usd.compute_usd_24h(str(sess), rc)
t0 = time.time()
a2,_,_ = fleet_usd.compute_usd_24h(str(sess), rc)
warm = time.time() - t0
assert a1 == a2, "cache changed result"
assert warm < 0.01, f"warm call should be cached (took {warm:.3f}s)"
print("cache warm=%.4fs metered=%s OK" % (warm, sum(a2.values())))
PY
)"
echo "$cache_out" | grep -q "OK" || fail "fleet_usd compute_usd_24h cache warm-read failed: $cache_out"
ok "fleet_usd.py caches per-file by mtime so re-scans are cheap (no result drift)"

# exporter emits fleet_usd_24h family from the same session tree.
expout="$(
SEAT_CAPS_JSON="$caps" FLEET_SESSIONS_DIR="$scratch/sessions" python3 - <<PY
import importlib.util, pathlib, os
os.environ.setdefault("FLEET_SESSIONS_DIR", "$scratch/sessions")
mp = pathlib.Path("$exporter")
spec = importlib.util.spec_from_file_location("fme", mp)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_CAPS_LIVE = pathlib.Path("$caps")
m.SEAT_CAPS_DEFAULT = m.SEAT_CAPS_LIVE
m.SEAT_CAPS_FALLBACK = m.SEAT_CAPS_LIVE
m.SESSIONS_DIR = pathlib.Path("$scratch/sessions")
lines=[]
m._emit_usd_24h(lines, {"Nishfleet/crof": 1})
print("\n".join(l for l in lines if "fleet_usd" in l))
PY
)"
echo "$expout" | grep -qE 'fleet_usd_24h\{kind="metered"\}' || fail "exporter did not emit fleet_usd_24h{kind=metered}; got: $expout"
echo "$expout" | grep -qE 'fleet_usd_24h\{kind="flat_share"\}' || fail "exporter did not emit fleet_usd_24h{kind=flat_share}"
# fleet-ops#4459 regression: the label VALUE must be quoted. Prometheus
# exposition format requires quoted label values; `merged_prs=133` is a parse
# error, and the node_exporter textfile collector drops the ENTIRE file on one
# bad line — so an unquoted value took fleet_usd_24h dark with it
# (node_textfile_scrape_error=1, observed live 2026-09-08T09:0xZ).
echo "$expout" | grep -qE 'fleet_usd_per_merged_pr\{merged_prs="[0-9]+"\} [0-9]' \
  || fail "exporter must emit fleet_usd_per_merged_pr with a QUOTED label value (textfile-parseable); got: $(echo "$expout" | grep fleet_usd_per_merged_pr)"
echo "$expout" | grep -qE 'fleet_usd_per_merged_pr\{merged_prs=[0-9]' \
  && fail "exporter emitted an unquoted merged_prs label value — node_exporter drops the whole textfile on that line"
ok "exporter emits fleet_usd_24h + fleet_usd_per_merged_pr with a quoted, parseable label (#4459)"

# 6. retired (fleet-ops#4263): per-seat prepaid USD recording went with the
# routing library; spend is the LiteLLM proxy /spend now.

# 6b. retired with 6 (fleet-ops#4263): remote_agent prepaid USD recording
# was the same deleted helper; the proxy /spend owns spend.

echo "PASS"
