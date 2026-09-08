#!/usr/bin/env bash
# tests/signal-reconcile.test.sh
#
# Proves the detector->queue reconciler (fleet-ops#362):
#   1. LOUD alarm with no open issue -> auto-filed.
#   2. LOUD alarm with an existing open issue -> heartbeat comment, no duplicate.
#   3. Alarm that goes green -> observe-to-close (gh issue close).
#   4. Cap exceeded -> files a cap alarm and stops over-filing.
#   5. Green / throughput / OK lines are skipped.
#   6. UNIT-FAILED with multiple units -> one issue per unit.
#   7. Routing: VIOLATION gets escalate-senior, PENDING gets agent-ready.
#   8. Daily heartbeat throttle: a recent comment blocks a second one.
#   9. Unclaimed-stall: agent-ready issue past stall hours is re-routed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/detector-queue-reconciler.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# Fake fleet-issue-file wrapper.
cat > "$tmp/fleet-issue-file" <<'PY'
#!/usr/bin/env python3
import os, sys, json
log = os.environ.get("FAKE_FLEET_ISSUE_FILE_LOG", "/dev/null")
out = {}
i = 1
while i < len(sys.argv):
    if sys.argv[i] in ("-R", "--repo"):
        out["repo"] = sys.argv[i+1]; i += 2
    elif sys.argv[i] == "--title":
        out["title"] = sys.argv[i+1]; i += 2
    elif sys.argv[i] == "--body":
        out["body"] = sys.argv[i+1]; i += 2
    elif sys.argv[i] == "--label":
        out.setdefault("labels", []).append(sys.argv[i+1]); i += 2
    else:
        i += 1
with open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps(out) + "\n")
print("#999")
PY
chmod +x "$tmp/fleet-issue-file"

# Fake gh CLI.
cat > "$tmp/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
log = os.environ.get("FAKE_GH_LOG", "/dev/null")
with open(log, "a", encoding="utf-8") as f:
    f.write("gh " + " ".join(sys.argv[1:]) + "\n")

if sys.argv[1:3] == ["issue", "list"]:
    path = os.environ.get("FAKE_GH_OPEN_ISSUES", "")
    if not path:
        print("[]")
    else:
        with open(path, encoding="utf-8") as f:
            print(f.read())
    sys.exit(0)

# comment, close, edit just need to look successful.
if sys.argv[1] == "issue" and sys.argv[2] in ("comment", "close", "edit"):
    sys.exit(0)

sys.exit(1)
PY
chmod +x "$tmp/gh"

common_env=(
    "FLEET_ISSUE_FILE=$tmp/fleet-issue-file"
    "GH=$tmp/gh"
    "FAKE_FLEET_ISSUE_FILE_LOG=$tmp/filed.jsonl"
    "FAKE_GH_LOG=$tmp/gh.log"
)

run() {
    env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$1" \
        python3 "$lib" --triage "$2" --tick-start "2026-08-28T13:30:00Z" \
        --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" || true
}

# ---------------------------------------------------------------------------
# 1. File a new alarm.
# ---------------------------------------------------------------------------
cat > "$tmp/empty.json" <<'EOF'
[]
EOF
cat > "$tmp/triage1.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-PENDING] terminal delivery not wired (#76)
EOF
run "$tmp/empty.json" "$tmp/triage1.md" > "$tmp/summary1.json"
jq -e '.filed == 1 and .deduped == 0 and .closed == 0' "$tmp/summary1.json" >/dev/null \
    || fail "scenario 1: expected one filed"
[[ $(jq -c '.' "$tmp/filed.jsonl" | wc -l) -eq 1 ]] || fail "scenario 1: fleet-issue-file called more than once"
grep -q "loud/escalation-canary-pending" "$tmp/filed.jsonl" || fail "scenario 1: signal missing in body"
grep -q '"agent-ready"' "$tmp/filed.jsonl" || fail "scenario 1: routing label wrong"
ok "scenario 1: one new alarm filed"

# ---------------------------------------------------------------------------
# 2. Dedupe + heartbeat comment when issue already open.
# ---------------------------------------------------------------------------
cat > "$tmp/open2.json" <<'EOF'
[{"number": 123, "body": "signal: loud/escalation-canary-pending/terminal-delivery-wired", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open2.json" "$tmp/triage1.md" > "$tmp/summary2.json"
jq -e '.filed == 0 and .deduped == 1 and .heartbeat_comments == 1' "$tmp/summary2.json" >/dev/null \
    || fail "scenario 2: expected dedup and heartbeat comment"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] || fail "scenario 2: should not file"
grep -q "issue comment" "$tmp/gh.log" || fail "scenario 2: expected gh issue comment"
ok "scenario 2: existing issue gets heartbeat comment"

# ---------------------------------------------------------------------------
# 3. Alarm gone -> observe-to-close.
# ---------------------------------------------------------------------------
cat > "$tmp/open3.json" <<'EOF'
[{"number": 124, "body": "signal: loud/escalation-canary-pending/old-alarm-wired", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
cat > "$tmp/triage3.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-PENDING] terminal delivery not wired (#76)
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open3.json" "$tmp/triage3.md" > "$tmp/summary3.json"
jq -e '.filed == 1 and .deduped == 0 and .closed == 1' "$tmp/summary3.json" >/dev/null \
    || fail "scenario 3: expected file new + close old"
grep -q "issue close" "$tmp/gh.log" || fail "scenario 3: expected gh issue close"
ok "scenario 3: missing alarm is closed (observe-to-close)"

# ---------------------------------------------------------------------------
# 4. Cap exceeded.
# ---------------------------------------------------------------------------
cat > "$tmp/triage4.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-PENDING] one
[2026-08-28T13:30:01Z] [ESCALATION-CANARY-PENDING] two
[2026-08-28T13:30:02Z] [ESCALATION-CANARY-PENDING] three
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage4.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" --cap 1 > "$tmp/summary4.json" || true
jq -e '.filed == 1 and .capped > 0' "$tmp/summary4.json" >/dev/null \
    || fail "scenario 4: expected one filed and capped"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 1 ]] || fail "scenario 4: cap should stop additional filings"
ok "scenario 4: cap is respected and a cap alarm is emitted"

# ---------------------------------------------------------------------------
# 5. Green lines are skipped.
# ---------------------------------------------------------------------------
cat > "$tmp/triage5.md" <<'EOF'
[2026-08-28T13:30:00Z] [THROUGHPUT] 42 ops
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-OK] violations=0 pending=0
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-EXCLUDED] resilience-drill-stub-restart.service
EOF
true > "$tmp/filed.jsonl"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage5.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary5.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary5.json" >/dev/null \
    || fail "scenario 5: expected no alarms from green lines"
ok "scenario 5: green/throughput/OK lines are skipped"

# ---------------------------------------------------------------------------
# 6. UNIT-FAILED splits by unit.
# ---------------------------------------------------------------------------
cat > "$tmp/triage6.md" <<'EOF'
[2026-08-28T13:30:00Z] [UNIT-FAILED] still failed after repair n=2 :: foo.timer,bar.service
EOF
true > "$tmp/filed.jsonl"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage6.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary6.json"
jq -e '.filed == 2 and .alarm_count == 2' "$tmp/summary6.json" >/dev/null \
    || fail "scenario 6: expected two filed for two units"
grep -q "loud/unit-failed/foo.timer" "$tmp/filed.jsonl" || fail "scenario 6: foo.timer missing"
grep -q "loud/unit-failed/bar.service" "$tmp/filed.jsonl" || fail "scenario 6: bar.service missing"
ok "scenario 6: UNIT-FAILED splits into one issue per unit"

# ---------------------------------------------------------------------------
# 7. Routing labels.
# ---------------------------------------------------------------------------
cat > "$tmp/triage7.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-VIOLATION] signal: escalation-canary/red-on-main-detector-yml red-on-main-detector.yml missing
EOF
true > "$tmp/filed.jsonl"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage7.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary7.json"
jq -e '.filed == 1' "$tmp/summary7.json" >/dev/null || fail "scenario 7: expected filed"
grep -q '"escalate-senior"' "$tmp/filed.jsonl" || fail "scenario 7: missing escalate-senior"
grep -q '"critical-path"' "$tmp/filed.jsonl" || fail "scenario 7: missing critical-path"
ok "scenario 7: VIOLATION routes to escalate-senior + critical-path"

# ---------------------------------------------------------------------------
# 8. Daily heartbeat throttle.
# ---------------------------------------------------------------------------
cat > "$tmp/open8.json" <<'EOF'
[{"number": 125, "body": "signal: loud/escalation-canary-pending/terminal-delivery-wired", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": [{"body": "detector heartbeat: still alarmed", "createdAt": "2026-08-28T13:00:00Z"}]}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/open8.json" \
    python3 "$lib" --triage "$tmp/triage1.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary8.json"
jq -e '.heartbeat_comments == 0' "$tmp/summary8.json" >/dev/null \
    || fail "scenario 8: expected no second heartbeat within 24h"
[[ $(wc -l < "$tmp/gh.log") -eq 0 ]] || fail "scenario 8: should not call gh"
ok "scenario 8: heartbeat throttled to one per day"

# ---------------------------------------------------------------------------
# 9. Unclaimed-stall reroute.
# ---------------------------------------------------------------------------
cat > "$tmp/open9.json" <<'EOF'
[{"number": 126, "body": "signal: loud/escalation-canary-pending/terminal-delivery-wired", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T00:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/open9.json" \
    python3 "$lib" --triage "$tmp/triage1.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary9.json"
jq -e '.rerouted == 1' "$tmp/summary9.json" >/dev/null \
    || fail "scenario 9: expected reroute"
grep -q "issue edit" "$tmp/gh.log" || fail "scenario 9: expected gh issue edit"
ok "scenario 9: unclaimed-stall reroutes to escalate-senior"

# ---------------------------------------------------------------------------
# 9b. DEBUG-PLAYBOOK-MISSING keys on session=, not snippet file tokens
#     (fleet-ops#4512).
# ---------------------------------------------------------------------------
cat > "$tmp/empty9b.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9b.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-MISSING] session=2026-09-08t07-35-48z-0509-1279-abc123 attempts=4 path=/home/nish/.pi/agent/sessions/pi-issue-0509-1279/s.jsonl snippet=agent-cron-run attest-identity-gate _dirty-worktree-audit.py escalation-daily-sweep
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9b.json" "$tmp/triage9b.md" > "$tmp/summary9b.json"
jq -e '.filed == 1' "$tmp/summary9b.json" >/dev/null \
    || fail "scenario 9b: expected one filed"
grep -q "loud/debug-playbook-missing/2026-09-08t07-35-48z-0509-1279-abc123" "$tmp/filed.jsonl" \
    || fail "scenario 9b: signal must key on the session slug, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9b: DEBUG-PLAYBOOK-MISSING keys on session=, not snippet tokens"

# ---------------------------------------------------------------------------
# 9c. DEBUG-PLAYBOOK-GATE-BLOCK keys on session= too (fleet-ops#4516). Same
#     noisy-snippet defect as 9b: the gate LOUD line carries the counted
#     attempt's stdout as `snippet=`, which produced
#     `loud/debug-playbook-gate-block/_dirty-worktree-audit.py`.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9c.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9c.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-GATE-BLOCK] session=2026-09-08t07-35-48z-0509-1279-abc123 attempts=4 snippet=agent-cron-run agent-scheduler-drift-check _dirty-worktree-audit.py escalation-daily-sweep
EOF
true > "$tmp/filed9c.jsonl"
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9c.json" "$tmp/triage9c.md" > "$tmp/summary9c.json"
jq -e '.filed == 1' "$tmp/summary9c.json" >/dev/null \
    || fail "scenario 9c: expected one filed"
grep -q "loud/debug-playbook-gate-block/2026-09-08t07-35-48z-0509-1279-abc123" "$tmp/filed.jsonl" \
    || fail "scenario 9c: signal must key on the session slug, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9c: DEBUG-PLAYBOOK-GATE-BLOCK keys on session=, not snippet tokens"

# ---------------------------------------------------------------------------
# 9d. Observe-to-close matches the reconciler's own filed body format
#     (fleet-ops#4512). issue_body() writes the signal as a backticked line
#     (`loud/<tag>/<key>`) with no literal `signal:` prefix, so SIGNAL_RE
#     never saw the reconciler's own filings and they could never go green.
# ---------------------------------------------------------------------------
# Alarm still live -> the filed-format issue stays open (deduped, not refiled).
cat > "$tmp/open9d.json" <<'EOF'
[{"number": 4512, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `DEBUG-PLAYBOOK-MISSING`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/debug-playbook-missing/2026-09-08t07-35-48z-0509-1279-abc123`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9d.json" "$tmp/triage9b.md" > "$tmp/summary9d.json"
jq -e '.closed == 0' "$tmp/summary9d.json" >/dev/null \
    || fail "scenario 9d: filed-format issue must stay open while the alarm is live"
grep -q 'detector heartbeat: still alarmed' "$tmp/gh.log" \
    || fail "scenario 9d: expected a heartbeat comment on the filed-format issue"
ok "scenario 9d: filed-format (backticked) signal is tracked while red"

# Alarm gone -> observe-to-close closes the filed-format issue.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9d.json" "$tmp/triage1.md" > "$tmp/summary9d2.json"
jq -e '.closed == 1' "$tmp/summary9d2.json" >/dev/null \
    || fail "scenario 9d: expected observe-to-close on a filed-format body"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9d: expected gh issue close"
ok "scenario 9d: filed-format (backticked) signal closes on green (observe-to-close)"

# ---------------------------------------------------------------------------
# 10. Tier1 wiring contract.
# ---------------------------------------------------------------------------
grep -q 'detector-queue-reconciler' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "scenario 10: fleet-heartbeat-tier1 must invoke the reconciler"
grep -q 'FLEET_SIGNAL_RECONCILE_TICK_START="\$TICK_START"' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "scenario 10: tier1 must pass TICK_START to the reconciler"
grep -q 'SIGNAL_RECONCILE_LIB=' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "scenario 10: tier1 must locate the reconciler lib"
ok "scenario 10: heartbeat-tier1 wires the detector->queue reconciler"

# ---------------------------------------------------------------------------
# 11. Live loader: bulk issue list must NOT fetch comments (fleet-ops#4552).
#     Requesting the full comment bodies for up to 300 open issues in one
#     GraphQL call 504-timeouts at fleet open-issue volume, so the loader
#     returned [] every tick and observe-to-close never ran (green alarm
#     issues stayed open and re-claimed). The bulk list now omits comments;
#     the heartbeat throttle hydrates them lazily per-issue. Prove: the live
#     `gh issue list` JSON field list does not request comments, and a green
#     filed-format issue is still observe-to-closed over that loader.
# ---------------------------------------------------------------------------
cat > "$tmp/open11.json" <<'EOF'
[{"number": 2011, "body": "The heartbeat detector filed this alarm.\n\n`loud/debug-playbook-missing/2026-09-08t07-35-48z-0509-1279-abc123`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z"}]
EOF
# green triage: the filed-format signal is NOT alarmed -> observe-to-close.
cat > "$tmp/triage11_green.md" <<'EOF'
[2026-08-28T13:30:00Z] [WEEKLY-FLEET-REVIEW-PASS] cycle verdict pass
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
env "${common_env[@]}" FAKE_GH_OPEN_ISSUES="$tmp/open11.json" \
    python3 "$lib" --triage "$tmp/triage11_green.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" > "$tmp/summary11.json"
jq -e '.closed == 1' "$tmp/summary11.json" >/dev/null \
    || fail "scenario 11: live loader failed to observe-to-close a green filed-format issue (got: $(cat "$tmp/summary11.json"))"
# bulk list must not request comments (the 504 cause).
grep -q 'issue list' "$tmp/gh.log" || fail "scenario 11: expected a live gh issue list call"
if grep -Eq 'issue list.*(--json|--jq).*comments' "$tmp/gh.log"; then
    fail "scenario 11: bulk gh issue list must not request comments (504 cause)"
fi
ok "scenario 11: live loader omits comments from the bulk list and observe-to-close still works"

ok "all signal-reconcile scenarios passed"
