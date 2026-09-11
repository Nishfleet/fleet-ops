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
#   repair_rung=armed|off ticks=<n>   (fleet-ops#4820; latched rung visibility)
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

# fleet-ops#4820: repair-rung latch visibility (blind-spot rule #4460).
# Printed first so a later gh/python failure cannot hide the line. The
# state file is the same one lib/pi-intake-tick.sh writes; missing or
# unreadable is off ticks=0, never a guess. Armed = strikes >= AFTER.
_rung_file="${PI_INTAKE_REPAIR_RUNG_STATE:-$HOME/workspaces/agent-state/pi-intake/repair-rung-state}"
_rung_after="${PI_INTAKE_REPAIR_RUNG_AFTER:-2}"
_rung_s=0
if [[ -f "$_rung_file" ]]; then
    read -r _rung_s _ <"$_rung_file" 2>/dev/null || true
fi
_rung_s=$(printf '%s' "${_rung_s:-}" | tr -cd '0-9')
[[ "$_rung_s" =~ ^[0-9]+$ ]] || _rung_s=0
if (( _rung_s >= _rung_after )); then
    echo "repair_rung=armed ticks=${_rung_s}"
else
    echo "repair_rung=off ticks=${_rung_s}"
fi

# --- gh_app: nishfleet-worker App installation token budget ----------------
# fleet-ops#5489: an idle fleet with a full queue because the App token's
# 5000/hr core budget is exhausted is a NAMED fault, never a mystery. Reads
# the same side-car state the exporter writes every 60s (the intake tick's
# rate-limit state); missing/unreadable is UNAVAILABLE, never a fabricated 0.
_gh_app_state="${GH_APP_RATE_LIMIT_STATE:-$HOME/workspaces/agent-state/pi-intake/gh-rate-limit.json}"
_gh_app_remaining=$(jq -r '.resources.core.remaining // .remaining // 0' "$_gh_app_state" 2>/dev/null || true)
if [[ "${_gh_app_remaining:-}" =~ ^[0-9]+$ ]]; then
    _gh_app_reset=$(jq -r '.resources.core.reset // .reset // 0' "$_gh_app_state" 2>/dev/null || echo 0)
    _gh_app_wait=$(( _gh_app_reset - $(date +%s) )); (( _gh_app_wait < 0 )) && _gh_app_wait=0
    echo "gh_app: remaining=${_gh_app_remaining} reset_in=${_gh_app_wait}s"
else
    echo "gh_app: UNAVAILABLE:state-missing-or-unparseable"
fi

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

# --- gate-escapes-24h -----------------------------------------------------
# fleet-ops#5238: merged PRs in the window whose diff touched gate-owned
# paths while the head's gate-integrity check was not green — the
# advisory-gate escape class. Repos without a gate-integrity workflow
# cannot produce one and are skipped. A gh failure flags the line
# UNAVAILABLE, never a fabricated 0 (same posture as the merge count).
gate_escapes=""
if command -v gh >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  _ge_cfg="$repo_root/.fleet/gate-integrity.yml"
  _ge_globs="$(bash "$repo_root/lib/gate-integrity-config.sh" "$_ge_cfg" 2>/dev/null \
      | jq -c '.gate_globs' 2>/dev/null)"
  if [ -z "$_ge_globs" ]; then
    gate_escapes="UNAVAILABLE:gate-glob-resolution"
  else
    gate_escapes=0
    _ge_fail=0
    for repo in $repo_list; do
      # No gate-integrity workflow on the repo -> no gate to escape.
      if ! gh api "repos/$repo/contents/.github/workflows/gate-integrity.yml" \
          --jq '.sha' >/dev/null 2>&1; then
        continue
      fi
      _ge_prs_file=$(mktemp -t fleet-gate-escapes.XXXXXX 2>/dev/null) \
        || { _ge_fail=1; continue; }
      if ! gh pr list -R "$repo" --state merged --limit 200 \
          --json number,mergedAt,headRefOid,files > "$_ge_prs_file" 2>/dev/null; then
        rm -f "$_ge_prs_file"; _ge_fail=1; continue
      fi
      _ge_gate_prs=$(FLEET_GATE_GLOBS="$_ge_globs" \
        MEASURE_CUTOFF="$(date -u -d '-24 hours' +%FT%TZ)" \
        python3 - "$_ge_prs_file" <<'PY'
import fnmatch, json, os, sys

globs = json.loads(os.environ["FLEET_GATE_GLOBS"])
cutoff = os.environ["MEASURE_CUTOFF"]
try:
    prs = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(0)

def matches(path):
    for p in globs:
        if fnmatch.fnmatch(path, p):
            return True
        if p.endswith("/**") and path.startswith(p[:-2]):
            return True
    return False

for pr in prs or []:
    if (pr.get("mergedAt") or "") < cutoff:
        continue
    paths = [f.get("path", "") for f in pr.get("files") or []]
    if any(matches(p) for p in paths):
        print(f"{pr.get('number')}\t{pr.get('headRefOid')}")
PY
      ) || { _ge_fail=1; continue; }
      while IFS=$'\t' read -r _pr_num _pr_sha; do
        [ -n "$_pr_sha" ] || continue
        _ge_verdict=$(gh api "repos/$repo/commits/$_pr_sha/check-runs" \
            --paginate \
            -q '.check_runs[] | select(.name == "gate-integrity" or (.name | endswith("/ gate-integrity"))) | [.id, (.conclusion // "pending")] | @tsv' \
            2>/dev/null | sort -n | tail -1 | cut -f2) || { _ge_fail=1; continue; }
        case "${_ge_verdict:-missing}" in
          success) : ;;
          *) gate_escapes=$((gate_escapes + 1)) ;;
        esac
      done <<< "$_ge_gate_prs"
      rm -f "$_ge_prs_file"
    done
    [ "$_ge_fail" -eq 0 ] || gate_escapes="UNAVAILABLE:gh-error"
  fi
else
  gate_escapes="UNAVAILABLE:no-gh"
fi
echo "gate-escapes-24h: ${gate_escapes}"

# --- cursor_today: real Cursor-side API-bucket burn (fleet-ops#4566/#4621)
# Shared helper: lib/cursor-api-bucket.sh (also sourced by the prepaid-util
# canary so the judge-facing usd_today cannot be the token $0). Reconciliation:
# GetCurrentPeriodUsage planUsage.apiPercentUsed x (limit/100) — see
# `bash lib/cursor-api-bucket.sh --help`.
# shellcheck disable=SC1091
source "$repo_root/lib/cursor-api-bucket.sh"
CURSOR_TODAY_FIGURE="$(cursor_today_figure)"
export CURSOR_TODAY_FIGURE
export CURSOR_API_CYCLE_USD="$(cursor_api_cycle_usd)"

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

# --- findings ledger: every finding queued, never dropped silently ----------
# fleet-ops#5443: the judges own carry-over ageing. One line, right after
# visitor:, from the canonical findings ledger. Missing/unreadable ledger is
# a real zero situation — but carried_over>0 is NEVER zeroed silently; the
# green check below flags a ledger that has gone silent (no append in 48h).
if [ -f "$repo_root/lib/findings_ledger.py" ]; then
    python3 "$repo_root/lib/findings_ledger.py" measure \
        || echo "findings: total=0 filed=0 carried_over=0 oldest_carry_h=0 panel_fail=0 UNAVAILABLE:measure-failed"
fi
