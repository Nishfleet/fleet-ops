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

# issue view --json title --jq .title: return the title that was actually
# filed for this issue number (fleet-ops#4622 verify_filed_signal). The fake
# fleet-issue-file logs each filing to FAKE_FLEET_ISSUE_FILE_LOG; read the
# most recent entry's title so the verify matches the signal key.
if sys.argv[1:3] == ["issue", "view"] and "--json" in sys.argv and "title" in sys.argv:
    override = os.environ.get("FAKE_GH_VIEW_TITLE", "")
    if override:
        print(override)
        sys.exit(0)
    log_path = os.environ.get("FAKE_FLEET_ISSUE_FILE_LOG", "")
    title = ""
    if log_path:
        try:
            with open(log_path, encoding="utf-8") as f:
                lines = [ln for ln in f.read().splitlines() if ln.strip()]
            if lines:
                import json as _json
                entry = _json.loads(lines[-1])
                title = entry.get("title", "")
        except (OSError, ValueError):
            pass
    print(title or "alarm: ESCALATION-CANARY-PENDING — terminal delivery not wired [loud/escalation-canary-pending/terminal-delivery-wired]")
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
# 9b. DEBUG-PLAYBOOK-MISSING is not queued by the reconciler (fleet-ops#4620).
#     The detector already LOUDs every in-window session AND files one daily
#     aggregate (fleet-ops#4384). Queuing the per-session MISSING lines as
#     loud/debug-playbook-missing created a never-green issue: any other
#     in-window session re-emits the same rule-level signal every tick, so
#     observe-to-close never fires (live: #4620 stayed open after the named
#     session aged out of the 24h window, and after PR #4644 exempted the
#     SPAWN_BLOCKED that originally tripped it).
# ---------------------------------------------------------------------------
cat > "$tmp/empty9b.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9b.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-MISSING] session=2026-09-08t07-35-47z-0509-1279-abc111 attempts=4 path=/home/nish/.pi/agent/sessions/pi-issue-0509-1279/s.jsonl snippet=agent-cron-run attest-identity-gate _dirty-worktree-audit.py escalation-daily-sweep
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9b.json" "$tmp/triage9b.md" > "$tmp/summary9b.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9b.json" >/dev/null     || fail "scenario 9b: DEBUG-PLAYBOOK-MISSING must not be queued, got: $(cat "$tmp/summary9b.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]]     || fail "scenario 9b: must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9b: DEBUG-PLAYBOOK-MISSING is not queued (detector files its own aggregate)"

# ---------------------------------------------------------------------------
# 9c. DEBUG-PLAYBOOK-GATE-BLOCK is not queued by the reconciler now
#     (fleet-ops#4946). Like DEBUG-PLAYBOOK-MISSING (#4620) and
#     FAILED-COMMAND-FAIL (#4944), it keys on the RULE not the session
#     (fleet-ops#4516/4579), so its derived signal
#     `loud/debug-playbook-gate-block` is constant across every in-window
#     session-close gate failure and can only go green on a tick whose 24h
#     window holds ZERO gate-blocks fleet-wide. #4946 is the live loop:
#     filed 2026-09-10T12:54:23Z, it stayed red even after #4953 fixed the
#     root cause because other sessions' gate-blocks kept the rule key alive
#     and re-claimed its unit into StartLimitBurst churn. The gate's
#     enforcement is untouched (bin/pi-issue-run still exits 1 / WORK-death),
#     and the same session is already carried per session by the detector's
#     `signal: debug-playbook/<slug>` and aggregate filings. The reconcile
#     issue is a redundant never-green carrier.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9c.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9c.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-GATE-BLOCK] session=2026-09-08t07-35-48z-0509-1279-abc222 attempts=4 snippet=agent-cron-run agent-scheduler-drift-check _dirty-worktree-audit.py escalation-daily-sweep
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9c.json" "$tmp/triage9c.md" > "$tmp/summary9c.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9c.json" >/dev/null     || fail "scenario 9c: DEBUG-PLAYBOOK-GATE-BLOCK must not be queued, got: $(cat "$tmp/summary9c.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]]     || fail "scenario 9c: must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9c: DEBUG-PLAYBOOK-GATE-BLOCK is not queued (rule key is never-green)"

# ---------------------------------------------------------------------------
# 9c-close. An already-open loud/debug-playbook-gate-block issue
#     observe-to-closes even while GATE-BLOCK loud lines keep firing
#     (fleet-ops#4946). Once the tag is SKIPed the line is no longer a queued
#     signal, so it cannot keep the stale alarm (live #4946) red — same
#     terminus as 9d for MISSING and 9k-close for FAILED-COMMAND-FAIL.
# ---------------------------------------------------------------------------
cat > "$tmp/open9cclose.json" <<'EOF'
[{"number": 4946, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector→queue reconciler filed one.\n\n- alarm tag: `DEBUG-PLAYBOOK-GATE-BLOCK`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/debug-playbook-gate-block`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T12:54:23Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9cclose.json" "$tmp/triage9c.md" > "$tmp/summary9cclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9cclose.json" >/dev/null \
    || fail "scenario 9c-close: stale GATE-BLOCK issue must observe-to-close while GATE-BLOCK lines continue, got: $(cat "$tmp/summary9cclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9c-close: expected gh issue close"
ok "scenario 9c-close: stale GATE-BLOCK issue observe-to-closes while lines continue"

# ---------------------------------------------------------------------------
# 9c-data. Two DEBUG-PLAYBOOK-MISSING sessions, one heartbeat tick, file ZERO
#     reconciler issues (fleet-ops#4620). The detector already files one daily
#     aggregate covering every in-window session (fleet-ops#4384). Queuing the
#     per-session LOUD lines is the never-green over-file that kept #4620 open.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9data.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9data.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-MISSING] session=2026-09-08t07-47-01z-0509-1111-aaa111 attempts=1 snippet=red pkg a
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-MISSING] session=2026-09-08t07-47-02z-0509-2222-bbb222 attempts=2 snippet=red pkg b
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9data.json" "$tmp/triage9data.md" > "$tmp/summary9data.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9data.json" >/dev/null     || fail "scenario 9data: two DEBUG-PLAYBOOK-MISSING sessions must file ZERO reconciler issues, got: $(cat "$tmp/summary9data.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]]     || fail "scenario 9data: expected no filed line, got $(cat "$tmp/filed.jsonl")"
ok "scenario 9c-extra: two MISSING sessions file zero reconciler issues"

# ---------------------------------------------------------------------------
# 9d. An already-open loud/debug-playbook-missing issue observe-to-closes even
#     while per-session MISSING LOUD lines keep firing (fleet-ops#4620). Those
#     lines are no longer a queued signal, so they cannot keep the issue red.
#     GATE-BLOCK is likewise skipped (scenario 9c). The daily rollup is DEBUG-PLAYBOOK-FAIL.
# ---------------------------------------------------------------------------
cat > "$tmp/open9d.json" <<'EOF'
[{"number": 4620, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `DEBUG-PLAYBOOK-MISSING`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/debug-playbook-missing`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9d.json" "$tmp/triage9b.md" > "$tmp/summary9d.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9d.json" >/dev/null \
    || fail "scenario 9d: stale loud/debug-playbook-missing must close even while MISSING LOUD lines fire, got: $(cat "$tmp/summary9d.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9d: expected gh issue close"
ok "scenario 9d: stale MISSING issue observe-to-closes while LOUD lines continue"

# ---------------------------------------------------------------------------
# 9e. DEBUG-PLAYBOOK-FAIL still queues (the daily rollup; fleet-ops#4384).
#     Skipping MISSING must not swallow the detector's own FAIL line.
# ---------------------------------------------------------------------------
cat > "$tmp/triage9e.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-MISSING] session=abc attempts=3 snippet=foo
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-FAIL] missing playbooks=117 (aggregate=2026-09-09 filed=1 debt=116 — a multi-attempt debug never filed the vault note; LOUD + one daily aggregate issue, observe-to-close (fleet-ops#4384)
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9b.json" "$tmp/triage9e.md" > "$tmp/summary9e.json"
jq -e '.filed == 1' "$tmp/summary9e.json" >/dev/null     || fail "scenario 9e: DEBUG-PLAYBOOK-FAIL must still file, got: $(cat "$tmp/summary9e.json")"
grep -q "loud/debug-playbook-fail" "$tmp/filed.jsonl"     || fail "scenario 9e: expected FAIL signal, got: $(cat "$tmp/filed.jsonl")"
grep -q "loud/debug-playbook-missing" "$tmp/filed.jsonl"     && fail "scenario 9e: MISSING must not be queued alongside FAIL, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9e: DEBUG-PLAYBOOK-FAIL still queues; MISSING does not"

# ---------------------------------------------------------------------------
# 9f. CLAIM-REAP-STARTED is not queued by the reconciler (fleet-ops#4918).
#     pi-issue-failed-reap writes this as its ENTRY log when it begins its
#     automatic post-failure cleanup (OnFailure). It fires on every real reap
#     — the same instance STARTED five times in an hour, each followed by a
#     successful CLAIM-RELEASED / PACKETS-ARCHIVED. A reap starting is the
#     expected recovery step, not a fault; the actionable reaper outcomes
#     (BRANCH-FAIL / LABEL-FAIL / PARSE-FAIL / NO-GH) still queue. Queuing
#     STARTED produced a noisy per-repo signal that could rarely go green.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9f.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9f.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-REAP-STARTED] instance=0509-2298 repo=Nishfleet/0509 issue=2298 dry_run=0
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9f.json" "$tmp/triage9f.md" > "$tmp/summary9f.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9f.json" >/dev/null \
    || fail "scenario 9f: CLAIM-REAP-STARTED must not be queued, got: $(cat "$tmp/summary9f.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9f: CLAIM-REAP-STARTED must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9f: CLAIM-REAP-STARTED is not queued (reap-start is expected recovery, not a fault)"

# ---------------------------------------------------------------------------
# 9g. An already-open loud/claim-reap-started issue observe-to-closes even
#     while fresh CLAIM-REAP-STARTED LOUD lines keep firing (fleet-ops#4918).
#     Those lines are no longer a queued signal, so they cannot keep the
#     issue red — the mechanism that clears #4918 on the next real tick.
# ---------------------------------------------------------------------------
cat > "$tmp/open9g.json" <<'EOF'
[{"number": 4918, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `CLAIM-REAP-STARTED`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/claim-reap-started/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9g.json" "$tmp/triage9f.md" > "$tmp/summary9g.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9g.json" >/dev/null \
    || fail "scenario 9g: stale loud/claim-reap-started must close even while STARTED LOUD lines fire, got: $(cat "$tmp/summary9g.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9g: expected gh issue close"
ok "scenario 9g: stale CLAIM-REAP-STARTED issue observe-to-closes while STARTED lines continue"

# ---------------------------------------------------------------------------
# 9h. FAILED-COMMAND-SWALLOWED keys on the session slug, not on a file token
#     harvested from the failure snippet (fleet-ops#4884). A python json.load
#     traceback puts /usr/lib/python3.12/json/__init__.py in the snippet; the
#     generic FILE_RE harvester keyed every such session to `__init__.py`, so
#     two unrelated sessions shared one signal and observe-to-close could not
#     close until both aged out. The LOUD line carries session=<slug>; key on
#     that so each session gets its own issue and closes independently.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9h.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9h.md" <<'EOF'
[2026-08-28T13:30:00Z] [FAILED-COMMAND-SWALLOWED] session=2026-09-09t22-17-38-210z-0509-2108-1788992257806109680 path=/home/nish/.pi/agent/sessions/pi-issue-0509-2108/s.jsonl snippet=Traceback (most recent call last): File "<string>", line 1, in <module> File "/usr/lib/python3.12/json/__init__.py", line 293, in load
[2026-08-28T13:30:00Z] [FAILED-COMMAND-SWALLOWED] session=2026-09-09t21-12-22-081z-0509-2144-1788988341792251501 path=/home/nish/.pi/agent/sessions/pi-issue-0509-2144/s.jsonl snippet=Traceback (most recent call last): File "<string>", line 1, in <module> File "/usr/lib/python3.12/json/__init__.py", line 293, in load
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9h.json" "$tmp/triage9h.md" > "$tmp/summary9h.json"
jq -e '.filed == 2' "$tmp/summary9h.json" >/dev/null \
    || fail "scenario 9h: two sessions must file two issues, got: $(cat "$tmp/summary9h.json")"
grep -q "loud/failed-command-swallowed/2026-09-09t22-17-38-210z-0509-2108-1788992257806109680" "$tmp/filed.jsonl" \
    || fail "scenario 9h: signal must key on session 0509-2108, got: $(cat "$tmp/filed.jsonl")"
grep -q "loud/failed-command-swallowed/2026-09-09t21-12-22-081z-0509-2144-1788988341792251501" "$tmp/filed.jsonl" \
    || fail "scenario 9h: signal must key on session 0509-2144, got: $(cat "$tmp/filed.jsonl")"
grep -q "loud/failed-command-swallowed/__init__.py" "$tmp/filed.jsonl" \
    && fail "scenario 9h: signal must NOT key on the __init__.py file token, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9h: FAILED-COMMAND-SWALLOWED keys on the session, not the file token"

# 9h-close. A stale __init__.py-keyed issue observe-to-closes once the
# detector re-keys on the session (fleet-ops#4884): the old signal is no
# longer produced, so it falls out of current_signals and closes.
cat > "$tmp/open9hclose.json" <<'EOF'
[{"number": 4884, "body": "The heartbeat detector reported this alarm.\n\n`loud/failed-command-swallowed/__init__.py`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T06:52:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9hclose.json" "$tmp/triage9h.md" > "$tmp/summary9hclose.json"
jq -e '.closed == 1' "$tmp/summary9hclose.json" >/dev/null \
    || fail "scenario 9h-close: stale __init__.py issue must observe-to-close, got: $(cat "$tmp/summary9hclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9h-close: expected gh issue close for stale __init__.py signal"
ok "scenario 9h-close: stale __init__.py-keyed issue observe-to-closes after re-key"

# ---------------------------------------------------------------------------
# 9i. CLAIM-RELEASED is not queued by the reconciler (fleet-ops#4930).
#     pi-issue-failed-reap writes it to confirm a SUCCESSFUL claim release
#     back to agent-ready after a worker failure (the instance=... branch=...
#     branch_deleted=yes label_flipped=yes comment_posted=yes summary line).
#     It fires on every real reap of an OPEN issue; the derived key is
#     per-repo (`loud/claim-released/<repo>`), so any future reap re-emits the
#     same key and observe-to-close can never go green — the never-green loop
#     #4918 fixed for CLAIM-REAP-STARTED. A reclaim is the expected recovery
#     step, not a fault; the actionable reaper outcomes (BRANCH-FAIL /
#     LABEL-FAIL / PARSE-FAIL / NO-GH) still queue.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9i.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9i.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-RELEASED] instance=fleet-ops-4907 repo=Nishfleet/fleet-ops branch=claim/issue-4907 branch_deleted=yes label_flipped=yes comment_posted=yes
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9i.json" "$tmp/triage9i.md" > "$tmp/summary9i.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9i.json" >/dev/null \
    || fail "scenario 9i: CLAIM-RELEASED must not be queued, got: $(cat "$tmp/summary9i.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9i: CLAIM-RELEASED must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9i: CLAIM-RELEASED is not queued (reap completion is expected recovery, not a fault)"

# ---------------------------------------------------------------------------
# 9i-close. An already-open loud/claim-released issue observe-to-closes even
#     while fresh CLAIM-RELEASED LOUD lines keep firing (fleet-ops#4930).
#     Those lines are no longer a queued signal, so they cannot keep the
#     issue red — the mechanism that clears #4930 on the next real tick.
# ---------------------------------------------------------------------------
cat > "$tmp/open9iclose.json" <<'EOF'
[{"number": 4930, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `CLAIM-RELEASED`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/claim-released/nishfleet-fleet-ops`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T11:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9iclose.json" "$tmp/triage9i.md" > "$tmp/summary9iclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9iclose.json" >/dev/null \
    || fail "scenario 9i-close: stale loud/claim-released must close even while RELEASED LOUD lines fire, got: $(cat "$tmp/summary9iclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9i-close: expected gh issue close"
ok "scenario 9i-close: stale CLAIM-RELEASED issue observe-to-closes while RELEASED lines continue"

# ---------------------------------------------------------------------------
# 9j. PACKETS-ARCHIVED is not queued by the reconciler (fleet-ops#4955).
#     pi-issue-failed-reap writes it ONCE the reaper's packet-archive sweep
#     moved a dead worker's packet files out of the way during cleanup (the
#     instance=... repo=... state=... branch_deleted=... count=... summary
#     line, bin/pi-issue-failed-reap archive_packets()). It fires on EVERY
#     real reap that archived packet files — a successful cleanup step, not a
#     fault. It carries a `repo=` key, so the derived signal is per-repo
#     (`loud/packets-archived/<repo>`), and any later reap re-emits the same
#     key so observe-to-close can never go green — the same never-green loop
#     #4918/#4930 fixed for CLAIM-REAP-STARTED / CLAIM-RELEASED. The
#     actionable reaper outcomes (BRANCH-FAIL / LABEL-FAIL / PARSE-FAIL /
#     NO-GH) still queue.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9j.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9j.md" <<'EOF'
[2026-08-28T13:30:00Z] [PACKETS-ARCHIVED] instance=0509-2320 repo=Nishfleet/0509 state=OPEN branch_deleted=yes count=3 stamp=x
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9j.json" "$tmp/triage9j.md" > "$tmp/summary9j.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9j.json" >/dev/null \
    || fail "scenario 9j: PACKETS-ARCHIVED must not be queued, got: $(cat "$tmp/summary9j.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9j: PACKETS-ARCHIVED must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9j: PACKETS-ARCHIVED is not queued (packet-archive completion is expected, not a fault)"

# ---------------------------------------------------------------------------
# 9j-close. An already-open loud/packets-archived issue observe-to-closes
#     once PACKETS-ARCHIVED is skipped (fleet-ops#4955): the archive-completion
#     line is no longer a queued signal, so it cannot keep the issue red — the
#     durable regression proving the informational archive-completion line
#     does not re-file.
# ---------------------------------------------------------------------------
cat > "$tmp/open9jclose.json" <<'EOF'
[{"number": 4955, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `PACKETS-ARCHIVED`\n\n`loud/packets-archived/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T11:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9jclose.json" "$tmp/triage9j.md" > "$tmp/summary9jclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9jclose.json" >/dev/null \
    || fail "scenario 9j-close: stale loud/packets-archived must close even while ARCHIVED LOUD lines fire, got: $(cat "$tmp/summary9jclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9j-close: expected gh issue close"
ok "scenario 9j-close: stale PACKETS-ARCHIVED issue observe-to-closes while ARCHIVED lines continue"

# ---------------------------------------------------------------------------
# 9m. CLAIM-CLOSED-CLEANUP is not queued by the reconciler (fleet-ops#5007).
#     pi-issue-failed-reap writes it once it has cleaned up a CLOSED issue's
#     claim — it removes the stale agent-in-progress label and resets the
#     reclaim/ladder markers (the instance=... repo=... branch=...
#     branch_deleted=no label_removed=yes summary line). It fires on EVERY
#     reaped CLOSED issue, keyed per-repo (`loud/claim-closed-cleanup/<repo>`)
#     from the repo_slug token, so any later closed reap re-emits the same
#     key and observe-to-close can never go green — the same never-green loop
#     #4918/#4930/#4955 fixed for CLAIM-REAP-STARTED / CLAIM-RELEASED /
#     PACKETS-ARCHIVED. A closed-issue cleanup is expected completion, not a
#     fault: branch_deleted=no here means the branch was already gone (merged
#     PR auto-delete or claim-reconcile's orphan sweep); a real delete that
#     failed raises its own actionable CLAIM-REAP-BRANCH-FAIL that still
#     queues. The actionable reaper outcomes (BRANCH-FAIL / LABEL-FAIL /
#     PARSE-FAIL / NO-GH) still queue.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9m.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9m.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-CLOSED-CLEANUP] instance=0509-2347 repo=Nishfleet/0509 branch=claim/issue-2347 branch_deleted=no label_removed=yes
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9m.json" "$tmp/triage9m.md" > "$tmp/summary9m.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9m.json" >/dev/null \
    || fail "scenario 9m: CLAIM-CLOSED-CLEANUP must not be queued, got: $(cat "$tmp/summary9m.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9m: CLAIM-CLOSED-CLEANUP must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9m: CLAIM-CLOSED-CLEANUP is not queued (closed-issue cleanup is expected completion, not a fault)"

# ---------------------------------------------------------------------------
# 9m-close. An already-open loud/claim-closed-cleanup issue observe-to-closes
#     once CLAIM-CLOSED-CLEANUP is skipped (fleet-ops#5007): the closed-issue
#     completion line is no longer a queued signal, so it cannot keep the
#     issue red — the durable regression proving the informational
#     closed-reap-completion line does not re-file and the stale issue closes
#     on the next real tick.
# ---------------------------------------------------------------------------
cat > "$tmp/open9mclose.json" <<'EOF'
[{"number": 5007, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `CLAIM-CLOSED-CLEANUP`\n\n`loud/claim-closed-cleanup/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T12:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9mclose.json" "$tmp/triage9m.md" > "$tmp/summary9mclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9mclose.json" >/dev/null \
    || fail "scenario 9m-close: stale loud/claim-closed-cleanup must close even while CLEANUP LOUD lines fire, got: $(cat "$tmp/summary9mclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9m-close: expected gh issue close"
ok "scenario 9m-close: stale CLAIM-CLOSED-CLEANUP issue observe-to-closes while CLEANUP LOUD lines continue"

# ---------------------------------------------------------------------------
# 9k. FAILED-COMMAND-FAIL is not queued by the reconciler (fleet-ops#4944).
#     It is the detector's own ROLLUP of swallowed-failure debt, and its key
#     is constant: _extract_signal_key() strips the counts as DYNAMIC_RE
#     tokens, so every tick derives the same
#     `loud/failed-command-fail/swallowed-failures` no matter how the counts
#     move. It can only go green on a tick whose 24h window holds zero
#     findings across ALL sessions, and the per-session exemption list is
#     deliberately narrow (edit-unmatch / schema-validation / "No changes
#     made" are real swallowed failures). Live loop 2026-09-10: #4920 was
#     filed, admitted by the senior panel, closed as completed with #4944
#     filed as the fix issue — and the next tick re-derived the identical
#     key. Same never-green shape as DEBUG-PLAYBOOK-MISSING (#4620). The
#     per-session carriers stay: the bin's own
#     `signal: failed-command-flagged/<session>` filings and the reconciler's
#     session-keyed FAILED-COMMAND-SWALLOWED alarms (#4884).
# ---------------------------------------------------------------------------
cat > "$tmp/empty9k.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9k.md" <<'EOF'
[2026-09-10T13:53:28Z] [FAILED-COMMAND-FAIL] swallowed failures=38 (filed=5 deferred=33) — a failed command was walked past; heartbeat tick will fail
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9k.json" "$tmp/triage9k.md" > "$tmp/summary9k.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9k.json" >/dev/null \
    || fail "scenario 9k: FAILED-COMMAND-FAIL must not be queued, got: $(cat "$tmp/summary9k.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9k: FAILED-COMMAND-FAIL must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9k: FAILED-COMMAND-FAIL rollup is not queued"

# 9k-key. The skip is only correct because the key cannot move: prove the
#     signal key is identical across a rising and a falling count. If a
#     future refactor stops stripping the counts, the key churns per tick and
#     the skip must be re-argued.
python3 - "$repo_root" <<'PY' || fail "scenario 9k-key: FAILED-COMMAND-FAIL key must not move with the counts"
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "dqr", sys.argv[1] + "/lib/detector-queue-reconciler.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
keys = set()
for n, f, d in [(1, 1, 0), (5, 5, 0), (23, 5, 18), (38, 5, 33), (100, 0, 0)]:
    msg = (f"swallowed failures={n} (filed={f} deferred={d}) "
           "\u2014 a failed command was walked past; heartbeat tick will fail")
    keys.add(tuple(m._extract_signal_key("FAILED-COMMAND-FAIL", msg)))
assert keys == {("swallowed-failures",)}, keys
PY
ok "scenario 9k-key: FAILED-COMMAND-FAIL key is constant across counts"

# ---------------------------------------------------------------------------
# 9k-close. An already-open loud/failed-command-fail/swallowed-failures issue
#     observe-to-closes even while the rollup line keeps firing every tick
#     (fleet-ops#4944). This is the terminus: without the skip the key is
#     re-derived on every tick, so observe-to-close can never fire and the
#     alarm refiles forever (live #4920 -> #4944).
# ---------------------------------------------------------------------------
cat > "$tmp/open9kclose.json" <<'EOF'
[{"number": 4944, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\nDo NOT close this issue on PR merge alone.\n\n`loud/failed-command-fail/swallowed-failures`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T12:55:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9kclose.json" "$tmp/triage9k.md" > "$tmp/summary9kclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9kclose.json" >/dev/null \
    || fail "scenario 9k-close: stale FAILED-COMMAND-FAIL issue must observe-to-close while the rollup keeps firing, got: $(cat "$tmp/summary9kclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9k-close: expected gh issue close"
ok "scenario 9k-close: stale FAILED-COMMAND-FAIL issue observe-to-closes while the rollup continues"

# 9k-keep. The per-session carrier must still queue: the skip is scoped to the
#     rollup, not to the swallowed-failure class. A session-keyed
#     FAILED-COMMAND-SWALLOWED alarm still files (fleet-ops#4884).
cat > "$tmp/triage9kkeep.md" <<'EOF'
[2026-09-10T13:53:28Z] [FAILED-COMMAND-FAIL] swallowed failures=38 (filed=5 deferred=33) — a failed command was walked past; heartbeat tick will fail
[2026-09-10T13:53:28Z] [FAILED-COMMAND-SWALLOWED] session=2026-09-10t12-52-48-925z-0509-2331-1789044768598769758 path=/home/nish/.pi/agent/sessions/pi-issue-0509-2331/s.jsonl snippet=fatal: a branch named 'claim/issue-2331' already exists
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9k.json" "$tmp/triage9kkeep.md" > "$tmp/summary9kkeep.json"
jq -e '.filed == 1 and .alarm_count == 1' "$tmp/summary9kkeep.json" >/dev/null \
    || fail "scenario 9k-keep: only the session-keyed swallowed alarm may file, got: $(cat "$tmp/summary9kkeep.json")"
grep -q "loud/failed-command-swallowed/2026-09-10t12-52-48-925z-0509-2331-1789044768598769758" "$tmp/filed.jsonl" \
    || fail "scenario 9k-keep: session-keyed signal must be filed, got: $(cat "$tmp/filed.jsonl")"
grep -q "loud/failed-command-fail" "$tmp/filed.jsonl" \
    && fail "scenario 9k-keep: rollup must not be filed, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9k-keep: FAILED-COMMAND-SWALLOWED still queues per session"

# ---------------------------------------------------------------------------
# 9l. EXEC-REVIEW-DISARM is not queued by the reconciler (fleet-ops#4969).
#     It is the exec-review canary's disarm ACTION (fleet-ops#3731 hard gate):
#     bin/fleet-exec-review-canary emits it when it disables auto-merge on an
#     armed PR that carries no verify/receipt cue. The message is
#     `auto-merge DISABLED on <repo>#NNN (no verify cue ...)`, so
#     derive_signals() harvests only the repo token and forms the per-repo key
#     `loud/exec-review-disarm/<repo>`. ANY later disarm in that repo re-emits
#     the same key, so the issue is never-green no matter which PR or how long
#     the gap between disarms. The actionable per-PR work is already tracked:
#     a worker finding is filed by the canary itself under
#     `signal: exec-review-receipt/<slug>`, and a human finding is
#     disarmed-only (fleet-ops#4117). The disarm already stopped the unverified
#     merge; the LOUD line is the measurement. Same never-green class as
#     PACKETS-ARCHIVED (#4955) and FAILED-COMMAND-FAIL (#4944).
# ---------------------------------------------------------------------------
cat > "$tmp/empty9l.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9l.md" <<'EOF'
[2026-09-10T13:56:12Z] [EXEC-REVIEW-DISARM] auto-merge DISABLED on Nishfleet/fleet-ops#4889 (no verify cue — fleet-ops#3731 hard gate)
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty9l.json" "$tmp/triage9l.md" > "$tmp/summary9l.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9l.json" >/dev/null \
    || fail "scenario 9l: EXEC-REVIEW-DISARM must not be queued, got: $(cat "$tmp/summary9l.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9l: EXEC-REVIEW-DISARM must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9l: EXEC-REVIEW-DISARM disarm action is not queued"

# 9l-key. The skip is only correct because the key is repo-scoped and cannot
#     move per PR: prove that any disarm message in the same repo derives the
#     SAME `loud/exec-review-disarm/<repo>` key. If a future refactor keys on
#     the PR number instead, the key churns per process and the skip must be
#     re-argued.
python3 - "$repo_root" <<'PY' || fail "scenario 9l-key: EXEC-REVIEW-DISARM key must be repo-scoped and constant"
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "dqr", sys.argv[1] + "/lib/detector-queue-reconciler.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
keys = set()
for repo, pr in [("Nishfleet/fleet-ops", 4889), ("Nishfleet/fleet-ops", 4906),
                 ("Nishfleet/fleet-ops", 4975), ("Nishfleet/0509", 2538)]:
    msg = (f"auto-merge DISABLED on {repo}#{pr} "
           "(no verify cue — fleet-ops#3731 hard gate)")
    keys.add(tuple(m._extract_signal_key("EXEC-REVIEW-DISARM", msg)))
assert keys == {("nishfleet-fleet-ops",), ("nishfleet-0509",)}, keys
PY
ok "scenario 9l-key: EXEC-REVIEW-DISARM key is repo-scoped (same repo, any PR -> same key)"

# ---------------------------------------------------------------------------
# 9l-close. An already-open loud/exec-review-disarm/<repo> issue observe-
#     to-closes once EXEC-REVIEW-DISARM is skipped, even while disarm LOUD
#     lines keep firing (fleet-ops#4969). This is the terminus: without the
#     skip the repo-scoped key is re-derived on every disarm, observe-to-close
#     can never fire, and the alarm refiles forever.
# ---------------------------------------------------------------------------
cat > "$tmp/open9lclose.json" <<'EOF'
[{"number": 4969, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `EXEC-REVIEW-DISARM`\n- evidence: auto-merge DISABLED on Nishfleet/fleet-ops#4889 (no verify cue \u2014 fleet-ops#3731 hard gate)\n- observed tick: `2026-09-10T13:56:12Z`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/exec-review-disarm/nishfleet-fleet-ops`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T13:30:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9lclose.json" "$tmp/triage9l.md" > "$tmp/summary9lclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9lclose.json" >/dev/null \
    || fail "scenario 9l-close: stale loud/exec-review-disarm issue must observe-to-close while disarm LOUD lines fire, got: $(cat "$tmp/summary9lclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9l-close: expected gh issue close"
ok "scenario 9l-close: stale EXEC-REVIEW-DISARM issue observe-to-closes while disarm lines continue"

# ---------------------------------------------------------------------------
# 9m. CLAIM-CLOSED-CLEANUP is not queued by the reconciler (fleet-ops#5007).
#     pi-issue-failed-reap writes it when it reaps a CLOSED issue: the
#     successful cleanup that removes agent-in-progress and archives the dead
#     worker's per-issue state (the instance=... repo=... branch=...
#     branch_deleted=... label_removed=... summary line). It fires on EVERY
#     real reap of a CLOSED issue and carries a `repo=` key, so the derived
#     signal is per-repo (`loud/claim-closed-cleanup/<repo>`) and observe-
#     to-close can never go green — the same never-green loop #4918/#4930/
#     #4955 fixed for CLAIM-REAP-STARTED / CLAIM-RELEASED / PACKETS-ARCHIVED.
#     The actionable reaper outcomes (BRANCH-FAIL / LABEL-FAIL / PARSE-FAIL /
#     NO-GH) still queue.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9m.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9m.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-CLOSED-CLEANUP] instance=0509-2317 repo=Nishfleet/0509 branch=claim/issue-2317 branch_deleted=yes label_removed=yes
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9m.json" "$tmp/triage9m.md" > "$tmp/summary9m.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9m.json" >/dev/null \
    || fail "scenario 9m: CLAIM-CLOSED-CLEANUP must not be queued, got: $(cat "$tmp/summary9m.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9m: CLAIM-CLOSED-CLEANUP must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9m: CLAIM-CLOSED-CLEANUP is not queued (closed-issue cleanup completion is expected, not a fault)"

# 9m-close. An already-open loud/claim-closed-cleanup issue observe-to-closes
#     once CLAIM-CLOSED-CLEANUP is skipped (fleet-ops#5007).
# ---------------------------------------------------------------------------
cat > "$tmp/open9mclose.json" <<'EOF'
[{"number": 5007, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `CLAIM-CLOSED-CLEANUP`\n\n`loud/claim-closed-cleanup/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T16:15:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9mclose.json" "$tmp/triage9m.md" > "$tmp/summary9mclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9mclose.json" >/dev/null \
    || fail "scenario 9m-close: stale loud/claim-closed-cleanup must close even while CLEANUP LOUD lines fire, got: $(cat "$tmp/summary9mclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9m-close: expected gh issue close"
ok "scenario 9m-close: stale CLAIM-CLOSED-CLEANUP issue observe-to-closes while CLEANUP lines continue"

# ---------------------------------------------------------------------------
# 9n. CLAIM-CLOSED-RESET is not queued by the reconciler (fleet-ops#5008).
#     pi-issue-failed-reap writes it in the SAME CLOSED branch, immediately
#     after CLAIM-CLOSED-CLEANUP, as the per-issue state-file reset that lets
#     a re-opened issue start fresh (rm reclaim-count/systemic/infra-death/
#     prefer-class/last-death-class; the instance=... repo=... summary line).
#     Like its CLEANUP sibling it fires on EVERY real reap of a CLOSED issue
#     with a `repo=` key, so the derived signal is per-repo
#     (`loud/claim-closed-reset/<repo>`) and observe-to-close can never go
#     green. Confirmed live: #5008 was auto-filed by this never-green key on
#     2026-09-10T15:48:43Z from instance=0509-2347 repo=Nishfleet/0509. The
#     reset is the expected post-merge cleanup, not a fault.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9n.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9n.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-CLOSED-RESET] instance=0509-2347 repo=Nishfleet/0509
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9n.json" "$tmp/triage9n.md" > "$tmp/summary9n.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary9n.json" >/dev/null \
    || fail "scenario 9n: CLAIM-CLOSED-RESET must not be queued, got: $(cat "$tmp/summary9n.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 9n: CLAIM-CLOSED-RESET must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9n: CLAIM-CLOSED-RESET is not queued (post-merge claim-state reset is expected, not a fault)"

# 9n-key. The skip is only correct because the key is repo-scoped and cannot
#     move per instance: prove that any closed-issue reap in the same repo
#     derives the SAME `loud/claim-closed-reset/<repo>` key. If a future
#     refactor keys on the instance or removes the reset's claims, the key
#     churns per reap and the skip must be re-argued.
python3 - "$repo_root" <<'PY' || fail "scenario 9n-key: CLAIM-CLOSED-RESET key must be repo-scoped and constant"
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "dqr", sys.argv[1] + "/lib/detector-queue-reconciler.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
keys = set()
for inst in ["0509-2347", "0509-2388", "0509-2401"]:
    msg = f"instance={inst} repo=Nishfleet/0509"
    keys.add(tuple(m._extract_signal_key("CLAIM-CLOSED-RESET", msg)))
assert keys == {("nishfleet-0509",)}, keys
PY
ok "scenario 9n-key: CLAIM-CLOSED-RESET key is repo-scoped (same repo, any instance -> same key)"

# 9n-close. An already-open loud/claim-closed-reset/<repo> issue observe-
#     to-closes once CLAIM-CLOSED-RESET is skipped even while RESET LOUD lines
#     keep firing (fleet-ops#5008). Without the skip the per-repo key is
#     re-derived on every closed-issue reap, observe-to-close can never fire,
#     and the alarm refiles forever.
# ---------------------------------------------------------------------------
cat > "$tmp/open9nclose.json" <<'EOF'
[{"number": 5008, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `CLAIM-CLOSED-RESET`\n- evidence: instance=0509-2347 repo=Nishfleet/0509\n- observed tick: `2026-09-10T15:48:43Z`\n\nDo NOT close this issue on PR merge alone.\n\n`loud/claim-closed-reset/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-09-10T16:19:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open9nclose.json" "$tmp/triage9n.md" > "$tmp/summary9nclose.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary9nclose.json" >/dev/null \
    || fail "scenario 9n-close: stale loud/claim-closed-reset must close even while RESET LOUD lines fire, got: $(cat "$tmp/summary9nclose.json")"
grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 9n-close: expected gh issue close"
ok "scenario 9n-close: stale CLAIM-CLOSED-RESET issue observe-to-closes while RESET lines continue"

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
[{"number": 2011, "body": "The heartbeat detector filed this alarm.\n\n`loud/debug-playbook-gate-block`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z"}]
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

# ---------------------------------------------------------------------------
# 12. FILED-LINK-MISMATCH (fleet-ops#4622): fleet-issue-file may dedupe to
#     an unrelated issue and return its URL. The reconciler must verify the
#     returned issue's title carries the signal key; on mismatch it emits a
#     LOUD FILED-LINK-MISMATCH so the wrong pointer can never satisfy
#     observe-to-close. Prove: (a) a wrong title -> LOUD + summary counter;
#     (b) a matching title -> no LOUD.
# ---------------------------------------------------------------------------
cat > "$tmp/triage12.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-PENDING] terminal delivery not wired (#76)
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"

# 12a. wrong title -> LOUD FILED-LINK-MISMATCH + filed_mismatches counter.
#     fleet-ops#4841: a wrong pointer is NOT a successful filing — it does not
#     carry the signal key, so observe-to-close can never close it, and counting
#     it would waste the auto-file cap on a pointer that can never go green.
#     So filed stays 0 (the cap is not consumed) and the signal is re-filed on
#     the next tick once the dedupe no longer collapses it onto the wrong issue.
env "${common_env[@]}" FAKE_GH_VIEW_TITLE="claude OAuth quota meter silently dead" \
    FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage12.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" 2>"$tmp/stderr12a.json" \
    > "$tmp/summary12a.json" || true
jq -e '.filed == 0' "$tmp/summary12a.json" >/dev/null \
    || fail "scenario 12a: wrong pointer must NOT count as filed (got: $(cat "$tmp/summary12a.json"))"
jq -e '.filed_mismatches == 1' "$tmp/summary12a.json" >/dev/null \
    || fail "scenario 12a: expected filed_mismatches==1 (got: $(cat "$tmp/summary12a.json"))"
grep -q 'FILED-LINK-MISMATCH' "$tmp/stderr12a.json" \
    || fail "scenario 12a: expected LOUD FILED-LINK-MISMATCH on stderr"
ok "scenario 12a: wrong-title filed pointer -> LOUD FILED-LINK-MISMATCH, not counted as filed, cap not consumed"

# 12b. matching title -> no LOUD, no mismatch counter.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
# Recreate the triage file: 12a's LOUD FILED-LINK-MISMATCH was appended to it.
cat > "$tmp/triage12.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-CANARY-PENDING] terminal delivery not wired (#76)
EOF
env "${common_env[@]}" \
    FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/empty.json" \
    python3 "$lib" --triage "$tmp/triage12.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T13:45:00Z" 2>"$tmp/stderr12b.json" \
    > "$tmp/summary12b.json" || true
jq -e '.filed == 1' "$tmp/summary12b.json" >/dev/null \
    || fail "scenario 12b: expected one filed (got: $(cat "$tmp/summary12b.json"))"
jq -e '(.filed_mismatches // 0) == 0' "$tmp/summary12b.json" >/dev/null \
    || fail "scenario 12b: expected filed_mismatches==0 (got: $(cat "$tmp/summary12b.json"))"
grep -q 'FILED-LINK-MISMATCH' "$tmp/stderr12b.json" \
    && fail "scenario 12b: matching title must NOT emit FILED-LINK-MISMATCH"
ok "scenario 12b: matching-title filed pointer -> no FILED-LINK-MISMATCH"

# 12c. issue_title embeds the signal key (regression guard).
python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dqr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sig = "loud/escalation-canary-pending/terminal-delivery-wired"
t = m.issue_title("ESCALATION-CANARY-PENDING", "terminal delivery not wired (#76)", signal=sig)
assert sig in t, ("title must embed signal key", t)
print("issue_title embeds signal:", t)
' "$lib" || fail "scenario 12c: issue_title must embed the signal key"
ok "scenario 12c: issue_title embeds the signal key in the title"

# ---------------------------------------------------------------------------
# 12d. Wrong-pointer root cause (fleet-ops#4841): issue-file's dedupe must NOT
#     collapse two reconciler alarms with DIFFERENT backticked `loud/...`
#     signals onto one issue. Before the fix, issue-file only recognised the
#     literal `signal:` prefix, so the reconciler's backticked signal key was
#     invisible to the dedupe and pure token overlap (shared boilerplate body)
#     scored unrelated alarms as duplicates — the first 5 filings all landed on
#     the wrong #4841 and wasted the auto-file cap. Prove: two issues with
#     different `loud/...` signals score below borderline (file clean), while
#     two with the SAME signal still score as duplicates.
# ---------------------------------------------------------------------------
cat > "$tmp/issue_file_lib.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("if", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def body(tag, key):
    return (
        "The heartbeat detector reported this alarm on a real tick and no open "
        "issue carried its signal key, so the detector→queue reconciler filed one.\n\n"
        f"- alarm tag: `{tag}`\n"
        f"- evidence: {key}\n"
        "- observed tick: `2026-09-10T01:35:29Z`\n"
        "- detector→queue reconciler: fleet-ops#362\n\n"
        "Do NOT close this issue on PR merge alone. "
        "The reconciler closes it only when the detector reports green on a real "
        "heartbeat tick (observe-to-close).\n\n"
        f"`loud/{tag.lower()}/{key}`\n"
    )

def title(tag, key):
    return f"alarm: {tag} — {key} [loud/{tag.lower()}/{key}]"

# Different signals -> must file clean (below borderline).
cand_t = title("CLAIM-REAP-NEEDED", "instance-fleet-ops-branch-claim-issue-open_pr_count")
cand_b = body("CLAIM-REAP-NEEDED", "instance-fleet-ops-branch-claim-issue-open_pr_count")
exist_t = title("DECISIONS-LEDGER-REASK", "decision-geo-aeo-fleet-executes-measurement")
exist_b = body("DECISIONS-LEDGER-REASK", "decision-geo-aeo-fleet-executes-measurement")
d = m.score_pair(cand_t, cand_b, exist_t, exist_b)
assert d["score"] < m.BORDERLINE_THRESHOLD, ("different loud signals must not dedupe", d["score"])
assert m.classify(d["score"]) == "new", ("must file clean", d["score"])

# Same signal -> still a duplicate.
d2 = m.score_pair(cand_t, cand_b, cand_t, cand_b)
assert d2["score"] >= m.DUP_THRESHOLD, ("same loud signal must dedupe", d2["score"])
assert m.classify(d2["score"]) == "duplicate", ("must dedupe", d2["score"])
print("different-signal score:", d["score"], "same-signal score:", d2["score"])
PY
python3 "$tmp/issue_file_lib.py" "$repo_root/lib/issue-file.py" \
    || fail "scenario 12d: issue-file must not dedupe different loud signals"
ok "scenario 12d: issue-file does not collapse different loud signals (wrong-pointer root cause fixed)"

# ---------------------------------------------------------------------------
# 13. ESCALATION-COMPLETION-STALE-TRIP chain-hash alarm -> observe-to-close
# (fleet-ops#4949). A STALE-TRIP LOUD line for a specific chain (chain-hash
# key, derived from the phrase, NOT a literal `signal:`/`unit=` token) is
# filed as one issue carrying the backticked key. While the chain stays in
# the current tick the issue is deduped (heartbeat comment, stays open); once
# the chain stops emitting (detector green / STOP-REASON advanced), the
# issue observe-to-closes. This locks the exact #4949/#4919 closeout so a
# regression can never leave a never-green STALE-TRIP issue.
# ---------------------------------------------------------------------------
stale_msg="chain 0a52ad5971df detector-green but STOP-REASON reason=unit-failure is NOT terminal and stop-escalation is IDLE — fix was never closed (auditor-resolved/boundary:* required)"
cat > "$tmp/open13.json" <<'EOF'
[{"number": 4949, "body": "\n`loud/escalation-completion-stale-trip/chain-0a52ad5971df-detector-green-stop-reason`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF

# 13a. STALE-TRIP still in the current tick -> dedupe, stays open.
cat > "$tmp/triage13-on.md" <<EOF
[2026-08-28T13:30:00Z] [ESCALATION-COMPLETION-STALE-TRIP] $stale_msg
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open13.json" "$tmp/triage13-on.md" > "$tmp/summary13a.json"
jq -e '.deduped == 1 and .closed == 0 and .filed == 0' "$tmp/summary13a.json" >/dev/null \
    || fail "scenario 13a: alarmed STALE-TRIP chain must dedupe (got: $(cat "$tmp/summary13a.json"))"
! grep -q "issue close" "$tmp/gh.log" || fail "scenario 13a: alarmed STALE-TRIP must not close (gh.log: $(cat "$tmp/gh.log"))"
ok "scenario 13a: STALE-TRIP chain still alarmed -> deduped, stays open"

# 13b. STALE-TRIP gone from the current tick -> observe-to-close #4949.
# The chain's detector reports green on this real heartbeat tick, so the
# filed STALE-TRIP issue is the exact closeout the reconciler owns.
cat > "$tmp/triage13-off.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-COMPLETION-GREEN] chain 0a52ad5971df unit=fleet-heartbeat.service is detector-green and STOP-REASON terminal — FIX reached and closed
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open13.json" "$tmp/triage13-off.md" > "$tmp/summary13b.json"
jq -e '.closed == 1 and .deduped == 0' "$tmp/summary13b.json" >/dev/null \
    || fail "scenario 13b: green STALE-TRIP chain must observe-to-close (got: $(cat "$tmp/summary13b.json"))"
grep -q "issue close 4949" "$tmp/gh.log" || fail "scenario 13b: expected gh issue close 4949 (got: $(cat "$tmp/gh.log"))"
grep -q "issue comment" "$tmp/gh.log" && fail "scenario 13b: green chain must only close, not heartbeat-comment"
ok "scenario 13b: green STALE-TRIP chain observe-to-closes the filed issue"

# 13c. fleet-ops#5190 flap guard: the SAME signal fired recently (a
# STALE-TRIP line in triage history, before this tick's TICK_START — the
# enforcer's hold tick) -> observe-to-close is DEFERRED, not fired, on a
# single quiet tick. This is the #4989 flap: the alarm closed while the
# chain still fired hours later.
cat > "$tmp/triage13-hist.md" <<EOF
[2026-08-28T12:50:00Z] [ESCALATION-COMPLETION-STALE-TRIP] $stale_msg
[2026-08-28T13:30:00Z] [HEARTBEAT-OK] tick quiet for this chain
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open13.json" "$tmp/triage13-hist.md" > "$tmp/summary13c.json"
jq -e '.closed == 0 and .close_deferred == 1' "$tmp/summary13c.json" >/dev/null \
    || fail "scenario 13c: recently-fired STALE-TRIP signal must be deferred, not closed (got: $(cat "$tmp/summary13c.json"))"
! grep -q "issue close" "$tmp/gh.log" || fail "scenario 13c: no gh issue close inside the grace window"
ok "scenario 13c: STALE-TRIP fired 55min ago -> close deferred (flap guard)"

# 13d. Once the last fire ages past the grace window (6h default), the same
# absent tick closes the alarm — the chain really is done.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
env "${common_env[@]}" FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$tmp/open13.json" \
    python3 "$lib" --triage "$tmp/triage13-hist.md" --tick-start "2026-08-28T13:30:00Z" \
    --ok-to-close 1 --json --now "2026-08-28T19:40:00Z" > "$tmp/summary13d.json" || true
jq -e '.closed == 1 and .close_deferred == 0' "$tmp/summary13d.json" >/dev/null \
    || fail "scenario 13d: STALE-TRIP silent past grace must observe-to-close (got: $(cat "$tmp/summary13d.json"))"
grep -q "issue close 4949" "$tmp/gh.log" || fail "scenario 13d: expected gh issue close 4949 past grace"
ok "scenario 13d: STALE-TRIP silent >6h -> observe-to-close fires"

# 13e. A close-grace miss is tag-scoped: an unrelated signal with NO history
# still closes immediately on a single absent tick (no global close delay).
cat > "$tmp/open13e.json" <<'EOF'
[{"number": 4990, "body": "signal: loud/escalation-canary-pending/old-alarm-wired", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open13e.json" "$tmp/triage13-hist.md" > "$tmp/summary13e.json"
jq -e '.closed == 1' "$tmp/summary13e.json" >/dev/null \
    || fail "scenario 13e: non-grace signal must still close immediately (got: $(cat "$tmp/summary13e.json"))"
ok "scenario 13e: close-grace is scoped to stale-trip signals only"

# ---------------------------------------------------------------------------
# 14. DEGRADED-LANES alarms are observe-to-close-only and must NOT be routed
#     to the worker pool (fleet-ops#4966). The heartbeat Tier 1 \u00a77 sees
#     auto-restart lanes as "held, no work \u2014 StartLimitBurst / OnFailure
#     are the right release path", so there is no manual action a fleet
#     worker can take, and every prior filing closed via the reconciler's own
#     observe-to-close with zero worker code (4668/4701/4931/4947/4966).
#     Routing them to agent-ready burned an admission-priced worker seat per
#     occurrence for nothing.
#
#     14a. A fresh DEGRADED-LANES alarm is filed under `observe-to-close`, NOT
#          `agent-ready`, so the intake will not claim it.
#     14b. The detector's observe-to-close STILL closes it once the lanes go
#          green (the label must not change the closeout path).
# ---------------------------------------------------------------------------
degraded_msg="degraded=4 :: pi-issue@0509-2189.service sub=auto-restart :: ... | pi-issue@0509-2324.service sub=auto-restart :: ..."
cat > "$tmp/empty14.json" <<'EOF'
[]
EOF
cat > "$tmp/triage14-on.md" <<EOF
[2026-08-28T13:30:00Z] [DEGRADED-LANES] $degraded_msg
EOF

# 14a. Fresh DEGRADED-LANES files with observe-to-close, not agent-ready.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty14.json" "$tmp/triage14-on.md" > "$tmp/summary14a.json"
jq -e '.filed == 1 and .closed == 0' "$tmp/summary14a.json" >/dev/null \
    || fail "scenario 14a: DEGRADED-LANES must file one issue (got: $(cat "$tmp/summary14a.json"))"
grep -q 'loud/degraded-lanes/0509-2189.service' "$tmp/filed.jsonl" \
    || fail "scenario 14a: DEGRADED-LANES signal key missing (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"labels": \["observe-to-close"\]' \
    || fail "scenario 14a: DEGRADED-LANES must file under observe-to-close, not agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"agent-ready"' \
    && fail "scenario 14a: DEGRADED-LANES must NOT carry agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
ok "scenario 14a: DEGRADED-LANES filed under observe-to-close, not agent-ready"

# 14b. Lanes go green (no DEGRADED-LANES line in the tick at all) -> the
# observe-to-close closeout still fires regardless of the label.
cat > "$tmp/triage14-off.md" <<'EOF'
[2026-08-28T13:30:00Z] [HEARTBEAT-OK] lanes green
EOF
cat > "$tmp/open14b.json" <<'EOF'
[{"number": 4966, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `DEGRADED-LANES`\n\nDo NOT close this issue on PR merge alone. The reconciler closes it only when the detector reports green on a real heartbeat tick (observe-to-close).\n\n`loud/degraded-lanes/0509-2189.service`\n", "labels": [{"name": "observe-to-close"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open14b.json" "$tmp/triage14-off.md" > "$tmp/summary14b.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary14b.json" >/dev/null \
    || fail "scenario 14b: green DEGRADED-LANES must observe-to-close (got: $(cat "$tmp/summary14b.json"))"
grep -q "issue close 4966" "$tmp/gh.log" \
    || fail "scenario 14b: expected gh issue close 4966 (got: $(cat "$tmp/gh.log"))"
ok "scenario 14b: green DEGRADED-LANES observe-to-closes under the label"

# 14c. Retroactive downgrade (fleet-ops#4987): #4981 re-routes DEGRADED-LANES
# to observe-to-close only for NEW filings. An ALREADY-OPEN agent-ready
# DEGRADED-LANES issue (filed before that routing landed, e.g. #4987 itself)
# is deduped but never downgraded, so the intake keeps claiming it and burns
# a worker seat on an observe-to-close-only alarm. The reconcile must
# retroactively re-label an open agent-ready (#4987) / agent-in-progress
# DEGRADED-LANES issue to observe-to-close while the alarm is still live.
cat > "$tmp/triage14c.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEGRADED-LANES] degraded=1 :: pi-issue@0509-2507.service sub=auto-restart :: ...
EOF
cat > "$tmp/open14c.json" <<'EOF'
[{"number": 4987, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `DEGRADED-LANES`\n\nDo NOT close this issue on PR merge alone. The reconciler closes it only when the detector reports green on a real heartbeat tick (observe-to-close).\n\n`loud/degraded-lanes/0509-2507.service`\n", "labels": [{"name": "agent-in-progress"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open14c.json" "$tmp/triage14c.md" > "$tmp/summary14c.json"
jq -e '.rerouted == 1 and .filed == 0' "$tmp/summary14c.json" >/dev/null \
    || fail "scenario 14c: live agent-in-progress DEGRADED-LANES must be retroactively rerouted to observe-to-close (got: $(cat "$tmp/summary14c.json"))"
grep -q 'issue edit 4987' "$tmp/gh.log" \
    || fail "scenario 14c: expected gh issue edit 4987 (got: $(cat "$tmp/gh.log"))"
ok "scenario 14c: live agent-in-progress DEGRADED-LANES is retroactively downgraded to observe-to-close"

# ---------------------------------------------------------------------------
# 15. Informational class guard (fleet-ops#4983): an UNKNOWN tag — not in
#     SKIP_TAGS — whose derived key is stable across varying message content
#     is never-green by construction and must not be queued. Every SKIP_TAGS
#     entry above was added one-at-a-time AFTER a live page (#4620/#4918/
#     #4930/#4955/#4944/#4945); this guard ends the fire-first pattern by
#     failing closed on the two never-green shapes: (a) the bare
#     `loud/<tag>` fallback (subkey "unspecified" = no occurrence
#     discriminator possible) and (b) field=value telemetry whose varying
#     values never reach the derived key.
# ---------------------------------------------------------------------------

# 15a. Synthetic informational signals NOT in SKIP_TAGS are not queued:
#      CLAIM-RELEASED-CONFIRM is a count-shaped completion rollup under a tag
#      the reconciler has never seen, and X-ARCHIVED is a count-shaped
#      archive line. Both carry field=value telemetry whose varying values
#      (instance slug, count) are dropped from the derived key, so any
#      re-emission re-derives the identical signal — never-green.
cat > "$tmp/empty15.json" <<'EOF'
[]
EOF
cat > "$tmp/triage15a.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-RELEASED-CONFIRM] instance=0509-9999 repo=Nishfleet/0509 count=3
[2026-08-28T13:30:00Z] [X-ARCHIVED] instance=fleet-ops-5555 repo=Nishfleet/fleet-ops count=7
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty15.json" "$tmp/triage15a.md" > "$tmp/summary15a.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary15a.json" >/dev/null \
    || fail "scenario 15a: unlisted informational signals must not be queued, got: $(cat "$tmp/summary15a.json")"
[[ $(wc -l < "$tmp/filed.jsonl") -eq 0 ]] \
    || fail "scenario 15a: must not file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 15a: informational class guard blocks unlisted telemetry signals"

# 15b. The guard decision rests on the key being stable across varying
#      message content: dump two differing CLAIM-RELEASED-CONFIRM messages,
#      assert the extracted keys are equal (constant per repo), and assert
#      derive_signals suppresses both. An exempt hand-keyed tag
#      (FAILED-COMMAND-SWALLOWED, session-keyed per fleet-ops#4884) is
#      unaffected.
python3 - "$repo_root" <<'PY' || fail "scenario 15b: guard must fail closed on stable keys"
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "dqr", sys.argv[1] + "/lib/detector-queue-reconciler.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
keys = set()
for inst, n in [("0509-9999", 3), ("0509-1111", 9), ("0509-42", 1)]:
    msg = f"instance={inst} repo=Nishfleet/0509 count={n}"
    keys.add(tuple(m._extract_signal_key("CLAIM-RELEASED-CONFIRM", msg)))
    assert m.derive_signals("CLAIM-RELEASED-CONFIRM", msg) == [], \
        ("unlisted telemetry signal must not queue", msg)
# differing messages, identical key -> stable across varying content.
assert keys == {("nishfleet-0509",)}, keys
# exempt tag keeps its hand-keyed path (per-session discriminator).
sig = m.derive_signals(
    "FAILED-COMMAND-SWALLOWED",
    "session=abc-123 path=/tmp/x snippet=boom")
assert sig == ["loud/failed-command-swallowed/abc-123"], sig
PY
ok "scenario 15b: key is stable across varying content; exempt tag unaffected"

# 15c. The `unspecified` -> `loud/<tag>` fallback is reserved for genuinely
#      instance-keyed tags: an unknown tag whose message yields no
#      discriminating token at all (`n=42` leaves no surviving key word) is
#      constant-keyed by construction and must not be queued.
cat > "$tmp/triage15c.md" <<'EOF'
[2026-08-28T13:30:00Z] [SWEEP-NOTE] n=42
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty15.json" "$tmp/triage15c.md" > "$tmp/summary15c.json"
jq -e '.filed == 0 and .alarm_count == 0' "$tmp/summary15c.json" >/dev/null \
    || fail "scenario 15c: bare loud/<tag> fallback must not queue for unknown tags, got: $(cat "$tmp/summary15c.json")"
ok "scenario 15c: unspecified bare-key fallback is suppressed for unknown tags"

# 15d. The guard must not swallow declared classes or discriminated keys:
#      WIDGET-FAIL routes senior (-FAIL) so it is exempt and still queues;
#      WIDGET-WATCHER keys on a unit= value that DOES reach the derived key,
#      so occurrences are discriminated and it still queues agent-ready.
cat > "$tmp/triage15d.md" <<'EOF'
[2026-08-28T13:30:00Z] [WIDGET-FAIL] widget=9 broken attempts=4 — real fault
[2026-08-28T13:30:00Z] [WIDGET-WATCHER] unit=alpha.service state=dead
EOF
true > "$tmp/filed.jsonl"
run "$tmp/empty15.json" "$tmp/triage15d.md" > "$tmp/summary15d.json"
jq -e '.filed == 2' "$tmp/summary15d.json" >/dev/null \
    || fail "scenario 15d: senior-routed and discriminated-key signals must still queue, got: $(cat "$tmp/summary15d.json")"
grep -q 'loud/widget-fail/' "$tmp/filed.jsonl" \
    || fail "scenario 15d: WIDGET-FAIL must file, got: $(cat "$tmp/filed.jsonl")"
grep -q '"escalate-senior"' "$tmp/filed.jsonl" \
    || fail "scenario 15d: WIDGET-FAIL must route senior, got: $(cat "$tmp/filed.jsonl")"
grep -q 'loud/widget-watcher/alpha.service' "$tmp/filed.jsonl" \
    || fail "scenario 15d: discriminated unit key must file, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 15d: declared fault classes and discriminated keys still queue"

# 15e. Terminus: an already-open issue filed under a now-suppressed
#      never-green signal observe-to-closes while the informational line
#      keeps firing — the same terminus as the per-tag 9*-close scenarios.
cat > "$tmp/open15e.json" <<'EOF'
[{"number": 5983, "body": "The heartbeat detector reported this alarm on a real tick.\n\n- alarm tag: `CLAIM-RELEASED-CONFIRM`\n\n`loud/claim-released-confirm/nishfleet-0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF
cat > "$tmp/triage15e.md" <<'EOF'
[2026-08-28T13:30:00Z] [CLAIM-RELEASED-CONFIRM] instance=0509-9999 repo=Nishfleet/0509 count=3
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open15e.json" "$tmp/triage15e.md" > "$tmp/summary15e.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary15e.json" >/dev/null \
    || fail "scenario 15e: stale suppressed-signal issue must observe-to-close while the line fires, got: $(cat "$tmp/summary15e.json")"
grep -q "issue close 5983" "$tmp/gh.log" \
    || fail "scenario 15e: expected gh issue close 5983"
ok "scenario 15e: stale suppressed-signal issue observe-to-closes while the line fires"

# ---------------------------------------------------------------------------
# 16. AUDITOR-PANEL-PENDING alarms are observe-to-close-only (fleet-ops#4965).
#     A pending senior panel is load-borne — the per-tick start cap defers
#     seat starts under backlog and the panel self-heals via stale-SKIP
#     recast (#3962) and SKIP-EXHAUSTED abstention (#4503). There is no
#     manual worker action: identical filings #4812/#4877 closed via
#     observe-to-close with zero worker code, and #4965 alone burned 7 claims
#     and 2 StartLimitBursts on workers that re-verified and exited with no
#     PR.
#
#     16a. A fresh AUDITOR-PANEL-PENDING alarm files under `observe-to-close`,
#          NOT `agent-ready`, so the intake will not claim it.
#     16b. An already-open agent-ready filing is retroactively re-labeled to
#          observe-to-close while the alarm still fires (dedupe path).
#     16c. The detector's observe-to-close STILL closes it on the green tick.
# ---------------------------------------------------------------------------
panel_msg="repo=0509 candidate=2581 age_s=3615 active=0 missing=1 failed=0 — senior auditor panel has not convened"
cat > "$tmp/triage16-on.md" <<EOF
[2026-08-28T13:30:00Z] [AUDITOR-PANEL-PENDING] $panel_msg
EOF
cat > "$tmp/open16.json" <<'EOF'
[{"number": 4965, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector→queue reconciler filed one.\n\n- alarm tag: `AUDITOR-PANEL-PENDING`\n\nDo NOT close this issue on PR merge alone. The reconciler closes it only when the detector reports green on a real heartbeat tick (observe-to-close).\n\n`loud/auditor-panel-pending/candidate-age_s-active-missing-failed`\n", "labels": [{"name": "agent-ready"}, {"name": "agent-in-progress"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF

# 16a. Fresh AUDITOR-PANEL-PENDING files with observe-to-close, not agent-ready.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty14.json" "$tmp/triage16-on.md" > "$tmp/summary16a.json"
jq -e '.filed == 1 and .closed == 0' "$tmp/summary16a.json" >/dev/null \
    || fail "scenario 16a: AUDITOR-PANEL-PENDING must file one issue (got: $(cat "$tmp/summary16a.json"))"
grep -q 'loud/auditor-panel-pending/candidate-age_s-active-missing-failed' "$tmp/filed.jsonl" \
    || fail "scenario 16a: AUDITOR-PANEL-PENDING signal key missing (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"labels": \["observe-to-close"\]' \
    || fail "scenario 16a: must file under observe-to-close, not agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"agent-ready"' \
    && fail "scenario 16a: must NOT carry agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
ok "scenario 16a: AUDITOR-PANEL-PENDING filed under observe-to-close, not agent-ready"

# 16b. Alarm still firing + open agent-ready filing -> dedupe AND retroactive
# re-label to observe-to-close so the intake stops claiming it (#4965's live
# claim-burn loop). The issue must NOT close while the alarm is live.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open16.json" "$tmp/triage16-on.md" > "$tmp/summary16b.json"
jq -e '.deduped == 1 and .closed == 0 and .rerouted == 1' "$tmp/summary16b.json" >/dev/null \
    || fail "scenario 16b: expected deduped+rerouted, not closed (got: $(cat "$tmp/summary16b.json"))"
grep -q "issue edit 4965" "$tmp/gh.log" \
    || fail "scenario 16b: expected gh issue edit 4965 (got: $(cat "$tmp/gh.log"))"
grep -q -- "--add-label observe-to-close" "$tmp/gh.log" \
    || fail "scenario 16b: must add observe-to-close (got: $(cat "$tmp/gh.log"))"
grep -q -- "--remove-label agent-ready" "$tmp/gh.log" \
    || fail "scenario 16b: must remove agent-ready (got: $(cat "$tmp/gh.log"))"
! grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 16b: still-alarmed issue must NOT close (gh.log: $(cat "$tmp/gh.log"))"
ok "scenario 16b: open agent-ready filing retroactively re-labeled observe-to-close while alarmed"

# 16c. Panel convenes (no AUDITOR-PANEL-PENDING line in the tick) -> the
# observe-to-close closeout fires regardless of the label.
cat > "$tmp/triage16-off.md" <<'EOF'
[2026-08-28T13:30:00Z] [AUDITOR-PANEL-GREEN] every senior auditor panel convened
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open16.json" "$tmp/triage16-off.md" > "$tmp/summary16c.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary16c.json" >/dev/null \
    || fail "scenario 16c: convened panel must observe-to-close (got: $(cat "$tmp/summary16c.json"))"
grep -q "issue close 4965" "$tmp/gh.log" \
    || fail "scenario 16c: expected gh issue close 4965 (got: $(cat "$tmp/gh.log"))"
ok "scenario 16c: convened panel observe-to-closes the filing"

# 17. FAILED-COMMAND-SWALLOWED alarms are observe-to-close-only (fleet-ops#4990).
#     #4884 re-keyed the tag to the detector's own `session=<slug>` field, so
#     every filing is session-scoped and can only go green when THAT session
#     ages out of the 24h detection window. There is no manual worker action:
#     the swallow belongs to the originating session (over by filing time) and
#     the class is pinned in tests/fleet-failed-command-edit-unmatch.test.sh.
#     Every prior filing closed via observe-to-close with zero worker code
#     (#4884/#4921/#4933); routing them agent-ready burned 33 claims across 10
#     filings in one day, #4990 alone 8 claims and 2 StartLimitBursts on
#     workers that re-verified the alarm and exited with no PR.
#
#     17a. A fresh FAILED-COMMAND-SWALLOWED alarm files under
#          `observe-to-close`, NOT `agent-ready`, so the intake will not claim
#          it — keyed on the session, not the snippet's file token.
#     17b. An already-open agent-ready filing is retroactively re-labeled to
#          observe-to-close while the alarm still fires (dedupe path).
#     17c. The detector's observe-to-close STILL closes it on the green tick.
# ---------------------------------------------------------------------------
swallowed_slug="2026-09-09t20-54-41-144z-0509-2136-1788987280885921928"
cat > "$tmp/triage17-on.md" <<EOF
[2026-08-28T13:30:00Z] [FAILED-COMMAND-SWALLOWED] session=$swallowed_slug path=/home/nish/.pi/agent/sessions/pi-issue-0509-2136/s.jsonl snippet=Could not find the exact text in /home/nish/workspaces/agent-worktrees/0509-2136-fresh/app/routes.ts. The old text must match exactly including all whitespace and newlines.
EOF
cat > "$tmp/open17.json" <<'EOF'
[{"number": 4990, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `FAILED-COMMAND-SWALLOWED`\n\nDo NOT close this issue on PR merge alone. The reconciler closes it only when the detector reports green on a real heartbeat tick (observe-to-close).\n\n`loud/failed-command-swallowed/2026-09-09t20-54-41-144z-0509-2136-1788987280885921928`\n", "labels": [{"name": "agent-in-progress"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF

# 17a. Fresh FAILED-COMMAND-SWALLOWED files with observe-to-close, not
# agent-ready.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty14.json" "$tmp/triage17-on.md" > "$tmp/summary17a.json"
jq -e '.filed == 1 and .closed == 0' "$tmp/summary17a.json" >/dev/null \
    || fail "scenario 17a: FAILED-COMMAND-SWALLOWED must file one issue (got: $(cat "$tmp/summary17a.json"))"
grep -q "loud/failed-command-swallowed/$swallowed_slug" "$tmp/filed.jsonl" \
    || fail "scenario 17a: FAILED-COMMAND-SWALLOWED signal key missing (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"labels": \["observe-to-close"\]' \
    || fail "scenario 17a: must file under observe-to-close, not agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"agent-ready"' \
    && fail "scenario 17a: must NOT carry agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
ok "scenario 17a: FAILED-COMMAND-SWALLOWED filed under observe-to-close, not agent-ready"

# 17b. Alarm still firing + open agent-in-progress filing -> dedupe AND
# retroactive re-label to observe-to-close so the intake stops claiming it
# (#4990's live claim-burn loop). The issue must NOT close while the alarm is
# live.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open17.json" "$tmp/triage17-on.md" > "$tmp/summary17b.json"
jq -e '.deduped == 1 and .closed == 0 and .rerouted == 1' "$tmp/summary17b.json" >/dev/null \
    || fail "scenario 17b: expected deduped+rerouted, not closed (got: $(cat "$tmp/summary17b.json"))"
grep -q "issue edit 4990" "$tmp/gh.log" \
    || fail "scenario 17b: expected gh issue edit 4990 (got: $(cat "$tmp/gh.log"))"
grep -q -- "--add-label observe-to-close" "$tmp/gh.log" \
    || fail "scenario 17b: must add observe-to-close (got: $(cat "$tmp/gh.log"))"
grep -q -- "--remove-label agent-in-progress" "$tmp/gh.log" \
    || fail "scenario 17b: must remove agent-in-progress (got: $(cat "$tmp/gh.log"))"
! grep -q "issue close" "$tmp/gh.log" \
    || fail "scenario 17b: still-alarmed issue must NOT close (gh.log: $(cat "$tmp/gh.log"))"
ok "scenario 17b: open agent-in-progress filing retroactively re-labeled observe-to-close while alarmed"

# 17c. The session ages out of the detector window (no
# FAILED-COMMAND-SWALLOWED line in the tick) -> the observe-to-close closeout
# fires regardless of the label.
cat > "$tmp/triage17-off.md" <<'EOF'
[2026-08-28T13:30:00Z] [FAILED-COMMAND-OK] no swallowed failures in window (scanned=1626)
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open17.json" "$tmp/triage17-off.md" > "$tmp/summary17c.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary17c.json" >/dev/null \
    || fail "scenario 17c: aged-out session must observe-to-close (got: $(cat "$tmp/summary17c.json"))"
grep -q "issue close 4990" "$tmp/gh.log" \
    || fail "scenario 17c: expected gh issue close 4990 (got: $(cat "$tmp/gh.log"))"
ok "scenario 17c: aged-out FAILED-COMMAND-SWALLOWED observe-to-closes the filing"

# ---------------------------------------------------------------------------
# 18. find_existing_signal matches the backticked trailer issue_body() writes
#     (fleet-ops#5076). The old substring check (`f"{signal}\n" in body` /
#     endswith) could never see a `` `signal` `` trailer, so every issue the
#     reconciler filed looked new to the helper. The matcher must accept the
#     real filed form — and must NOT be satisfied by an unrelated issue that
#     merely mentions the signal key in prose.
# ---------------------------------------------------------------------------
python3 - "$lib" <<'PY' || fail "scenario 18: find_existing_signal trailer matching failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dqr", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["dqr"] = m
spec.loader.exec_module(m)

sig = "slo/seat-availability-slowburn"

# The exact body issue_body() writes — signal trailer is a backticked line.
filed = m.issue_body(
    sig, "SLO-SEAT-SLOWBURN", "signal: slo/seat-availability-slowburn burn-rate high",
    "2026-09-10T21:00:00Z",
)
issue = {"number": 5076, "body": filed, "comments": []}
assert m.find_existing_signal([issue], sig) is issue, \
    "issue_body() backticked trailer must be found"

# Older carrier forms still count as carrying the key.
legacy = {"number": 5077, "body": f"preamble\n{sig}\n", "comments": []}
assert m.find_existing_signal([legacy], sig) is legacy, \
    "bare trailer line must still match"
keyed = {"number": 5078, "body": f"signal: {sig}\n", "comments": []}
assert m.find_existing_signal([keyed], sig) is keyed, \
    "signal: <key> marker line must still match"

# An unrelated issue that only mentions the key in prose must not match.
prose = {
    "number": 5079,
    "body": f"Investigating — the detector mentions {sig} in passing, see also `loud/other`.\n",
    "comments": [{"body": f"more prose about {sig} here"}],
}
assert m.find_existing_signal([prose], sig) is None, \
    "prose mention of the signal must not match"
assert m.find_existing_signal([prose, issue], sig) is issue, \
    "real filing must win over a prose-mention issue"
print("scenario 18 assertions passed")
PY
ok "scenario 18: find_existing_signal matches the issue_body() backticked trailer, not prose mentions"

# ---------------------------------------------------------------------------
# 19. ESCALATION-PANEL-PENDING alarms are observe-to-close-only (fleet-ops#5057).
#     The exact loud() tag asserted first in bin/pi-escalation-audit — a
#     pending senior escalation panel is load-borne and self-heals via
#     stale-SKIP recast (#3962) and SKIP-EXHAUSTED abstention (#4503). There
#     is no manual worker action: every prior filing closed via
#     observe-to-close with zero worker code; routing them agent-ready
#     burned an admission-priced worker seat per occurrence.
#
#     19a. A fresh ESCALATION-PANEL-PENDING alarm files under
#          `observe-to-close`, NOT `agent-ready`, so the intake will not
#          claim it.
#     19b. The detector's observe-to-close STILL closes it on the green tick
#          (panel convenes, no ESCALATION-PANEL-PENDING line in the tick).
# ---------------------------------------------------------------------------
cat > "$tmp/triage19-on.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-PANEL-PENDING] repo=Nishfleet/0509 candidate=Nishfleet/0509#5100 age_s=4200 active=1 missing=2 failed=0 - senior escalation panel has not convened
EOF
cat > "$tmp/open19.json" <<'EOF'
[{"number": 5100, "body": "The heartbeat detector reported this alarm on a real tick and no open issue carried its signal key, so the detector\u2192queue reconciler filed one.\n\n- alarm tag: `ESCALATION-PANEL-PENDING`\n\nDo NOT close this issue on PR merge alone. The reconciler closes it only when the detector reports green on a real heartbeat tick (observe-to-close).\n\n`loud/escalation-panel-pending/0509`\n", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-28T10:00:00Z", "comments": []}]
EOF

# 19a. Fresh ESCALATION-PANEL-PENDING files with observe-to-close, not
# agent-ready.
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty14.json" "$tmp/triage19-on.md" > "$tmp/summary19a.json"
jq -e '.filed == 1 and .closed == 0' "$tmp/summary19a.json" >/dev/null \
    || fail "scenario 19a: ESCALATION-PANEL-PENDING must file one issue (got: $(cat "$tmp/summary19a.json"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q 'loud/escalation-panel-pending' \
    || fail "scenario 19a: ESCALATION-PANEL-PENDING signal key missing (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"labels": \["observe-to-close"\]' \
    || fail "scenario 19a: must file under observe-to-close, not agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
printf '%s' "$(cat "$tmp/filed.jsonl")" | grep -q '"agent-ready"' \
    && fail "scenario 19a: must NOT carry agent-ready (filed: $(cat "$tmp/filed.jsonl"))"
ok "scenario 19a: ESCALATION-PANEL-PENDING filed under observe-to-close, not agent-ready"

# 19b. Panel convenes (no ESCALATION-PANEL-PENDING line in the tick) -> the
# observe-to-close closeout fires regardless of the label.
cat > "$tmp/triage19-off.md" <<'EOF'
[2026-08-28T13:30:00Z] [ESCALATION-PANEL-OK] senior escalation panel convened (members=3)
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/open19.json" "$tmp/triage19-off.md" > "$tmp/summary19b.json"
jq -e '.closed == 1 and .filed == 0' "$tmp/summary19b.json" >/dev/null \
    || fail "scenario 19b: convened panel must observe-to-close (got: $(cat "$tmp/summary19b.json"))"
grep -q "issue close 5100" "$tmp/gh.log" \
    || fail "scenario 19b: expected gh issue close 5100 (got: $(cat "$tmp/gh.log"))"
ok "scenario 19b: convened ESCALATION-PANEL observe-to-closes the filing"

ok "all signal-reconcile scenarios passed"
