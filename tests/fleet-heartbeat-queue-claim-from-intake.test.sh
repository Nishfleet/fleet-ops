#!/usr/bin/env bash
# tests/fleet-heartbeat-queue-claim-from-intake.test.sh
#
# fleet-ops#177 / #239: heartbeat §2 (queue) and §3 (claim release) must
# derive their repo lists from config/intake-repos.json `repos[]` — the
# same source the reconciler and §5 verify_timers already use — not from
# a hand-maintained ~/.local/state/fleet-heartbeat/fleet-repos.json.
#
# The gap this locks closed: fleet-repos.json had drifted to keep deferred
# repos (inish-site, seo-fix-kit, TinyStudio.io, tinystudio-in) in
# queue/claim, omit fleet-ops after it enrolled on 2026-08-26, and even
# carry a wrong owner prefix (nish3451/seo-fix-kit). A hand edit must never
# be able to re-introduce that.
#
# Mechanical prevention (fleet-ops#366): this test runs the real
# reconcile_fleet_repos_from_intake function against a stale state file
# (the 2026-08-26 live shape) and fails if deferred repos survive, if
# enrolled repos are missing, or if anyone re-wires queue/claim back to
# fleet-repos.json.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-tier1"
intake_json="$repo_root/config/intake-repos.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$intake_json" ]] || fail "missing: $intake_json"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# Extract a single function body from the source by name (column-1 `}`).
extract_fn() {
    local fn="$1"
    awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { in_fn=1 }
        in_fn { print }
        in_fn && /^\}/ { in_fn=0 }
    ' "$bin"
}

# --- 1. Source path lock -----------------------------------------------------
grep -q 'FLEET_INTAKE_REPOS_JSON' "$bin" \
  || fail "fleet-heartbeat-tier1 must use FLEET_INTAKE_REPOS_JSON"
grep -qF '.repos[]? | "Nishfleet/" + .name' "$bin" \
  || fail "fleet-heartbeat-tier1 must derive enrolled repos as Nishfleet/<name> from .repos[]?"
grep -qF 'queue_repos=$enrolled_repos' "$bin" \
  || fail "fleet-heartbeat-tier1 must set queue_repos from the derived enrolled set"
grep -qF 'claim_repos=$enrolled_repos' "$bin" \
  || fail "fleet-heartbeat-tier1 must set claim_repos from the derived enrolled set"
grep -qF 'reconcile_fleet_repos_from_intake' "$bin" \
  || fail "fleet-heartbeat-tier1 must reconcile the live state file from intake"
if grep -qF "jq -r '.queue_repos[]'" "$bin"; then
  fail "fleet-heartbeat-tier1 still reads .queue_repos[] from fleet-repos.json"
fi
if grep -qF "jq -r '.claim_repos[]'" "$bin"; then
  fail "fleet-heartbeat-tier1 still reads .claim_repos[] from fleet-repos.json"
fi
grep -qF ".hands_off[]?" "$bin" \
  || fail "fleet-heartbeat-tier1 must read hands_off with the optional .hands_off[]? form"
if grep -qF 'cat > "$REPOS_JSON"' "$bin"; then
  fail "fleet-heartbeat-tier1 still auto-writes a hardcoded fleet-repos.json (drift surface)"
fi
ok "queue/claim source path locked to intake-repos.json; hands_off is escape-hatch only"

# --- 2. Run the real reconcile against the 2026-08-26 stale shape ------------
scratch="$(mktemp -d -t heartbeat-queue-claim.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/intake.json" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"}
  ],
  "deferred": [
    {"name": "inish-site"},
    {"name": "seo-fix-kit"},
    {"name": "TinyStudio.io"},
    {"name": "tinystudio-in"},
    {"name": "siterep-public"}
  ],
  "excluded": [
    {"name": "fleet2"}
  ]
}
JSON

# Live stale file from the #177 report: deferred repos in queue/claim, a
# wrong-owner seo-fix-kit row, fleet-ops only in claim, plus a paused_note
# that would re-arm a timer the file itself says not to re-arm.
cat >"$scratch/stale.json" <<'JSON'
{
  "queue_repos": [
    "Nishfleet/0509",
    "Nishfleet/inish-site",
    "nish3451/seo-fix-kit",
    "Nishfleet/TinyStudio.io",
    "Nishfleet/tinystudio-in",
    "Nishfleet/siterep-public"
  ],
  "claim_repos": [
    "Nishfleet/0509",
    "Nishfleet/TinyStudio.io",
    "Nishfleet/fleet-ops",
    "Nishfleet/inish-site",
    "nish3451/seo-fix-kit",
    "Nishfleet/siterep-public",
    "Nishfleet/tinystudio-in"
  ],
  "hands_off": ["Nishfleet/0509"],
  "verify_timers": [
    "pi-intake@0509.timer",
    "pi-intake@siterep-public.timer"
  ],
  "_paused_note": "pi-intake@0509.timer PAUSED — do not re-arm"
}
JSON

fn=$(extract_fn reconcile_fleet_repos_from_intake)
[[ -n "$fn" ]] || fail "could not extract reconcile_fleet_repos_from_intake from $bin"
eval "$fn"
reconcile_fleet_repos_from_intake "$scratch/intake.json" "$scratch/stale.json"

got_queue=$(jq -c '.queue_repos' "$scratch/stale.json")
got_claim=$(jq -c '.claim_repos' "$scratch/stale.json")
want='["Nishfleet/0509","Nishfleet/fleet-ops"]'
[[ "$got_queue" == "$want" ]] \
  || fail "queue_repos after reconcile: $got_queue want $want"
[[ "$got_claim" == "$want" ]] \
  || fail "claim_repos after reconcile: $got_claim want $want"
hands=$(jq -c '.hands_off' "$scratch/stale.json")
[[ "$hands" == '["Nishfleet/0509"]' ]] \
  || fail "hands_off must be preserved, got $hands"
derived=$(jq -r '.derived_from' "$scratch/stale.json")
[[ "$derived" == "config/intake-repos.json" ]] \
  || fail "derived_from must name intake-repos.json, got $derived"
if jq -e 'has("verify_timers")' "$scratch/stale.json" >/dev/null; then
  fail "reconcile must drop the hand-maintained verify_timers key"
fi
if jq -e 'has("_paused_note")' "$scratch/stale.json" >/dev/null; then
  fail "reconcile must drop _paused_note (it is not an enrolment key)"
fi
for leaked in inish-site seo-fix-kit TinyStudio.io tinystudio-in siterep-public fleet2 nish3451; do
  if jq -e --arg s "$leaked" '.. | strings | select(contains($s))' "$scratch/stale.json" >/dev/null; then
    fail "stale/deferred/wrong-owner token leaked after reconcile: $leaked"
  fi
done
ok "stale 2026-08-26 fleet-repos.json projects to enrolled repos only; hands_off kept"

# --- 3. Missing-file path writes the projection, never a hardcoded default --
rm -f "$scratch/missing.json"
reconcile_fleet_repos_from_intake "$scratch/intake.json" "$scratch/missing.json"
[[ -f "$scratch/missing.json" ]] || fail "missing dest must be created"
got=$(jq -c '.queue_repos' "$scratch/missing.json")
[[ "$got" == "$want" ]] || fail "missing-file queue_repos: $got want $want"
hands=$(jq -c '.hands_off' "$scratch/missing.json")
[[ "$hands" == '[]' ]] || fail "missing-file hands_off must be [], got $hands"
ok "missing fleet-repos.json is created from intake, not a hardcoded default"

# --- 4. Live repo config -----------------------------------------------------
enrolled=$(jq -r '.repos[].name' "$intake_json")
derived=$(jq -r '.repos[]? | "Nishfleet/" + .name' "$intake_json")
deferred=$(jq -r '.deferred[]?.name' "$intake_json" 2>/dev/null || true)

for repo in $enrolled; do
  printf '%s\n' "$derived" | grep -qx "Nishfleet/$repo" \
    || fail "enrolled repo $repo missing from derived queue/claim set"
done
ok "every enrolled repo in config appears in derived queue/claim set"

printf '%s\n' "$derived" | grep -qx 'Nishfleet/fleet-ops' \
  || fail "Nishfleet/fleet-ops must be in the derived queue/claim set (fleet-ops#177)"
ok "Nishfleet/fleet-ops present in derived queue/claim set"

for repo in $deferred; do
  [ -z "$repo" ] && continue
  if printf '%s\n' "$derived" | grep -qx "Nishfleet/$repo"; then
    fail "deferred repo $repo leaked into derived queue/claim set (fleet-ops#177 regression)"
  fi
done
ok "no deferred repo leaks into derived queue/claim set"

echo "OK: heartbeat queue/claim derived from intake-repos.json (fleet-ops#177)"
