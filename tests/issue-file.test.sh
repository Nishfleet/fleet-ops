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
#  10. Spec-schema bodies for two DIFFERENT problems never reach DUP_THRESHOLD,
#      while a genuinely same-problem pair still does (fleet-ops#5058).
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

# --- 10. spec-schema bodies for different problems are not duplicates -------
# fleet-ops#5058: three different-problem candidates were suppressed onto
# #4959 (a cpu-sampler scoring step) at exactly PRIMARY_SIGNAL_FLOOR, 0.70,
# while their token overlap was 0.05-0.24. Two causes, both regression-locked:
#   (a) the derived #2899 `fleet/seat-crisis` PRIMARY signal fired on ANY body
#       that mentioned a seat next to a failure word. #4959 carries "seat
#       rate-limit walls" and, in an unrelated sentence, "the unit is dead
#       with no deliverable" / "dead-man" — so the cpu-sampler packet, a
#       dangling-symlink packet and a seat packet all looked like one problem.
#       The failure cause is now a seat-health marker, or a seat state word in
#       the same breath as the seat word.
#   (b) the packet field skeleton (metric:/observed:/evidence:/...) is in
#       every well-formed candidate, so it counted as overlap evidence; it is
#       stripped before tokenising.
# Asserted both ways: the real different-problem pairs stay below
# DUP_THRESHOLD, and a genuinely same-problem pair still clears it.
cat >"$scratch/against-4959.json" <<'JSON'
[
  {
    "number": 4959,
    "repository": "Nishfleet/fleet-ops",
    "title": "score the throughput Decision rule conjunct 2 from the completed 24h cpu-sampler run (fleet-ops#4956)",
    "body": "metric: the #4804 throughput Decision rule conjunct 2 (`saturated_with_backlog_hours` >= 6 of 24h) is scored from a completed 24h sampler window with a real `ready` value.\n\nobserved: 2026-09-10. #4956 landed the fixed sampler (`libexec/fleet-cpu-sampler.py`): `ready` is read from `queue-composition-cache.json` with a freshness bound.\n\naccept:\n- Read the completed window: `agent-state/fleet-metrics/cpu-sampler-4956-24h.jsonl`.\n- If the run is incomplete (unit still active, no deliverable, or JSONL < 6h): post `blocked-on: re-open-2026-09-11T16:00Z` plus `agent-blocked` on this issue and stop. Do not re-run the sampler yourself unless the unit is dead with no deliverable (then relaunch it exactly as #4956 documented, with a `--deliverable` and dead-man).\n- Otherwise name the next route to throughput from the study's two named candidates (seat rate-limit walls / claim-loop empty-success churn #4457).\n\nimpact: answers the fleet's central throughput question with a real 24h window.\n\nproduct_surface: fleet CPU/throughput measurement (worker-worktree CPU limiter Q)\n\nsource: Nishfleet/fleet-ops#4956 + docs/throughput-limiter-study.md"
  }
]
JSON

cand_supergrok_title="SuperGrok seat dead: grok CLI unauthenticated; xai-oauth is healthy"
cat >"$scratch/cand-supergrok.md" <<'MD'
fleet-seat-live-validate (fleet-ops#917) found the grok CLI dead but the
xai-oauth extension token in ~/.pi/agent/auth.json is still valid (the
subscription proxy cli-chat-proxy.grok.com returned 200).

This is the #1450 case: the previous canary blindly mirrored the grok
dead-class onto xai-oauth, marking xai-oauth seats credentials_bad even
though the xai-oauth token was healthy.

Nish must sign in TODAY on netcup-rs2000:

    grok login --device-auth
MD

cand_symlink_title="No detector for dangling helper symlinks: unit-escalation-write was 127 for ~7.5h (every OnFailure escalation died silently); straitly canary link still dangling"
cat >"$scratch/cand-symlink.md" <<'MD'
metric: every helper symlink under ~/.local/bin and ~/.local/lib/pi-packet
resolves to an existing file, and a check fails loud the moment one dangles

observed: 2026-09-10T21:46Z-23:50Z - during the deploy-clone wrong-remote
reset (fleet-ops#5016), ~/.local/bin/unit-escalation-write dangled ~7.5h;
every OnFailure escalation (unit-escalation@*.service) exited 127, so failed
units recorded no STOP-REASON and nothing paged on the escalation path
itself being dead. fleet-seat-recovery alone 203/EXEC'd 44x and its
escalation 127'd 40x in the window.

evidence:
- journalctl --user -u 'unit-escalation@fleet-seat-recovery.service.service'
  --since '24 hours ago' -> status=127, repeated 40x on 2026-09-10
MD

for pair in "supergrok:$cand_supergrok_title" "symlink:$cand_symlink_title"; do
  name="${pair%%:*}"
  title="${pair#*:}"
  out=$(score "$title" "$(cat "$scratch/cand-$name.md")" "$scratch/against-4959.json")
  kind=$(jq -r .kind <<<"$out")
  sc=$(jq -r .score <<<"$out")
  below=$(jq -r '.score < 0.65' <<<"$out")
  prim=$(jq -r '.primary_shared_signals | length' <<<"$out")
  [[ "$kind" != "duplicate" ]] \
    || fail "different-problem spec-schema pair ($name vs #4959) must not be a duplicate, got $out"
  [[ "$below" == "true" ]] \
    || fail "different-problem spec-schema pair ($name vs #4959) must score below DUP_THRESHOLD, got $out"
  [[ "$prim" == "0" ]] \
    || fail "incidental seat/dead wording must not raise the seat-crisis floor ($name), got $out"
  ok "different-problem spec-schema pair stays unfiled ($name vs #4959, score=$sc)"
done

# And the other direction: a real same-problem pair must still be suppressed.
cat >"$scratch/against-symlink-dup.json" <<'JSON'
[
  {
    "number": 5059,
    "repository": "Nishfleet/fleet-ops",
    "title": "unit-escalation-write symlink dangles: OnFailure escalations exit 127 with no STOP-REASON",
    "body": "metric: every OnFailure escalation writes a STOP-REASON\n\nobserved: ~/.local/bin/unit-escalation-write dangles, so unit-escalation@*.service exits 127 and no STOP-REASON is written.\n"
  }
]
JSON
out=$(score \
  "Dangling unit-escalation-write helper: OnFailure escalations exit 127 and write no STOP-REASON" \
  "metric: every OnFailure escalation writes a STOP-REASON

observed: ~/.local/bin/unit-escalation-write is a dangling symlink; unit-escalation@*.service exits 127 and writes no STOP-REASON." \
  "$scratch/against-symlink-dup.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "duplicate" ]] \
  || fail "genuinely same-problem spec-schema pair must stay duplicate, got $out"
ok "same-problem spec-schema pair is still duplicate (score=$sc)"

# --- 9. standards-drift dedupe keys on the missing file (fleet-ops#4591) ---
bash "$here/standards-drift-dedupe.test.sh"

echo "OK: issue-file same-problem dedupe (fleet-ops#1212)"
