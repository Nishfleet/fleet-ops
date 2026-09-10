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
# 9c. DEBUG-PLAYBOOK-GATE-BLOCK keys on the RULE too (fleet-ops#4516/4579).
#     Same rule-level dedupe as 9b: no noisy `_dirty-worktree-audit.py` key and
#     no per-session split.
# ---------------------------------------------------------------------------
cat > "$tmp/empty9c.json" <<'EOF'
[]
EOF
cat > "$tmp/triage9c.md" <<'EOF'
[2026-08-28T13:30:00Z] [DEBUG-PLAYBOOK-GATE-BLOCK] session=2026-09-08t07-35-48z-0509-1279-abc222 attempts=4 snippet=agent-cron-run agent-scheduler-drift-check _dirty-worktree-audit.py escalation-daily-sweep
EOF
true > "$tmp/filed.jsonl"
true > "$tmp/gh.log"
run "$tmp/empty9c.json" "$tmp/triage9c.md" > "$tmp/summary9c.json"
jq -e '.filed == 1' "$tmp/summary9c.json" >/dev/null     || fail "scenario 9c: expected one filed"
grep -q "loud/debug-playbook-gate-block" "$tmp/filed.jsonl"     || fail "scenario 9c: signal must key on the rule, got: $(cat "$tmp/filed.jsonl")"
grep -q "loud/debug-playbook-gate-block/2026-09-08t07-35-47z-0509-1279-abc222" "$tmp/filed.jsonl"     && fail "scenario 9c: signal must NOT key on the session, got: $(cat "$tmp/filed.jsonl")"
ok "scenario 9c: DEBUG-PLAYBOOK-GATE-BLOCK keys on the rule, not the session"

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
#     GATE-BLOCK still queues (scenario 9c). The daily rollup is DEBUG-PLAYBOOK-FAIL.
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

ok "all signal-reconcile scenarios passed"
