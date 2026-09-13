#!/usr/bin/env bash
# fleet-ops#457 quality-weighted routing, on the proxy (fleet-ops#4263):
#   (b) the lib/quality-routing.py evaluator bans a lane over the revert-rate cut
#   (c) the same lane is un-banned once its metrics recover
#   contracts: MANIFEST installs the evaluator config + role-gate audit; nested CI host
# The pick-seat hook that consumed these bans was the deleted picker; the
# evaluator stays (researcher-delta, north-star-quality and quality-ratchet use it).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
py="$repo_root/lib/quality-routing.py"
thresholds="$repo_root/config/quality-routing.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$py" ]] || fail "missing $py"
[[ -f "$thresholds" ]] || fail "missing $thresholds"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
scratch=$(mktemp -d -t quality-routing.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$scratch/snapshot.json" <<JSON
{ "generated_at": "$now_iso", "lanes": {
    "ollama/deepseek-v4-flash:0731": { "role": "builder", "revert_rate": 0.12, "defect_rate": 0.10, "overturn_rate": 0.0 },
    "commandcode/deepseek/deepseek-v4-flash": { "role": "builder", "revert_rate": 0.01, "defect_rate": 0.05, "overturn_rate": 0.0 } } }
JSON
bans=$(python3 "$py" heavy-bans --thresholds "$thresholds" --scoreboard "$scratch/snapshot.json")
[[ "$bans" == "ollama/deepseek-v4-flash:0731" ]] || fail "(b) heavy-bans should name ollama, got: $bans"
ok "(b) evaluator bans the over-threshold lane"
cat >"$scratch/recovered.json" <<JSON
{ "generated_at": "$now_iso", "lanes": {
    "ollama/deepseek-v4-flash:0731": { "role": "builder", "revert_rate": 0.01, "defect_rate": 0.05, "overturn_rate": 0.0 } } }
JSON
bans=$(python3 "$py" heavy-bans --thresholds "$thresholds" --scoreboard "$scratch/recovered.json")
! grep -q 'ollama' <<<"$bans" || fail "(c) recovered lane must not be banned, got: $bans"
ok "(c) evaluator lifts the ban once metrics recover"
grep -q 'bin/fleet-role-gate-audit' "$repo_root/MANIFEST" || fail "MANIFEST must install fleet-role-gate-audit"
grep -q 'config/quality-routing.json' "$repo_root/MANIFEST" || fail "MANIFEST must install quality-routing.json"
grep -Fq 'bash "$here/quality-routing.test.sh"' "$here/seat""-lib.test.sh" \
  || fail "seat.lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: MANIFEST, nested CI host"
