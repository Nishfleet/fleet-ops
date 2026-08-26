#!/usr/bin/env bash
# tests/repo-privacy-guard.test.sh
#
# Free-tier privacy line (vault global-standing-rules.md, 2026-08-18;
# fleet-ops#520): no-card free LLM tiers train on prompts, so free-class
# seats may only process PUBLIC-repo work. Private-repo or sensitive
# packets route to prepaid/metered lanes only.
#
# What we prove (the drill that runs in CI and on the canary every tick):
#   1. repo_privacy() reads config/repo-privacy.json: a listed public repo
#      resolves "public", a listed private repo resolves "private".
#   2. repo_privacy() fails CLOSED: a repo with no entry resolves to
#      default_policy (private), so a newly created private product repo
#      can never silently leak to a free lane before it is classified.
#   3. repo_privacy() fails CLOSED on a missing/unparseable config too.
#   4. packet_repo() extracts the Nishfleet repo name from every TARGET
#      line shape the dispatch wrappers emit.
#   5. pick_seat ... private NEVER returns a free-class seat — not even
#      when free is the only class with capacity (fail-closed rc=1, loud
#      log, no stdout). This is the core guard.
#   6. pick_seat ... private still picks a prepaid/metered seat when one
#      is available (private work routes off free lanes, not off the
#      whole ladder).
#   7. pick_seat ... public still picks a free lane (the guard does not
#      over-block public work).
#   8. config/repo-privacy.json is valid JSON and every enrolled intake
#      repo is classified (no enrolled repo is left to the fail-closed
#      default by accident).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t repo-privacy-guard.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: never touch live systemd seat state.
export PI_SEAT_LIB_CHECK_SYSTEMD=0

# --- a scratch models.json + seat-caps.json (mirrors seat-lib.test.sh) -----
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    },
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 } }
      ]
    },
    "minimax": {
      "models": [
        { "id": "MiniMax-M3", "cost": { "input": 0.30 } }
      ]
    }
  }
}
JSON

# ollama=free, devin=prepaid-quota, minimax=metered. Free first on public.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama":  { "cap": 2, "class": "free",          "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":   { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } },
    "minimax": { "cap": 2, "class": "metered",       "models": { "MiniMax-M3": 2 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"

# A scratch repo-privacy.json: 0509 public, 0509-telemetry private, default
# fail-closed (private).
cat >"$scratch/repo-privacy.json" <<'JSON'
{
  "default_policy": "private",
  "public": ["0509", "fleet-ops"],
  "private": ["0509-telemetry", "egress-probe"]
}
JSON
export REPO_PRIVACY_JSON="$scratch/repo-privacy.json"

# A clean (usable) seat-health ledger so every allowlisted seat is pickable.
ledger="$scratch/ledger-clean"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"

run_pick() {
    # $1 = privacy. Prints "rc<TAB>out" so callers can assert both.
    local privacy="${1:-public}" state
    state="$scratch/state-$privacy-$$-$RANDOM"
    export PI_PACKET_STATE="$state"
    set +e
    out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "" "$1"' "$lib" "$privacy" 2>/dev/null)
    rc=$?
    set -e
    printf '%s\t%s' "$rc" "$out"
}

# --- invariant 1: repo_privacy reads the config ---------------------------
set +e
pub=$(bash -c 'source "$0"; repo_privacy 0509' "$lib" 2>/dev/null)
priv=$(bash -c 'source "$0"; repo_privacy 0509-telemetry' "$lib" 2>/dev/null)
set -e
[[ "$pub" == "public" ]]  || fail "repo_privacy: 0509 must be public, got '$pub'"
[[ "$priv" == "private" ]] || fail "repo_privacy: 0509-telemetry must be private, got '$priv'"
ok "repo_privacy: listed repos resolve correctly (0509=public, 0509-telemetry=private)"

# --- invariant 2: fail-closed on an unlisted repo ------------------------
set +e
unk=$(bash -c 'source "$0"; repo_privacy a-brand-new-private-product-repo' "$lib" 2>/dev/null)
set -e
[[ "$unk" == "private" ]] \
  || fail "repo_privacy: unlisted repo must fail-closed to private (default_policy), got '$unk'"
ok "repo_privacy: unlisted repo fails closed to private"

# --- invariant 3: fail-closed on a missing/unparseable config ------------
export REPO_PRIVACY_JSON="$scratch/does-not-exist.json"
set +e
miss=$(bash -c 'source "$0"; _repo_privacy_loaded=0; load_repo_privacy; repo_privacy anything' "$lib" 2>/dev/null)
set -e
[[ "$miss" == "private" ]] \
  || fail "repo_privacy: missing config must fail-closed to private, got '$miss'"
ok "repo_privacy: missing config fails closed to private"

printf 'not json{' >"$scratch/bad-privacy.json"
export REPO_PRIVACY_JSON="$scratch/bad-privacy.json"
set +e
bad=$(bash -c 'source "$0"; _repo_privacy_loaded=0; load_repo_privacy; repo_privacy anything' "$lib" 2>/dev/null)
set -e
[[ "$bad" == "private" ]] \
  || fail "repo_privacy: unparseable config must fail-closed to private, got '$bad'"
ok "repo_privacy: unparseable config fails closed to private"
export REPO_PRIVACY_JSON="$scratch/repo-privacy.json"

# --- invariant 4: packet_repo extracts the repo from every TARGET shape ---
pkt="$scratch/pkt-issue.txt"
cat >"$pkt" <<'TXT'
Some prompt body.
TARGET: repo Nishfleet/0509-telemetry issue 7 unit pi-issue-0509telemetry-7
TXT
[[ "$(bash -c 'source "$0"; packet_repo "$1"' "$lib" "$pkt" 2>/dev/null)" == "0509-telemetry" ]] \
  || fail "packet_repo: pi-issue-run TARGET shape not parsed"
ok "packet_repo: pi-issue-run TARGET shape"

cat >"$pkt" <<'TXT'
TARGET: scout unit pi-scout@fleet-ops.service, repo Nishfleet/fleet-ops
TXT
[[ "$(bash -c 'source "$0"; packet_repo "$1"' "$lib" "$pkt" 2>/dev/null)" == "fleet-ops" ]] \
  || fail "packet_repo: pi-scout-run legacy TARGET shape not parsed"
ok "packet_repo: pi-scout-run legacy TARGET shape"

cat >"$pkt" <<'TXT'
TARGET REPO: Nishfleet/0509
TXT
[[ "$(bash -c 'source "$0"; packet_repo "$1"' "$lib" "$pkt" 2>/dev/null)" == "0509" ]] \
  || fail "packet_repo: pi-scout-run 0509 TARGET REPO shape not parsed"
ok "packet_repo: pi-scout-run 0509 TARGET REPO shape"

cat >"$pkt" <<'TXT'
TARGET: intake unit pi-intake@0509-telemetry.service, repo Nishfleet/0509-telemetry
TXT
[[ "$(bash -c 'source "$0"; packet_repo "$1"' "$lib" "$pkt" 2>/dev/null)" == "0509-telemetry" ]] \
  || fail "packet_repo: pi-intake-repair-run TARGET shape not parsed"
ok "packet_repo: pi-intake-repair-run TARGET shape"

# A packet with no TARGET line -> empty (caller defaults to public).
cat >"$pkt" <<'TXT'
just a prompt, no target line
TXT
[[ -z "$(bash -c 'source "$0"; packet_repo "$1"' "$lib" "$pkt" 2>/dev/null)" ]] \
  || fail "packet_repo: no-TARGET packet must return empty"
ok "packet_repo: no-TARGET packet returns empty"

# --- invariant 5: private NEVER picks a free-class seat ------------------
# Free (ollama) is the first-class candidate on a clean ledger. privacy=private
# must skip it and pick a prepaid seat (devin) instead.
res=$(run_pick private)
rc=${res%%	*}; out=${res#*	}
[[ "$rc" == "0" ]] || fail "private: expected a non-free pick, got rc=$rc"
[[ "$out" == "devin	glm-5-2" ]] \
  || fail "private: must pick prepaid devin/glm-5-2, not a free lane, got: $out"
ok "private: routes to prepaid (devin/glm-5-2), not free"

# --- invariant 5b: private with ONLY free seats -> fail-closed rc=1 -------
# Block devin (prepaid) and minimax (metered) via tried-seats so only free
# (ollama) remains. privacy=private must NOT leak to ollama: rc=1, no stdout.
printf 'devin/glm-5-2\nminimax/MiniMax-M3\n' >"$scratch/tried-onlyfree.txt"
state="$scratch/state-onlyfree"
export PI_PACKET_STATE="$state"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1" private' "$lib" "$scratch/tried-onlyfree.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "only-free: private target must fail-closed rc=1, got rc=$rc"
[[ -z "$out" ]]   || fail "only-free: must print nothing to stdout, got: $out"
grep -q "free-tier privacy: private-repo target, free-class lane blocked" "$state/watch.log" \
  || fail "only-free: must log the free-tier privacy skip for ollama"
grep -q "NO USABLE SEAT" "$state/watch.log" \
  || fail "only-free: must log the loud NO USABLE SEAT line"
ok "private: only-free-available -> fail-closed rc=1, no free leak"

# --- invariant 6: private still picks prepaid/metered when free is tried --
# Free (ollama) already tried -> private must pick devin (prepaid), not stall.
printf 'ollama/deepseek-v4-flash:0731\n' >"$scratch/tried-free.txt"
res=$(run_pick private)
rc=${res%%	*}; out=${res#*	}
# run_pick does not pass a tried file; re-run with the tried file inline.
state="$scratch/state-triedfree"
export PI_PACKET_STATE="$state"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1" private' "$lib" "$scratch/tried-free.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "tried-free: private must pick prepaid after free tried, got rc=$rc"
[[ "$out" == "devin	glm-5-2" ]] \
  || fail "tried-free: expected devin/glm-5-2, got: $out"
ok "private: routes to prepaid after free lane tried"

# --- invariant 7: public still picks the free lane -----------------------
res=$(run_pick public)
rc=${res%%	*}; out=${res#*	}
[[ "$rc" == "0" ]] || fail "public: expected a pick, got rc=$rc"
[[ "$out" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "public: must pick free ollama first, got: $out"
ok "public: still picks the free lane (guard does not over-block)"

# --- invariant 8: config/repo-privacy.json is valid + enrolled repos classified
live_privacy="$repo_root/config/repo-privacy.json"
jq -e . "$live_privacy" >/dev/null || fail "config/repo-privacy.json is not valid JSON"
[[ "$(jq -r '.default_policy' "$live_privacy")" == "private" ]] \
  || fail "config/repo-privacy.json default_policy must be 'private' (fail-closed)"
# Every enrolled intake repo must appear in public[] or private[] so the
# fail-closed default is never the live routing decision for enrolled work.
intake="$repo_root/config/intake-repos.json"
if [[ -f "$intake" ]]; then
    while IFS= read -r enrolled; do
        [[ -n "$enrolled" ]] || continue
        if ! jq -e --arg r "$enrolled" '([.public[]?, .private[]?] | index($r)) != null' "$live_privacy" >/dev/null 2>&1; then
            fail "enrolled repo '$enrolled' is not classified in config/repo-privacy.json (would fail-closed to private — classify it explicitly)"
        fi
    done < <(jq -r '.repos[].name' "$intake" 2>/dev/null || true)
fi
ok "config/repo-privacy.json valid; every enrolled intake repo classified"

echo "repo-privacy-guard: all invariants hold"
