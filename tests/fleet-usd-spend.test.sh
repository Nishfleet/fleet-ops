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
cat > "$scratch/sessions/pi-issue-fleet-ops-0001/test.jsonl" <<'EOF'
{"type":"session","timestamp":"2026-09-08T10:00:00Z","id":"a"}
{"type":"model_change","provider":"crof","modelId":"deepseek-v4-flash-0731"}
{"type":"message","timestamp":"2026-09-08T10:00:00Z","message":{"role":"assistant","usage":{"input":1000000,"output":1000000,"cacheRead":1000000,"totalTokens":3000000}}}
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
echo "$expout" | grep -qE 'fleet_usd_per_merged_pr' || fail "exporter did not emit fleet_usd_per_merged_pr"
ok "exporter emits fleet_usd_24h + fleet_usd_per_merged_pr"

# 6. UNAVAILABLE never fabricated: a provider with no rate card records UNAVAILABLE
#    in the prepaid-usage counter.
pystate="$scratch/state"
ST="$pystate" bash - <<SH
export PI_PACKET_STATE="$pystate"
export STATE_DIR="$pystate"
export SEAT_CAPS_JSON="$caps"
source "$repo_root/lib/seat-lib.sh"
mkdir -p "\$STATE_DIR/prepaid-usage" "\$STATE_DIR"
sess="$scratch/dev.jsonl"
printf '%s\n' '{"type":"message","message":{"role":"assistant","usage":{"input":100,"output":100,"cacheRead":0}}}' > "\$sess"
_record_prepaid_usd some-no-rate-seat "\$sess"
jq -r '.usd' "\$STATE_DIR/prepaid-usage/some-no-rate-seat.json"
rm -f "\$sess"
SH
unavail="$(cat "$pystate/prepaid-usage/some-no-rate-seat.json" | jq -r '.usd' 2>/dev/null || true)"
[[ "$unavail" == UNAVAILABLE:* ]] || fail "no-rate-card seat did not record UNAVAILABLE (got: $unavail) — must not fabricate \$0"
ok "no-rate-card seat records UNAVAILABLE (not a fabricated \$0)"

echo "PASS"
