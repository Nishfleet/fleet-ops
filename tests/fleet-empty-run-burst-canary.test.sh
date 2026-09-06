#!/usr/bin/env bash
# tests/fleet-empty-run-burst-canary.test.sh
#
# Proves the empty-run burst canary (fleet-ops#2666) offline:
#   1. Snapshot missing -> exit 1 (watcher broken).
#   2. Snapshot unparseable -> exit 1.
#   3. empty_runs=0 / samples=[] -> exit 0, OK, no file action.
#   4. empty_runs=2 (below threshold) -> exit 0, no file action.
#   5. empty_runs=6 with healthy-seat sample + 0B err -> exit 0 (alarm
#      with observe-to-open fired), file_finding is called once.
#   6. empty_runs=6 but empty_run_samples=[] -> exit 1 (watcher
#      inconsistent) AND a `watcher-broken` issue is filed.
#   7. Cause classification: provider-no-op, provider-partial,
#      hang-watchdog, mid-session-death, empty-bench, unknown.
#   8. Healthy-seat bucketing: a sample on a healthy seat is bucketed
#      into healthy_seat_buckets, the issue title carries the seat
#      (kind=healthy-seat-burst).
#   9. Provider-only burst: a sample on a non-healthy seat is bucketed
#      into seat_buckets only (kind=provider-burst, no healthy seat
#      named in the title).
#  10. Dedup: a second tick with the burst still active does not file a
#      second issue.
#  11. Observe-to-close: a previous-burst tick (samples empty) closes
#      any open canary-filed issue with a `resolved-at:` comment.
#  12. Heartbeat-tier1 wires the canary and propagates rc>=2 (MANIFEST
#      dest missing fails loud; burst tick alarm does not).
#  13. pi-issue-run parse_unit / parse_seat_from_err helpers handle the
#      live watch-log and err-file shapes used in #2666.
#  14. Production seat-caps / heartbeat / opus-heartbeat snapshot are
#      still parseable after the new canary is added (regression
#      check).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-empty-run-burst-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$manifest" ]] || fail "missing: $manifest"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t empty-burst-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"

export HOME="$scratch/home"
mkdir -p "$HOME"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_EMPTY_BURST_REPO="Nishfleet/fleet-ops"
export FLEET_EMPTY_BURST_FILE=1
export FLEET_OPS_REPO="$repo_root"

# Stub gh to log calls and return canned JSON for issue list / create / close.
gh_log="$scratch/gh.log"
gh_close_log="$scratch/gh.close.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue close"*)
    printf '%s\n' "$*" >>"${GH_CLOSE_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export GH_CLOSE_LOG="$gh_close_log"
export PATH="$scratch:$PATH"

# Stub fleet-issue-file to log create calls so we can assert the title/body.
issue_file_log="$scratch/issue-file.log"
issue_file="$scratch/fleet-issue-file"
cat >"$issue_file" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "ARGS=$*" >>"${ISSUE_FILE_LOG:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/999"
exit 0
FAKE
chmod +x "$issue_file"
export FLEET_ISSUE_FILE="$issue_file"
export ISSUE_FILE_LOG="$issue_file_log"
# Prepend scratch to PATH so the canary's `command -v` finds our stub.
export PATH="$scratch:$PATH"

# Receipts dir + per-unit err files for classification tests.
receipts="$scratch/pi-issues"
mkdir -p "$receipts"
export FLEET_EMPTY_BURST_RECEIPTS="$receipts"

# Seat-health ledger stub for healthy-vs-faulted classification: flat
# per-seat files at <provider>__<model-sanitised>.json, the production
# agent-state/lanes/seats shape (matches fleet-gap-closure-auditor).
seat_dir="$scratch/seats"
mkdir -p "$seat_dir"
export FLEET_EMPTY_BURST_SEAT_HEALTH_DIR="$seat_dir"

write_snap() {
    cat >"$scratch/snapshot.json"
}

write_seat_health() {
    # args: <id> <health_class> [http_status] [provider] [model]
    # provider/model default to the id parts (unsanitised seat id) so the
    # fleet-ops#3585 disagree scan can name the real seat. Extra fields
    # are harmless to the pre-existing scenarios that ignore them.
    local id="$1" cls="$2" http="${3:-0}" prov="${4:-}" mod="${5:-}"
    if [[ -z "$prov" || -z "$mod" ]]; then
        prov="${id%%__*}"
        mod="${id#*__}"
    fi
    cat >"$seat_dir/${id}.json" <<JSON
{
  "provider": "$prov",
  "model": "$mod",
  "health_class": "$cls",
  "http_status": $http,
  "observed_at": "2026-09-01T17:33:00Z"
}
JSON
}

# write_spawn_bench <id> <failure_mode> <usable_at> — write a clobber-proof
# spawn-bench marker (the mark_seat_empty_run / mark_seat_spawn_fail shape)
# in the same seat-health dir the canary scans. fleet-ops#3585.
write_spawn_bench() {
    local id="$1" mode="$2" usable="$3"
    cat >"$seat_dir/${id}.spawn-bench.json" <<JSON
{
  "provider": "test",
  "model": "test",
  "usable_at": "$usable",
  "reason": "test",
  "written_at": "2026-09-01T17:00:00Z",
  "backoff_s": 900,
  "failure_mode": "$mode",
  "consecutive_failure_count": 1,
  "writer": "test"
}
JSON
}

write_err() {
    local unit="$1" body="$2"
    printf '%s' "$body" >"$receipts/${unit}.err"
}

# 1. Snapshot missing
export FLEET_EMPTY_BURST_SNAPSHOT="$scratch/does-not-exist.json"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "scenario 1: missing snapshot, expected exit 1, got $rc"
grep -q 'EMPTY-BURST-WATCHER-BROKEN' "$triage" || fail "scenario 1: expected WATCHER-BROKEN LOUD, got: $(cat "$triage")"
ok "scenario 1: missing snapshot -> exit 1, LOUD watcher-broken"

# 2. Snapshot unparseable
printf 'not json\n' >"$scratch/snapshot.json"
export FLEET_EMPTY_BURST_SNAPSHOT="$scratch/snapshot.json"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "scenario 2: unparseable snapshot, expected exit 1, got $rc"
grep -q 'EMPTY-BURST-WATCHER-BROKEN' "$triage" || fail "scenario 2: expected WATCHER-BROKEN LOUD, got: $(cat "$triage")"
ok "scenario 2: unparseable snapshot -> exit 1, LOUD watcher-broken"

# 3. clean tick (counter=0, samples=[]) -> exit 0, no file action
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 0,
    "empty_run_samples": []
  }
}
JSON
: >"$issue_file_log"
: >"$gh_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 3: clean tick, expected exit 0, got $rc"
[[ ! -s "$issue_file_log" ]] || fail "scenario 3: clean tick must not file, got: $(cat "$issue_file_log")"
grep -q 'no burst' "$scratch/err" || fail "scenario 3: expected 'no burst' log, got: $(cat "$scratch/err")"
ok "scenario 3: clean tick -> exit 0, no file action"

# 4. below threshold (counter=2, samples non-empty) -> exit 0, no file
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 2,
    "empty_run_samples": [
      "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"
    ]
  }
}
JSON
write_err "fleet-ops-2627" "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op
[2026-09-01T14:11:19Z] empty-run: marked openrouter/deepseek/deepseek-v4-flash-0731 unusable until 2026-09-01T14:26:19Z (reason=pi-issue:fleet-ops-2627:provider-no-op:stdout=0B, backoff=900s, count=1)
"
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 4: below threshold, expected exit 0, got $rc"
[[ ! -s "$issue_file_log" ]] || fail "scenario 4: below threshold must not file, got: $(cat "$issue_file_log")"
ok "scenario 4: below threshold -> exit 0, no file action"

# 5. healthy-seat burst (counter=6, healthy seat sample, provider-no-op
#    err) -> exit 0, file_finding fires once.
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 6,
    "empty_run_samples": [
      "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"
    ]
  }
}
JSON
write_err "fleet-ops-2627" "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op
[2026-09-01T14:11:19Z] empty-run: marked openrouter/deepseek/deepseek-v4-flash-0731 unusable until 2026-09-01T14:26:19Z (reason=pi-issue:fleet-ops-2627:provider-no-op:stdout=0B, backoff=900s, count=1)
"
write_seat_health "openrouter__deepseek_deepseek-v4-flash-0731" healthy 200
: >"$issue_file_log"
: >"$gh_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 5: burst, expected exit 0, got $rc"
[[ -s "$issue_file_log" ]] || fail "scenario 5: burst must file, got empty log"
grep -q 'healthy-seat-burst' "$issue_file_log" || fail "scenario 5: title kind=healthy-seat-burst, got: $(cat "$issue_file_log")"
grep -q 'openrouter/deepseek/deepseek-v4-flash-0731' "$issue_file_log" || fail "scenario 5: title must name the healthy seat"
grep -q 'provider-no-op' "$issue_file_log" || fail "scenario 5: body must name the cause class"
grep -q 'empty-run-burst-canary: healthy-seat-burst' "$issue_file_log" || fail "scenario 5: marker missing on the body"
grep -q 'class=healthy' "$issue_file_log" || fail "scenario 5: body must cite seat health evidence"
ok "scenario 5: healthy-seat burst -> exit 0, file kind=healthy-seat-burst with evidence"

# 6. watcher inconsistent: counter=6, samples=[] -> exit 1, watcher-broken
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 6,
    "empty_run_samples": []
  }
}
JSON
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "scenario 6: watcher-inconsistent, expected exit 1, got $rc"
[[ -s "$issue_file_log" ]] || fail "scenario 6: watcher-broken must file, got empty log"
grep -q 'watcher-broken' "$issue_file_log" || fail "scenario 6: marker watcher-broken missing"
grep -q 'EMPTY-BURST-WATCHER-BROKEN' "$triage" || fail "scenario 6: LOUD tag missing on triage"
ok "scenario 6: watcher-inconsistent -> exit 1, file watcher-broken"

# 7. cause classification across the five classes + unknown.
# Each entry: <unit> <TAB> <expected_cause> <TAB> <err_body>. Using
# a TSV is the only safe shape — a `|` body has lines starting with
# `pi-issue-run:` etc. that break the `|` split.
#
# Compose the err bodies with printf '%s\n' to keep newlines literal.
write_err "fleet-ops-noop"     "[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-noop pi exited 0 but stdout=0B (< 20B) — provider no-op
"
write_err "fleet-ops-partial"  "EXTLOAD-OK extension=packet-verdict mode=print-safe
PACKET-VERDICT tools=80 class=worked
[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-partial pi exited 0 but stdout=0B
"
write_err "fleet-ops-hang"     "EXTLOAD-OK extension=packet-verdict mode=print-safe
PACKET-VERDICT tools=22 class=worked
[2026-09-01T01:00:00Z] pi-issue-run: PI HANG WATCHDOG — pi on seat=foo did not finalize within 2520s; killed.
[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-hang PI HANG WATCHDOG on seat=foo after 2520s — killed and re-seating
"
write_err "fleet-ops-mid"      "EXTLOAD-OK extension=packet-verdict mode=print-safe
PACKET-VERDICT tools=19 class=worked
[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-mid pi exited 143 on foo (1703s, spawn_fail=0) — systemd will restart with a new seat
"
write_err "fleet-ops-bench"    "[2026-09-01T01:00:00Z] empty-run: marked openrouter/deepseek/deepseek-v4-flash-0731 unusable until 2026-09-01T01:15:00Z (reason=pi-issue:fleet-ops-bench:provider-no-op:stdout=0B, backoff=900s, count=2)
[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-bench seat openrouter/deepseek/deepseek-v4-flash-0731 marked (empty_run); will skip on next in-process re-seat and on intake re-spawn
"
# The 0B run itself is archived in an older err; this err holds only the
# bench follow-up -> empty-bench (seat was benched for a PRIOR no-op).
write_err "fleet-ops-unknown"  "no markers here at all, just nothing
"
# Build one snapshot that lists all 6 units and assert the table row
# each cause lands in matches.
{
    printf '{\n  "ts": "2026-09-01T16:30:04Z",\n  "waste": {\n    "empty_runs_last_2h": 6,\n    "empty_run_samples": [\n'
    sep=""
    for u in fleet-ops-noop fleet-ops-partial fleet-ops-hang fleet-ops-mid fleet-ops-bench fleet-ops-unknown; do
        printf '%s      "[2026-09-01T01:00:00Z] pi-issue-run: %s pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"\n' \
            "$sep" "$u"
        sep=","
    done
    printf '    ]\n  }\n}\n'
} >"$scratch/snapshot.json"
# Mark openrouter as healthy so the healthy-seat-bucket fires.
write_seat_health "openrouter__deepseek_deepseek-v4-flash-0731" healthy 200
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 7: classification, expected exit 0, got $rc"
for c in provider-no-op provider-partial hang-watchdog mid-session-death empty-bench unknown; do
    grep -q "| $c |" "$issue_file_log" \
        || fail "scenario 7: expected cause=$c in body, got: $(cat "$issue_file_log" | head -20)"
done
ok "scenario 7: all 5 cause classes + unknown classify correctly"

# 8. healthy-seat title
grep -q 'Empty-run burst on healthy seat' "$issue_file_log" || fail "scenario 8: title must name 'healthy seat', got: $(cat "$issue_file_log" | head -5)"
grep -q 'openrouter/deepseek/deepseek-v4-flash-0731' "$issue_file_log" || fail "scenario 8: title must name the seat"
ok "scenario 8: title carries the healthy seat name"

# 9. provider-only burst (no healthy seat) -> kind=provider-burst
rm -f "$receipts"/*.err
write_err "fleet-ops-foo" "[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-foo pi exited 0 but stdout=0B (< 20B)
[2026-09-01T01:00:00Z] empty-run: marked straitly/deepseek/deepseek-v4-pro unusable until 2026-09-01T01:15:00Z (reason=pi-issue:fleet-ops-foo:provider-no-op:stdout=0B, backoff=900s, count=1)
"
write_seat_health "straitly__deepseek_deepseek-v4-pro" quota_exhausted 402
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 6,
    "empty_run_samples": [
      "[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-foo pi exited 0 but stdout=0B (< 20B) — provider no-op"
    ]
  }
}
JSON
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 9: provider-only burst, expected exit 0, got $rc"
grep -q 'provider-burst' "$issue_file_log" || fail "scenario 9: kind=provider-burst, got: $(cat "$issue_file_log")"
grep -q 'No samples landed on a health_class=healthy' "$issue_file_log" || fail "scenario 9: body must say no healthy seat"
ok "scenario 9: provider-only burst -> kind=provider-burst"

# 10. dedup: second tick with the burst still active must NOT file.
# Use a healthy-seat sample so the canary's kind is `healthy-seat-burst`,
# and stub gh issue list with the matching marker.
write_seat_health "openrouter__deepseek_deepseek-v4-flash-0731" healthy 200
write_err "fleet-ops-2627" "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op
[2026-09-01T14:11:19Z] empty-run: marked openrouter/deepseek/deepseek-v4-flash-0731 unusable until 2026-09-01T14:26:19Z (reason=pi-issue:fleet-ops-2627:provider-no-op:stdout=0B, backoff=900s, count=1)
"
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 6,
    "empty_run_samples": [
      "[2026-09-01T14:11:19Z] pi-issue-run: fleet-ops-2627 pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"
    ]
  }
}
JSON
cat >"$scratch/open-issues.json" <<'JSON'
[
  {
    "number": 4321,
    "body": "Empty-run burst…\n\nempty-run-burst-canary: healthy-seat-burst\n"
  }
]
JSON
export GH_OPEN_ISSUES="$scratch/open-issues.json"
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 10: dedup tick, expected exit 0, got $rc"
[[ ! -s "$issue_file_log" ]] || fail "scenario 10: dedup must not file, got: $(cat "$issue_file_log")"
ok "scenario 10: dedup — second burst tick does not re-file"

# 11. observe-to-close: a previous-burst tick (samples empty) closes
#     the open canary-filed issue.
rm -f "$scratch/open-issues.json.bak"
cp "$scratch/open-issues.json" "$scratch/open-issues.json.bak"
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 0,
    "empty_run_samples": []
  }
}
JSON
: >"$gh_close_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 11: observe-to-close, expected exit 0, got $rc"
grep -q 'issue close 4321' "$gh_close_log" || fail "scenario 11: must close #4321, got: $(cat "$gh_close_log")"
grep -q 'observe-to-close' "$gh_close_log" || fail "scenario 11: close comment must say 'observe-to-close'"
ok "scenario 11: observe-to-close drains the open canary-filed issue"

# Restore the burst snapshot for the next scenario.
cp "$scratch/open-issues.json.bak" "$scratch/open-issues.json"
rm -f "$scratch/open-issues.json.bak"

# 12. heartbeat-tier1 wires the canary and propagates rc>=2 when the
#     helper is missing. Make the canary crash by feeding an empty
#     SNAPSHOT path AND failing jq (which can't happen on a normal
#     system). Simulate a real crash by setting FLEET_EMPTY_BURST_SNAPSHOT
#     to a binary that jq cannot read.
export FLEET_EMPTY_BURST_SNAPSHOT="$scratch/snapshot.json"
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": { "empty_runs_last_2h": 0, "empty_run_samples": [] }
}
JSON
# Check the tier-1 contains the canary block (grep for the bin var).
grep -q 'EMPTY_BURST_CANARY_BIN' "$tier1" || fail "scenario 12: tier-1 must wire the canary"
grep -q 'fleet-empty-run-burst-canary' "$tier1" || fail "scenario 12: tier-1 must name the canary"
# Check the MANIFEST ships the canary.
grep -q '^bin/fleet-empty-run-burst-canary' "$manifest" || fail "scenario 12: MANIFEST must install the canary"
ok "scenario 12: heartbeat-tier1 wires the canary + MANIFEST installs it"

# 13. parse_unit / parse_seat_from_err against live shapes.
# Use a fresh canary invocation that just runs the helper path.
# Clear GH_OPEN_ISSUES so the canary is NOT in dedup mode (the prior
# scenarios stubbed an open issue; this scenario verifies the canary
# fires fresh on a live watch-log shape).
export GH_OPEN_ISSUES=""
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 3,
    "empty_run_samples": [
      "[2026-09-01T13:16:26Z] pi-issue-run: fleet-ops-2614 pi exited 143 on opencode/nemotron-3-ultra-free (1703s, spawn_fail=0) — systemd will restart with a new seat"
    ]
  }
}
JSON
write_err "fleet-ops-2614" "[2026-09-01T13:16:26Z] pi-issue-run: fleet-ops-2614 pi exited 143 on opencode/nemotron-3-ultra-free (1703s, spawn_fail=0) — systemd will restart with a new seat
EXTLOAD-OK extension=packet-verdict mode=print-safe
PACKET-VERDICT tools=19 class=worked
"
write_seat_health "opencode__nemotron-3-ultra-free" healthy 200
: >"$issue_file_log"
set +e
"$bin" >"$scratch/out" 2>"$scratch/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario 13: live-shape sample, expected exit 0, got $rc"
grep -q 'fleet-ops-2614' "$issue_file_log" || fail "scenario 13: body must include the unit"
grep -q 'opencode/nemotron-3-ultra-free' "$issue_file_log" || fail "scenario 13: body must include the seat"
grep -q 'mid-session-death' "$issue_file_log" || fail "scenario 13: must classify exit-143 as mid-session-death"
ok "scenario 13: live watch-log + err-file shape parse correctly"

# 14. regression: production seat-caps / heartbeat / snapshot
#     (opus-heartbeat) are still parseable after the canary was added.
# Use jq to read each; fail if any of them is now broken by the new
# tier-1 wiring.
[[ -f "$repo_root/config/seat-caps.json" ]] || fail "scenario 14: seat-caps.json missing"
jq -e 'type == "object" and (.providers | type == "object")' "$repo_root/config/seat-caps.json" >/dev/null \
    || fail "scenario 14: production seat-caps.json no longer parseable"
[[ -f "$repo_root/bin/fleet-heartbeat-tier1" ]]
bash -n "$repo_root/bin/fleet-heartbeat-tier1" || fail "scenario 14: tier-1 has a bash syntax error"
# The live snapshot is a sanity check, not a fail; if missing, skip.
if [[ -f "$HOME/.local/state/opus-heartbeat/snapshot.json" ]]; then
    jq -e 'type == "object" and (.waste | type == "object")' "$HOME/.local/state/opus-heartbeat/snapshot.json" >/dev/null \
        || fail "scenario 14: live opus-heartbeat snapshot no longer parseable"
fi
ok "scenario 14: regression — production files still parse after the canary was added"

# 15. canary rc=0 on a clean tick; rc=1 on a watcher-broken tick;
#     rc=0 on a burst tick (alarm, not fail-loud — fleet-ops#1116).
# 15a. clean
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": { "empty_runs_last_2h": 0, "empty_run_samples": [] }
}
JSON
set +e; "$bin" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 15a: clean tick, expected exit 0, got $rc"
# 15b. watcher broken (counter non-zero, samples empty)
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": { "empty_runs_last_2h": 5, "empty_run_samples": [] }
}
JSON
set +e; "$bin" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 1 ]] || fail "scenario 15b: watcher broken, expected exit 1, got $rc"
# 15c. burst (with sample) — alarm, not fail-loud
rm -f "$receipts"/*.err
write_err "fleet-ops-zzz" "[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-zzz pi exited 0 but stdout=0B
[2026-09-01T01:00:00Z] empty-run: marked openrouter/deepseek/deepseek-v4-flash-0731 unusable until 2026-09-01T01:15:00Z
"
write_snap <<'JSON'
{
  "ts": "2026-09-01T16:30:04Z",
  "waste": {
    "empty_runs_last_2h": 5,
    "empty_run_samples": [
      "[2026-09-01T01:00:00Z] pi-issue-run: fleet-ops-zzz pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"
    ]
  }
}
JSON
: >"$issue_file_log"
set +e; "$bin" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 15c: burst tick, expected exit 0 (alarm, not fail-loud), got $rc"
ok "scenario 15: rc 0/1/0 across clean/broken/burst ticks matches the alarm-vs-failure pattern"

# 16. the seat-health unknown branch (file missing) classifies
#     cleanly without crashing. Clear GH_OPEN_ISSUES so the canary
#     files fresh (the prior scenarios left an open issue stubbed
#     for dedup/observe-to-close).
export GH_OPEN_ISSUES=""
rm -rf "$seat_dir"
: >"$issue_file_log"
set +e; "$bin" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 16: missing seat-health, expected exit 0, got $rc"
grep -q 'unknown' "$issue_file_log" || fail "scenario 16: body must cite 'unknown' seat class"
ok "scenario 16: missing seat-health does not crash the canary"

# 17. fleet-ops#3585 Part 1: a seat with a LIVE spawn-bench marker AND
#     a ledger that says healthy is classified transient_fault by the
#     canary's read helpers (the marker wins), so a burst on that seat
#     is kind=provider-burst (benched seat), NOT healthy-seat-burst.
#     The live 2026-09-05 ollama/deepseek-v4-flash:0731 case: ledger
#     healthy, marker wall live, canary filed "healthy-seat-burst".
future_usable=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ)
past_usable=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ)
rm -rf "$seat_dir"
mkdir -p "$seat_dir"
export GH_OPEN_ISSUES=""
write_seat_health "ollama__deepseek-v4-flash_0731" healthy 200
write_spawn_bench "ollama__deepseek-v4-flash_0731" empty_run "$future_usable"
rm -f "$receipts"/*.err
write_err "fleet-ops-3585a" "[2026-09-05T10:29:58Z] pi-issue-run: fleet-ops-3585a pi exited 0 but stdout=0B (< 20B) — provider no-op
[2026-09-05T10:29:58Z] empty-run: marked ollama/deepseek-v4-flash:0731 unusable until $future_usable (reason=pi-issue:fleet-ops-3585a:provider-no-op:stdout=0B, backoff=86400s, count=6)
"
write_snap <<JSON
{
  "ts": "2026-09-05T10:30:04Z",
  "waste": {
    "empty_runs_last_2h": 6,
    "empty_run_samples": [
      "[2026-09-05T10:29:58Z] pi-issue-run: fleet-ops-3585a pi exited 0 but stdout=0B (< 20B) — provider no-op, benching seat (empty_run, flat cooldown) and re-seating in-process"
    ]
  }
}
JSON
: >"$issue_file_log"
set +e; "$bin" >"$scratch/out" 2>"$scratch/err"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 17: benched-seat burst, expected exit 0, got $rc"
# The seat is benched (marker live) so it must NOT be classified healthy.
grep -q 'healthy-seat-burst' "$issue_file_log" \
    && fail "scenario 17: benched seat must NOT be healthy-seat-burst, got: $(cat "$issue_file_log" | head -5)"
grep -q 'provider-burst' "$issue_file_log" \
    || fail "scenario 17: benched seat burst must be kind=provider-burst, got: $(cat "$issue_file_log" | head -5)"
ok "scenario 17: live bench marker + healthy ledger -> provider-burst (not healthy-seat-burst)"

# 18. fleet-ops#3585 Part 1b: once the marker wall EXPIRES, the canary
#     falls back to the ledger — a healthy ledger with no live wall is
#     healthy again (the bench aged out, the seat recovered).
write_spawn_bench "ollama__deepseek-v4-flash_0731" empty_run "$past_usable"
: >"$issue_file_log"
set +e; "$bin" >"$scratch/out" 2>"$scratch/err"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 18: expired-bench burst, expected exit 0, got $rc"
grep -q 'healthy-seat-burst' "$issue_file_log" \
    || fail "scenario 18: expired bench + healthy ledger -> healthy-seat-burst, got: $(cat "$issue_file_log" | head -5)"
ok "scenario 18: expired bench marker -> ledger healthy wins again (healthy-seat-burst)"

# 19. fleet-ops#3585 Part 2: the disagreement scan flags a seat that is
#     benched (live marker) AND reported healthy by the ledger, even on
#     a CLEAN tick (no burst). LOUD triage tag + file_finding fire.
rm -rf "$seat_dir"
mkdir -p "$seat_dir"
export GH_OPEN_ISSUES=""
write_seat_health "ollama__deepseek-v4-flash_0731" healthy 200 "ollama" "deepseek-v4-flash:0731"
write_spawn_bench "ollama__deepseek-v4-flash_0731" empty_run "$future_usable"
write_snap <<'JSON'
{
  "ts": "2026-09-05T10:30:04Z",
  "waste": { "empty_runs_last_2h": 0, "empty_run_samples": [] }
}
JSON
: >"$triage"
: >"$issue_file_log"
set +e; "$bin" >"$scratch/out" 2>"$scratch/err"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 19: disagree scan on clean tick, expected exit 0 (alarm), got $rc"
grep -q 'SEAT-BENCH-HEALTH-DISAGREE' "$triage" \
    || fail "scenario 19: expected SEAT-BENCH-HEALTH-DISAGREE LOUD tag, got: $(cat "$triage")"
grep -q 'seat-bench-health-disagree' "$issue_file_log" \
    || fail "scenario 19: expected seat-bench-health-disagree finding filed, got: $(cat "$issue_file_log" | head -5)"
grep -q 'ollama/deepseek-v4-flash:0731' "$issue_file_log" \
    || fail "scenario 19: finding must name the disagreeing seat"
ok "scenario 19: benched + healthy -> SEAT-BENCH-HEALTH-DISAGREE LOUD + filed on clean tick"

# 20. fleet-ops#3585 Part 2b: no disagreement -> no LOUD tag, no file.
#     A seat whose marker wall EXPIRED is not benched anymore, so a
#     healthy ledger for it is NOT a disagreement.
rm -rf "$seat_dir"
mkdir -p "$seat_dir"
export GH_OPEN_ISSUES=""
write_seat_health "ollama__deepseek-v4-flash_0731" healthy 200 "ollama" "deepseek-v4-flash:0731"
write_spawn_bench "ollama__deepseek-v4-flash_0731" empty_run "$past_usable"
write_snap <<'JSON'
{
  "ts": "2026-09-05T10:30:04Z",
  "waste": { "empty_runs_last_2h": 0, "empty_run_samples": [] }
}
JSON
: >"$triage"
: >"$issue_file_log"
set +e; "$bin" >"$scratch/out" 2>"$scratch/err"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "scenario 20: clean disagree scan, expected exit 0, got $rc"
grep -q 'SEAT-BENCH-HEALTH-DISAGREE' "$triage" \
    && fail "scenario 20: expired bench must NOT fire disagree, got: $(cat "$triage")"
[[ ! -s "$issue_file_log" ]] \
    || fail "scenario 20: no disagree -> no file, got: $(cat "$issue_file_log" | head -5)"
ok "scenario 20: expired bench + healthy ledger -> no disagree (clean)"

echo "OK: fleet-empty-run-burst-canary — 20 scenarios"
