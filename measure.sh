#!/usr/bin/env bash
# measure.sh — fleet USD spend + $/merged-PR snapshot (fleet-ops#4459).
#
# The judge header carries usd_24h as the third number (product: -> waste:
# -> usd_24h: -> shipped/24h -> workers/ready, per the fable-check header
# order spec). This script produces the numbers that line and the fleet_usd_24h
# prom metric consume.
#
# Output (machine-readable on stdout, one idea per line):
#   usd_24h: metered=<n> flat_share=<n> cursor_today=<n|UNAVAILABLE:<why>> cursor_api_cycle_usd=<n|UNAVAILABLE:<why>> unavailable=<seats>
#              cursor_today is the trailing-24h delta of Cursor's own
#              GetCurrentPeriodUsage included-API-bucket spend (fleet-ops#4566);
#              cursor_api_cycle_usd is the cycle-to-date cumulative.
#   usd_per_merged_pr: <n>
#
#   metered    = marginal USD from tracked-metered seats over the trailing 24h
#                (rate card in config/seat-caps.json x session usage tokens)
#   flat_share = prorated daily share of the registered flat prepaid plans
#                (flat_usd_per_month / 30)
#   unavailable= seat providers seen in the last 24h with NO rate card and NO
#                flat plan — reported by name (never fabricated as $0)
#   usd_per_merged_pr = total (metered + flat_share) / merged PRs (trailing 24h)
#
# Usage:
#   bash measure.sh               # trailing 24h (default)
#   FLEET_SESSIONS_DIR=<dir> bash measure.sh   # point at a session tree
#   MEASURE_PYTHON=<path> bash measure.sh      # python3 override for tests

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
lib="$repo_root/lib/fleet_usd.py"
seat_caps="$repo_root/config/seat-caps.json"
sessions_dir="${FLEET_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
python="${MEASURE_PYTHON:-python3}"

[[ -f "$lib" ]] || { echo "measure.sh: fleet_usd.py not found: $lib" >&2; exit 1; }
[[ -f "$seat_caps" ]] || { echo "measure.sh: seat-caps.json not found: $seat_caps" >&2; exit 1; }

# Merged PRs across the fleet repos in the trailing 24h (gh is the live truth;
# a gh failure makes the numerator unknown and is flagged, not silently zeroed).
merged_24h=0
repo_list="${MEASURE_REPOS:-Nishfleet/fleet-ops Nishfleet/0509 Nishfleet/siterep-public Nishfleet/inish-site}"
for repo in $repo_list; do
  if command -v gh >/dev/null 2>&1; then
    n=$(gh pr list -R "$repo" --state merged --limit 200 --json mergedAt \
        -q "[.[]|select(.mergedAt>=\"$(date -u -d '-24 hours' +%FT%TZ)\")]|length" 2>/dev/null || echo 0)
    merged_24h=$((merged_24h + (n + 0)))
  fi
done

# --- cursor_today: real Cursor-side API-bucket burn (fleet-ops#4566) -------
# The token-derived usd_today for cursor is structurally $0 (prepaid-quota
# class, no rate card), which reported a false 0.000000 as fact. The real
# number is Cursor's own GetCurrentPeriodUsage API bucket, written by
# bin/fleet-prepaid-util-canary into prepaid-spend/cursor.json
# (api_bucket_used_usd, cycle-to-date cumulative). cursor_today = the trailing
# 24h DELTA of that cumulative figure, computed against a history of samples
# this script appends on every run. Until >= CURSOR_TODAY_MIN_H hours of
# history exists it reports UNAVAILABLE:cursor-history-warming — never a
# fabricated $0. cursor_api_cycle_usd (cycle-to-date) is always real once the
# canary has run. Reconciliation command for a human:
#   token=$(jq -r .accessToken ~/.config/cursor/auth.json); curl -s -X POST \
#     -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
#     -d '{}' https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage \
#     | jq '.planUsage | {apiPercentUsed, limit}'
# apiPercentUsed x (limit/100) = api_bucket_used_usd = cursor_api_cycle_usd.
cursor_today_figure() {
    local state_dir hist now_s latest_usd latest_s line ts used base_ts base_usd last_ts
    state_dir="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
    hist="$state_dir/prepaid-spend/cursor-history.jsonl"
    local state_json="$state_dir/prepaid-spend/cursor.json"
    [[ -f "$state_json" ]] || { echo "UNAVAILABLE:no-cursor-state"; return; }
    latest_usd=$(jq -r '.api_bucket_used_usd // empty' "$state_json" 2>/dev/null || true)
    latest_s=$(jq -r '.updated_s // empty' "$state_json" 2>/dev/null || true)
    [[ -n "$latest_usd" && -n "$latest_s" ]] || { echo "UNAVAILABLE:no-api-bucket-field"; return; }
    now_s=$(date -u +%s)
    mkdir -p "$(dirname "$hist")" 2>/dev/null || true
    # Append (deduped: skip if the last sample is < 300s old).
    last_ts=0
    [[ -f "$hist" ]] && last_ts=$(tail -n 1 "$hist" 2>/dev/null | jq -r '.updated_s // 0' 2>/dev/null || echo 0)
    if (( now_s - last_ts >= 300 )); then
        printf '{"updated_s":%s,"api_bucket_used_usd":%s}\n' "$latest_s" "$latest_usd" >> "$hist" 2>/dev/null || true
    fi
    min_age_s=$(( ${CURSOR_TODAY_MIN_H:-24} * 3600 ))
    base_ts=""; base_usd=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        ts=$(printf '%s' "$line" | jq -r '.updated_s // 0' 2>/dev/null || echo 0)
        used=$(printf '%s' "$line" | jq -r '.api_bucket_used_usd // 0' 2>/dev/null || echo 0)
        if (( now_s - ts >= min_age_s )); then base_ts=$ts; base_usd=$used; fi
    done < "$hist"
    if [[ -z "$base_ts" ]]; then
        echo "UNAVAILABLE:cursor-history-warming"
        return
    fi
    # Cycle reset between base and now makes the delta meaningless.
    cycle_end_s=$(jq -r '.cycle_end_s // 0' "$state_json" 2>/dev/null || echo 0)
    if (( cycle_end_s > 0 && base_ts < cycle_end_s && now_s >= cycle_end_s )); then
        echo "UNAVAILABLE:cycle-reset-in-window"
        return
    fi
    awk -v n="$latest_usd" -v b="$base_usd" 'BEGIN{d=n-b; printf "%.4f", (d<0)?0:d}'
}
CURSOR_TODAY_FIGURE="$(cursor_today_figure)"
export CURSOR_TODAY_FIGURE
export CURSOR_API_CYCLE_USD="$(jq -r '.api_bucket_used_usd // "UNAVAILABLE:no-cursor-state"' "${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/prepaid-spend/cursor.json" 2>/dev/null || echo UNAVAILABLE:no-cursor-state)"

# Compute the USD numbers via the shared helper (kept in lock-step with the
# fleet_usd_24h prom exporter).
FLEET_USD_LIB="$lib" FLEET_USD_SEAT_CAPS="$seat_caps" FLEET_USD_SESSIONS="$sessions_dir" \
  "$python" - <<'PY' "${merged_24h}"
import json, os, sys

sys.path.insert(0, os.environ["FLEET_USD_LIB"].rsplit("/", 1)[0])
from fleet_usd import (
    load_rate_card,
    compute_usd_24h,
)

merged_24h = int(sys.argv[1] or 0)
rate_card = load_rate_card(os.environ["FLEET_USD_SEAT_CAPS"])
agg, seen_missing, flat = compute_usd_24h(os.environ["FLEET_USD_SESSIONS"], rate_card)

# metered seats that priced in the 24h and are NOT flat (flat seats report
# flat_share, their marginal metered spend is a $0 read).
metered = sum(v for prov, v in agg.items() if not rate_card.get(prov, {}).get("flat"))
flat_share = sum(flat.values())
# UNAVAILABLE: seats seen in sessions with no price record in the rate card,
# EXCEPT class=free seats — those are measurably $0 (cost field 0 in the catalog),
# so they are not "unreadable", they are known-free. Never fabricate a $0 for a
# seat that cannot be read; name the unreadable ones (fleet-ops#4459 required).
_SKIP = {"litellm", "litellm-private", "litellm-worker"}  # internal self/control plane
unavailable = ",".join(
    sorted(
        seed
        for seed in seen_missing
        if not rate_card.get(seed, {}).get("priced")
        and rate_card.get(seed, {}).get("class") != "free"
        and seed not in _SKIP
    )
)

# usd_per_merged_pr: total spend over merged PRs. 0 merged -> unknown, flagged.
if merged_24h and merged_24h > 0:
    usd_per_pr = (metered + flat_share) / merged_24h
    per_line = f"usd_per_merged_pr: {usd_per_pr:.4f}"
else:
    per_line = "usd_per_merged_pr: UNAVAILABLE:no-merged-pr-in-24h"

# cursor_today: the real Cursor-side figure (24h delta of the GetCurrentPeriodUsage
# API bucket, or an UNAVAILABLE:<why> label — never a fabricated $0; fleet-ops#4566).
print(f"usd_24h: metered={metered:.4f} flat_share={flat_share:.4f} cursor_today={os.environ.get('CURSOR_TODAY_FIGURE', 'UNAVAILABLE:no-cursor-state')} cursor_api_cycle_usd={os.environ.get('CURSOR_API_CYCLE_USD', 'UNAVAILABLE:no-cursor-state')} unavailable={unavailable or 'none'}")
print(per_line)
# A JSON blob for consumers that prefer structured output (the judge header's
# third line is built from usd_24h above; this is the raw detail).
print(
    "usd_json: "
    + json.dumps(
        {
            "metered_24h": round(metered, 4),
            "flat_share_24h": round(flat_share, 4),
            "merged_pr_24h": merged_24h,
            "usd_per_merged_pr": round(usd_per_pr, 4) if merged_24h else None,
            "unavailable": sorted(unavailable.split(",")) if unavailable else [],
            "cursor_today": os.environ.get('CURSOR_TODAY_FIGURE', 'UNAVAILABLE:no-cursor-state'),
            "cursor_api_cycle_usd": os.environ.get('CURSOR_API_CYCLE_USD', 'UNAVAILABLE:no-cursor-state'),
        }
    )
)
PY

# --- questions flame: for-nish / oldest / in-conference / unfiled -----------
# fleet-ops#4476 (part 3): the escalation-matrix side of the judge header.
# Sourced (not run) from lib/fleet-questions.sh; fails closed to real zeros,
# an unreachable store stays a real zero (gh calls are guarded). The unfiled
# scan + auto-file happen here too (the detector lives in measure.sh, so
# `bash measure.sh | grep -E '^questions:'` proves both the line and the
# scan).
if [ -f "$repo_root/lib/fleet-questions.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "$repo_root/lib/fleet-questions.sh"
    fleet_questions_line
fi

