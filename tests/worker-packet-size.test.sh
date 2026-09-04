#!/usr/bin/env bash
# tests/worker-packet-size.test.sh
#
# fleet-ops#3120: byte-size assertion for the rendered worker packet.
# Intake now appends repo-conditional blocks (D1/gate-integrity for 0509,
# GEO/AEO for geo/aeo issues) to the small base worker.md. The base packet
# must stay under 12 KB for non-0509 repos and 20 KB for 0509, so small
# context windows are not bloated and the prompt-size ceiling test keeps
# headroom.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"
block_0509_mig="$repo_root/prompts/worker-0509-migrations.md"
block_0509_gi="$repo_root/prompts/worker-0509-gate-integrity.md"
block_geo="$repo_root/prompts/worker-geo-aeo.md"
intake="$repo_root/lib/pi-intake-tick.sh"
metric_exporter="$repo_root/libexec/fleet-metrics-export.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$block_0509_mig" ]] || fail "missing $block_0509_mig"
[[ -f "$block_0509_gi" ]] || fail "missing $block_0509_gi"
[[ -f "$block_geo" ]] || fail "missing $block_geo"
[[ -f "$intake" ]] || fail "missing $intake"
[[ -f "$metric_exporter" ]] || fail "missing $metric_exporter"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t worker-packet-size.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

target_line='TARGET: repo Nishfleet/<repo> issue <N> unit pi-issue-<repo>-<N>'

packet_size() {
  local out="$scratch/packet.in"
  { cat "$worker"; echo; for f in "$@"; do cat "$f"; done; echo; echo "$target_line"; } > "$out"
  wc -c < "$out"
}

# --- 1. base (non-0509, no conditional blocks) stays under 12 KB ---------------
base_size=$(packet_size)
[[ "$base_size" -le 12288 ]] || fail "base packet is ${base_size}B, exceeds 12 KB (non-0509)"
ok "base non-0509 packet is ${base_size}B, under 12 KB"

# --- 2. 0509 with D1 + gate-integrity blocks stays under 20 KB -----------------
mig_gi_size=$(packet_size "$block_0509_mig" "$block_0509_gi")
[[ "$mig_gi_size" -le 20480 ]] || fail "0509 D1+gate-integrity packet is ${mig_gi_size}B, exceeds 20 KB"
ok "0509 D1+gate-integrity packet is ${mig_gi_size}B, under 20 KB"

# --- 3. 0509 with D1 only stays under 20 KB ------------------------------------
mig_size=$(packet_size "$block_0509_mig")
[[ "$mig_size" -le 20480 ]] || fail "0509 D1-only packet is ${mig_size}B, exceeds 20 KB"
ok "0509 D1-only packet is ${mig_size}B, under 20 KB"

# --- 4. 0509 with gate-integrity only stays under 20 KB ------------------------
gi_size=$(packet_size "$block_0509_gi")
[[ "$gi_size" -le 20480 ]] || fail "0509 gate-integrity-only packet is ${gi_size}B, exceeds 20 KB"
ok "0509 gate-integrity-only packet is ${gi_size}B, under 20 KB"

# --- 5. non-0509 with GEO/AEO block stays under 12 KB --------------------------
geo_size=$(packet_size "$block_geo")
[[ "$geo_size" -le 12288 ]] || fail "non-0509 GEO/AEO packet is ${geo_size}B, exceeds 12 KB"
ok "non-0509 GEO/AEO packet is ${geo_size}B, under 12 KB"

# --- 6. 0509 with all conditional blocks stays under 20 KB ---------------------
all_size=$(packet_size "$block_0509_mig" "$block_0509_gi" "$block_geo")
[[ "$all_size" -le 20480 ]] || fail "0509 all-blocks packet is ${all_size}B, exceeds 20 KB"
ok "0509 all-blocks packet is ${all_size}B, under 20 KB"

# --- 7. lib/pi-intake-tick.sh assembles conditional blocks ---------------------
grep -q 'conditional_worker_blocks' "$intake" \
  || fail "lib/pi-intake-tick.sh must call conditional_worker_blocks"
grep -q 'worker-0509-migrations.md' "$intake" \
  || fail "lib/pi-intake-tick.sh must reference worker-0509-migrations.md"
grep -q 'worker-0509-gate-integrity.md' "$intake" \
  || fail "lib/pi-intake-tick.sh must reference worker-0509-gate-integrity.md"
grep -q 'worker-geo-aeo.md' "$intake" \
  || fail "lib/pi-intake-tick.sh must reference worker-geo-aeo.md"
ok "lib/pi-intake-tick.sh assembles conditional blocks"

# --- 8. libexec/fleet-metrics-export.py emits fleet_packet_bytes ---------------
grep -q 'fleet_packet_bytes' "$metric_exporter" \
  || fail "libexec/fleet-metrics-export.py must define fleet_packet_bytes metric"
grep -q '_packet_sizes' "$metric_exporter" \
  || fail "libexec/fleet-metrics-export.py must define _packet_sizes()"
mkdir -p "$scratch/packets"
# plant a few fake packets with known sizes/expected medians
printf '%0*d' 1000 0 | tr '0' 'a' > "$scratch/packets/fleet-ops-1.in"
printf '%0*d' 3000 0 | tr '0' 'b' > "$scratch/packets/fleet-ops-2.in"
printf '%0*d' 5000 0 | tr '0' 'c' > "$scratch/packets/fleet-ops-3.in"
printf '%0*d' 4000 0 | tr '0' 'd' > "$scratch/packets/0509-4.in"
FLEET_METRICS_PACKET_DIR="$scratch/packets" python3 - "$metric_exporter" <<'PY'
import sys, importlib.util
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("fme", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sizes = mod._packet_sizes()
assert "fleet-ops" in sizes, "missing fleet-ops packet size"
assert sizes["fleet-ops"] == 3000, f"fleet-ops median mismatch: {sizes['fleet-ops']}"
assert "0509" in sizes, "missing 0509 packet size"
assert sizes["0509"] == 4000, f"0509 median mismatch: {sizes['0509']}"
print("metric computed OK")
PY
ok "libexec/fleet-metrics-export.py emits fleet_packet_bytes per repo"

ok "worker-packet-size: base and conditional packets fit the 12 KB/20 KB budget"
