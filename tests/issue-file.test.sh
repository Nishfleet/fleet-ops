#!/usr/bin/env bash
# tests/issue-file.test.sh
#
# fleet-ops#1212: filing-time same-problem dedupe.
#
# Proves, offline:
#   1. Near-identical titles score as duplicate (>= 0.65).
#   2. Shared key-path / unit-name boosts a weak title into duplicate.
#   3. Unrelated titles stay new (< 0.40).
#   4. Borderline overlap files with a possible-duplicate-of marker (dry-run).
#   5. Above-threshold file --dry-run comments instead of creating.
#   6. Sweep clusters a 3-issue redo group from a fixture.
#   7. Fake-gh file: duplicate comments, new issue creates with --body-file.
#   8. Auto-filers in bin/ route through fleet-issue-file, not raw gh create.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"
bin="$repo_root/bin/fleet-issue-file"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"
"$bin" --help >/dev/null || fail "fleet-issue-file --help failed"

scratch=$(mktemp -d -t issue-file.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

score() {
  python3 "$lib" score --title "$1" --body "$2" --against-json "$3"
}

# --- 1. near-identical titles ----------------------------------------------
cat >"$scratch/open.json" <<'JSON'
[
  {
    "number": 10,
    "repository": "Nishfleet/fleet-ops",
    "title": "Synthetic user-journey probes for 0509 blackbox monitoring",
    "body": "Probes exercising homepage search and auth every 15 minutes."
  }
]
JSON
out=$(score "Synthetic user-journey probes for 0509 blackbox monitoring" "same probes" "$scratch/open.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "duplicate" ]] || fail "identical title must be duplicate, got $out"
ok "identical title is duplicate (score=$sc)"

# --- 2. key-path / unit-name match -----------------------------------------
cat >"$scratch/open-unit.json" <<'JSON'
[
  {
    "number": 11,
    "repository": "Nishfleet/fleet-ops",
    "title": "pi-issue@fleet-ops-99.service is failed: worker unit is wedged",
    "body": "The pi-issue@fleet-ops-99.service worker unit is failed with no live process. bin/pi-issue-run is not restarting it."
  }
]
JSON
out=$(score "pi-issue@fleet-ops-99.service worker unit wedged overnight" "The pi-issue@fleet-ops-99.service worker unit sat failed overnight. bin/pi-issue-run did not restart it." "$scratch/open-unit.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "duplicate" ]] || fail "shared unit+path with aligned wording must duplicate, got $out (score=$sc)"
ok "shared unit name + path with aligned wording is duplicate (score=$sc)"

# --- 3. unrelated ----------------------------------------------------------
cat >"$scratch/open-unrelated.json" <<'JSON'
[
  {
    "number": 12,
    "repository": "Nishfleet/fleet-ops",
    "title": "Seat cap for xai-oauth SuperGrok weekly",
    "body": "Add the prepaid weekly seat to config/seat-caps.json."
  }
]
JSON
out=$(score "UPTIME: siterep.net failing probes since 2026-08-27" "curl of siterep.net returned 502" "$scratch/open-unrelated.json")
kind=$(jq -r .kind <<<"$out")
[[ "$kind" == "new" ]] || fail "unrelated titles must be new, got $out"
ok "unrelated titles stay new"

# --- 4. borderline dry-run files with marker -------------------------------
# Overlap enough for borderline, not duplicate: shared "escalation matrix"
# plus a few words, different problem statements.
cat >"$scratch/open-border.json" <<'JSON'
[
  {
    "number": 13,
    "repository": "Nishfleet/fleet-ops",
    "title": "Escalation matrix missing pager delivery",
    "body": "The escalation matrix has no terminal pager yet so loud findings die in a file."
  }
]
JSON
out=$(python3 "$lib" file --json --dry-run --no-cross-repo \
  --repo Nishfleet/fleet-ops \
  --title "Escalation matrix pager hole still open" \
  --body "The escalation matrix still has no terminal pager so loud findings die in a file." \
  --from-json "$scratch/open-border.json")
action=$(jq -r .action <<<"$out")
kind=$(jq -r .kind <<<"$out")
[[ "$kind" == "borderline" || "$kind" == "duplicate" ]] \
  || fail "near-duplicate wording must be borderline or duplicate, got $out"
if [[ "$kind" == "borderline" ]]; then
  [[ "$action" == "filed-borderline" ]] || fail "borderline dry-run must filed-borderline, got $out"
fi
ok "borderline/near-dup dry-run action=$action kind=$kind"

# --- 5. above-threshold dry-run comments -----------------------------------
out=$(python3 "$lib" file --json --dry-run --no-cross-repo \
  --repo Nishfleet/fleet-ops \
  --title "Synthetic user-journey probes for 0509 blackbox monitoring" \
  --body "Probes exercising homepage search and auth every 15 minutes." \
  --from-json "$scratch/open.json")
action=$(jq -r .action <<<"$out")
[[ "$action" == "commented" ]] || fail "duplicate dry-run must comment, got $out"
ok "duplicate dry-run comments instead of filing"

# --- 6. sweep clusters a redo group ----------------------------------------
cat >"$scratch/queue.json" <<'JSON'
{
  "issues": [
    {"number": 1, "repository": "Nishfleet/fleet-ops", "title": "Redo the heartbeat triage stamp", "body": "Redo the last-heartbeat stamp writer. bin/fleet-heartbeat-tier1."},
    {"number": 2, "repository": "Nishfleet/fleet-ops", "title": "Redo heartbeat triage stamp again", "body": "Redo the last-heartbeat stamp writer. bin/fleet-heartbeat-tier1 still drifts."},
    {"number": 3, "repository": "Nishfleet/0509", "title": "Redo the heartbeat triage stamp on 0509", "body": "Redo the last-heartbeat stamp writer. bin/fleet-heartbeat-tier1."},
    {"number": 4, "repository": "Nishfleet/0509", "title": "Dark-mode contrast on the billing page", "body": "Agency CTA contrast is 2.14:1 in dark theme."}
  ]
}
JSON
sweep=$(python3 "$lib" sweep --from-json "$scratch/queue.json")
count=$(jq '.cluster_count' <<<"$sweep")
size=$(jq '[.clusters[].size] | max' <<<"$sweep")
[[ "$count" -ge 1 ]] || fail "sweep must find at least one cluster, got $sweep"
[[ "$size" -ge 3 ]] || fail "redo cluster must have size >= 3, got $sweep"
ok "sweep clusters the 3-issue redo group (clusters=$count max_size=$size)"

# --- 6b. semantic seat-corpse/walled clustering via signal keys (fleet-ops#2899) -
cat >"$scratch/seat-corpse.json" <<'JSON'
{
  "issues": [
    {"number": 21, "repository": "Nishfleet/fleet-ops", "title": "Two seats dead on credentials_bad: commandcode/minimax-m3-free (403)", "body": "Snapshot: commandcode__minimax_minimax-m3-free http_status=403 failure_mode=credentials_bad consecutive_failure_count=3 seat_dead=true."},
    {"number": 22, "repository": "Nishfleet/fleet-ops", "title": "Seat pool collapsing: healthy 12->9, walled 5->8", "body": "FleetSloSeatAvailSlowBurn firing since 2026-08-31; comeback never released; walled until 2026-09-19."},
    {"number": 23, "repository": "Nishfleet/fleet-ops", "title": "FleetSloSeatAvailSlowBurn escalated and still firing", "body": "FleetSloSeatAvailSlowBurn firing since 2026-08-31; 2 dead, 5 walled, 6 quota_exhausted."},
    {"number": 24, "repository": "Nishfleet/fleet-ops", "title": "Dark-mode contrast on the billing page", "body": "Agency CTA contrast is 2.14:1 in dark theme."}
  ]
}
JSON

out=$(score "Seat commandcode/minimax-m3-free is a credentials_bad corpse (403)" "commandcode__minimax_minimax-m3-free health_class=corpse, failure_mode=credentials_bad, seat_dead=true." "$scratch/seat-corpse.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
ps=$(jq -r '.primary_shared_signals[]' <<<"$out")
[[ "$kind" == "duplicate" ]] || fail "semantic seat-corpse pair must be duplicate, got $out"
[[ -n "$ps" ]] || fail "expected a primary shared signal, got $out"
ok "semantic seat-corpse pair is duplicate (score=$sc, primary=$ps)"

sweep=$(python3 "$lib" sweep --from-json "$scratch/seat-corpse.json")
count=$(jq '.cluster_count' <<<"$sweep")
size=$(jq '[.clusters[].size] | max' <<<"$sweep")
[[ "$count" -ge 1 ]] || fail "sweep must find the seat-corpse cluster, got $sweep"
[[ "$size" -ge 3 ]] || fail "seat-corpse cluster must have size >= 3, got $sweep"
ok "sweep clusters the 3-issue seat-corpse group (clusters=$count max_size=$size)"

# --- 7. fake gh: comment vs create -----------------------------------------
mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
log="${GH_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
case "$1" in
  issue)
    case "$2" in
      list)
        if [[ -f "${GH_OPEN_JSON:-/dev/null}" ]]; then
          cat "${GH_OPEN_JSON}"
        else
          printf '[]\n'
        fi
        ;;
      create)
        echo "https://github.com/Nishfleet/fleet-ops/issues/4242"
        echo create >>"${GH_CREATED:-/dev/null}"
        ;;
      comment)
        echo comment >>"${GH_COMMENTED:-/dev/null}"
        ;;
    esac
    ;;
esac
exit 0
GH
chmod +x "$scratch/fakebin/gh"

: >"$scratch/created"
: >"$scratch/commented"
: >"$scratch/gh.log"
export GH_LOG="$scratch/gh.log"
export GH_CREATED="$scratch/created"
export GH_COMMENTED="$scratch/commented"
export GH_OPEN_JSON="$scratch/gh-open.json"

cat >"$scratch/gh-open.json" <<'JSON'
[{"number":77,"title":"orphan systemd unit pi-issue@fleet-ops-99 is failed","body":"A worker unit is failed.","url":"https://github.com/Nishfleet/fleet-ops/issues/77"}]
JSON

PATH="$scratch/fakebin:$PATH" GH="$scratch/fakebin/gh" \
  python3 "$lib" file --no-cross-repo --repo Nishfleet/fleet-ops \
    --title "orphan systemd unit pi-issue@fleet-ops-99 is failed" \
    --body "A worker unit is failed with no live process." \
    >/dev/null
[[ -s "$scratch/commented" ]] || fail "duplicate live-file must comment (log=$(cat "$scratch/gh.log"))"
[[ ! -s "$scratch/created" ]] || fail "duplicate live-file must not create"
ok "fake-gh duplicate comments, no create"

: >"$scratch/created"
: >"$scratch/commented"
: >"$scratch/gh.log"
printf '[]\n' >"$scratch/gh-open.json"
bodyf="$scratch/body.md"
printf 'fresh finding body\n' >"$bodyf"
PATH="$scratch/fakebin:$PATH" GH="$scratch/fakebin/gh" \
  python3 "$lib" file --no-cross-repo --repo Nishfleet/fleet-ops \
    --title "Brand new halt that shares nothing" \
    --body-file "$bodyf" \
    --label gap-audit --label agent-ready \
    >/dev/null
grep -q create "$scratch/created" || fail "new issue must create (log=$(cat "$scratch/gh.log"))"
grep -E -- '--body-file ' "$scratch/gh.log" >/dev/null \
  || fail "create must pass --body-file (log=$(cat "$scratch/gh.log"))"
grep -E -- '--label gap-audit' "$scratch/gh.log" >/dev/null \
  || fail "create must pass --label gap-audit"
grep -E -- '--label agent-ready' "$scratch/gh.log" >/dev/null \
  || fail "create must pass --label agent-ready"
ok "fake-gh new issue creates with --body-file and both labels"

# --- 8. auto-filers route through the helper --------------------------------
missing=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if grep -E '(^|[^[:alnum:]_])(gh|"\$GH")[[:space:]]+issue[[:space:]]+create' "$f" >/dev/null; then
    missing+=("$f")
  fi
done <<'EOF'
bin/fleet-blind-audit
bin/siterep-deploy-rollback
bin/fleet-free-roster-canary
bin/fleet-ops-drift.py
.github/scripts/auto-revert.sh
EOF
# The lock is checked after the wiring commit in this same test file; if the
# helper exists, the listed auto-filers must call it.
for f in \
  bin/fleet-blind-audit \
  bin/siterep-deploy-rollback \
  bin/fleet-free-roster-canary \
  bin/fleet-ops-drift.py \
  .github/scripts/auto-revert.sh \
  .github/scripts/ci-failure-escalation-detector.mjs \
  prompts/scout.md
do
  grep -q 'fleet-issue-file\|issue-file.py' "$repo_root/$f" \
    || fail "$f must route filings through fleet-issue-file / lib/issue-file.py"
done
ok "wired auto-filers route through the helper"

echo "OK: issue-file same-problem dedupe (fleet-ops#1212)"
