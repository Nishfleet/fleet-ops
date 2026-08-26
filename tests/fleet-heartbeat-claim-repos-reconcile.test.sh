#!/usr/bin/env bash
# tests/fleet-heartbeat-claim-repos-reconcile.test.sh
#
# fleet-ops#239: heartbeat must reconcile fleet-repos.json claim_repos (and
# queue_repos) to config/intake-repos.json enrolment. verify_timers already
# derives from intake (#156 finding 9); claim_repos/queue_repos did not, so
# a repo joining intake (fleet-ops on 2026-08-26) stayed missing from the
# live state file and #124 never scanned its claim PRs. The #152 canary
# fails loud on that gap every tick.
#
# This test runs the real tier1 binary with FLEET_REPOS_RECONCILE_ONLY=1 so
# it stops after writing the reconciled file — no gh, no live systemctl.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- 1. Shape lock ----------------------------------------------------------
grep -q 'FLEET_INTAKE_REPOS_JSON' "$bin" \
  || fail "fleet-heartbeat-tier1 must use FLEET_INTAKE_REPOS_JSON"
grep -q 'intake_synced' "$bin" \
  || fail "fleet-heartbeat-tier1 must persist intake_synced so leavers drop and extras stay"
grep -q 'FLEET_REPOS_RECONCILE_ONLY' "$bin" \
  || fail "fleet-heartbeat-tier1 must honour FLEET_REPOS_RECONCILE_ONLY (test seam; exit after write-back)"
# Reconcile must happen before claim_repos is consumed by later blocks.
# The read of .claim_repos[] must come AFTER the python rewrite, which we
# lock by requiring the reconcile-only exit to appear before block 0/1.
awk '
  /FLEET_REPOS_RECONCILE_ONLY/ { rec=NR }
  /last-heartbeat updated/ { hb=NR }
  END {
    if (!rec) exit 1
    if (hb && rec > hb) exit 2
  }
' "$bin" || fail "reconcile-only exit must run before last-heartbeat mutation"
ok "shape: intake source, intake_synced, reconcile-only seam, order"

# --- scratch env ------------------------------------------------------------
scratch="$(mktemp -d -t heartbeat-claim-repos.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

plan="$scratch/plan.md"
: >"$plan"
log_dir="$scratch/log"
triage="$scratch/triage.md"
mkdir -p "$log_dir"
: >"$triage"

intake="$scratch/intake-repos.json"
repos_json="$scratch/fleet-repos.json"

run_reconcile() {
  FLEET_PLAN_FILE="$plan" \
  FLEET_REPOS_JSON="$repos_json" \
  FLEET_INTAKE_REPOS_JSON="$intake" \
  FLEET_HEARTBEAT_LOG_DIR="$log_dir" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  FLEET_REPOS_RECONCILE_ONLY=1 \
    "$bin"
}

# --- 2. Joiner: stale file missing an intake repo ---------------------------
# Exact #239 bug: 0509 in claim_repos, fleet-ops enrolled, fleet-ops absent.
cat >"$intake" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"}
  ]
}
JSON
cat >"$repos_json" <<'JSON'
{
  "queue_repos": ["Nishfleet/0509", "Nishfleet/inish-site"],
  "claim_repos": ["Nishfleet/0509", "Nishfleet/inish-site"],
  "hands_off": ["Nishfleet/seo-fix-kit"]
}
JSON

run_reconcile || fail "scenario2: reconcile-only must exit 0"

jq -e '.claim_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario2: claim_repos must gain Nishfleet/fleet-ops (joiner)"
jq -e '.claim_repos | index("Nishfleet/0509")' "$repos_json" >/dev/null \
  || fail "scenario2: claim_repos must keep Nishfleet/0509"
jq -e '.claim_repos | index("Nishfleet/inish-site")' "$repos_json" >/dev/null \
  || fail "scenario2: extra product repo Nishfleet/inish-site must be preserved"
jq -e '.queue_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario2: queue_repos must also gain the intake joiner"
jq -e '.queue_repos | index("Nishfleet/inish-site")' "$repos_json" >/dev/null \
  || fail "scenario2: extra queue repo Nishfleet/inish-site must be preserved"
ho=$(jq -c '.hands_off' "$repos_json")
[[ "$ho" == '["Nishfleet/seo-fix-kit"]' ]] \
  || fail "scenario2: hands_off must be preserved unchanged, got $ho"
synced=$(jq -c '.intake_synced' "$repos_json")
[[ "$synced" == '["Nishfleet/0509","Nishfleet/fleet-ops"]' ]] \
  || fail "scenario2: intake_synced must record current intake slugs, got $synced"
ok "scenario2: joiner added to claim_repos and queue_repos; extras and hands_off kept"

# --- 3. Idempotent second tick ----------------------------------------------
cp "$repos_json" "$scratch/after-first.json"
run_reconcile || fail "scenario3: second tick must exit 0"
# Field order may shuffle; compare the sets that matter.
for key in claim_repos queue_repos hands_off intake_synced; do
  a=$(jq -c --arg k "$key" '.[$k]' "$scratch/after-first.json")
  b=$(jq -c --arg k "$key" '.[$k]' "$repos_json")
  [[ "$a" == "$b" ]] || fail "scenario3: $key drifted on second tick ($a -> $b)"
done
ok "scenario3: second tick is a no-op"

# --- 4. Leaver: intake repo removed, extras stay ----------------------------
cat >"$intake" <<'JSON'
{
  "repos": [
    {"name": "0509"}
  ]
}
JSON
run_reconcile || fail "scenario4: leaver tick must exit 0"
jq -e '.claim_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  && fail "scenario4: claim_repos must drop Nishfleet/fleet-ops after it left intake"
jq -e '.queue_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  && fail "scenario4: queue_repos must drop Nishfleet/fleet-ops after it left intake"
jq -e '.claim_repos | index("Nishfleet/inish-site")' "$repos_json" >/dev/null \
  || fail "scenario4: extra product repo must still be in claim_repos"
jq -e '.claim_repos | index("Nishfleet/0509")' "$repos_json" >/dev/null \
  || fail "scenario4: remaining intake repo must stay in claim_repos"
synced=$(jq -c '.intake_synced' "$repos_json")
[[ "$synced" == '["Nishfleet/0509"]' ]] \
  || fail "scenario4: intake_synced must shrink to remaining intake, got $synced"
ok "scenario4: leaver dropped; extra product repo kept"

# --- 5. Missing state file: default then reconcile --------------------------
rm -f "$repos_json"
cat >"$intake" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"}
  ]
}
JSON
run_reconcile || fail "scenario5: missing-file path must exit 0"
[[ -f "$repos_json" ]] || fail "scenario5: default fleet-repos.json was not written"
jq -e '.claim_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario5: default+reconcile must include Nishfleet/fleet-ops in claim_repos"
jq -e '.queue_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario5: default+reconcile must include Nishfleet/fleet-ops in queue_repos"
jq -e '.claim_repos | index("Nishfleet/siterep-public")' "$repos_json" >/dev/null \
  || fail "scenario5: default extras such as siterep-public must survive reconcile"
ok "scenario5: missing file writes default then adds every intake slug"

# --- 6. Canary contract: every intake slug is in claim_repos ----------------
# Same derivation the #152 canary uses (Nishfleet/<name>).
intake_slugs=$(jq -r '.repos[]? | "Nishfleet/\(.name)"' "$intake")
while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue
  jq -e --arg s "$slug" '.claim_repos | index($s)' "$repos_json" >/dev/null \
    || fail "scenario6: canary would flag $slug missing from claim_repos"
done <<< "$intake_slugs"
ok "scenario6: every intake slug is in claim_repos (canary contract)"

# --- 7. Live-shaped file: extra keys + non-Nishfleet extras survive ---------
# The 2026-08-26 live state file carries verify_timers, a _paused_note, and
# nish3451/seo-fix-kit (not Nishfleet/). Reconcile must not wipe those.
cat >"$intake" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"}
  ]
}
JSON
cat >"$repos_json" <<'JSON'
{
  "queue_repos": ["Nishfleet/0509", "nish3451/seo-fix-kit"],
  "claim_repos": ["Nishfleet/0509", "nish3451/seo-fix-kit"],
  "hands_off": [],
  "verify_timers": ["pi-intake@0509.timer"],
  "_paused_note": "do not strip this"
}
JSON
run_reconcile || fail "scenario7: live-shaped reconcile must exit 0"
jq -e '.claim_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario7: live-shaped stale file must gain fleet-ops"
jq -e '.claim_repos | index("nish3451/seo-fix-kit")' "$repos_json" >/dev/null \
  || fail "scenario7: nish3451/seo-fix-kit extra must be preserved"
note=$(jq -r '._paused_note' "$repos_json")
[[ "$note" == "do not strip this" ]] \
  || fail "scenario7: extra keys must be preserved, _paused_note=$note"
jq -e '.verify_timers | index("pi-intake@0509.timer")' "$repos_json" >/dev/null \
  || fail "scenario7: unused verify_timers key must be left in place"
ok "scenario7: live-shaped extras and unknown keys survive; joiner still added"

# --- 8. First tick after deploy: fleet-ops already hand-added to claim_repos
#      but missing from queue_repos (the exact 2026-08-26 live drift) --------
# The hand-fix on 2026-08-26 added fleet-ops to claim_repos only. The first
# tick under this PR must add it to queue_repos too, keep every existing slug,
# and record intake_synced.
cat >"$intake" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"}
  ]
}
JSON
cat >"$repos_json" <<'JSON'
{
  "queue_repos": ["Nishfleet/0509", "Nishfleet/inish-site"],
  "claim_repos": ["Nishfleet/0509", "Nishfleet/fleet-ops", "Nishfleet/inish-site"],
  "hands_off": []
}
JSON
run_reconcile || fail "scenario8: first-tick reconcile must exit 0"
jq -e '.claim_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario8: claim_repos must keep the hand-added fleet-ops"
jq -e '.queue_repos | index("Nishfleet/fleet-ops")' "$repos_json" >/dev/null \
  || fail "scenario8: queue_repos must gain fleet-ops on first tick"
jq -e '.claim_repos | index("Nishfleet/inish-site")' "$repos_json" >/dev/null \
  || fail "scenario8: extra product repo must be preserved"
synced=$(jq -c '.intake_synced' "$repos_json")
[[ "$synced" == '["Nishfleet/0509","Nishfleet/fleet-ops"]' ]] \
  || fail "scenario8: intake_synced must be recorded, got $synced"
ok "scenario8: first-tick under deploy closes the queue_repos gap"

echo "OK: heartbeat claim_repos/queue_repos reconciled to intake enrolment (fleet-ops#239)"
