#!/usr/bin/env bash
# tests/nish-boundary-notify-retry-fallback.test.sh
#
# fleet-ops#1458: nish-boundary-notify failed delivery twice silently on
# 2026-08-28 (00:12 + 00:15 IST) — the Nish-reserved channel delivered 7h
# late during an active Grok-401 incident. The root cause (seats= grep abort
# under set -euo pipefail) was fixed by #1349; this test locks the REMAINING
# mechanical guarantee from #1458: on delivery failure the unit must retry
# hermes on a short backoff, and if hermes is exhausted it must exit 1 (loud
# — OnFailure summons an auditor).
#
# fleet-ops#4145: the direct Telegram Bot API fallback was retired with the
# hand-built claude-telegram-bridge.py. Hermes is now the single phone path.
# This test was rewritten to match: there is no fallback path, so a hermes
# outage is LOUD (exit 1) instead of silently bypassed. The retry count and
# loud-failure guarantees from #1458 still hold; the fallback guarantee does
# not (it is gone by design).
#
# The drill forces a hermes failure (a fake hermes that always exits 1) and
# proves the retry count fires and the run exits 1. A succeeding fake hermes
# proves delivery marks the entry seen. A spurious trigger (no unseen entries)
# exits 0, not 1.
#
# Runs offline against temp files. No live state, no real Telegram send.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/nish-boundary-notify"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "missing: $script"
[[ -x "$script" ]] || fail "not executable: $script"
bash -n "$script" || fail "bash syntax error in $script"

# --- shared fixtures --------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state"
mkdir -p "$state/lanes"
seen="$state/lanes/nish-boundary-notify.seen"
escalations="$state/NISH-ESCALATIONS.md"
: > "$seen"

# A boundary entry with NO provider seats (the LEGAL-BOUNDARY class that
# triggered the 00:12 abort — body names no devin/minimax/etc).
entry_line="2026-08-28T00:12:20Z LEGAL-BOUNDARY hash=drill-1458-legal-basics"
{
  printf '%s\n' "$entry_line"
  printf '  SUMMARY: drill test for fleet-ops#1458 retry + loud failure\n'
  printf '  NISH DECISION NEEDED: prove retry fires and failure is loud\n'
} > "$escalations"

# Fake hermes that always fails — logs each invocation (one line each) so the
# test can count retries. Exits 1 to simulate a hermes outage.
fake_hermes_fail="$tmp/fake-hermes-fail"
cat > "$fake_hermes_fail" <<'EOF'
#!/usr/bin/env bash
printf 'hermes-invoked\n' >> "$HERMES_LOG"
exit 1
EOF
chmod +x "$fake_hermes_fail"

# Fake hermes that always succeeds — logs each invocation so the test can
# prove delivery. Exits 0.
fake_hermes_ok="$tmp/fake-hermes-ok"
cat > "$fake_hermes_ok" <<'EOF'
#!/usr/bin/env bash
printf 'hermes-invoked\n' >> "$HERMES_LOG"
exit 0
EOF
chmod +x "$fake_hermes_ok"

# --- scenario 1: hermes fails -> retry fires -> exit 1 (loud, no fallback) ---
echo "--- scenario 1: hermes fails -> retry -> exit 1 (loud, no fallback) ---"
hermes_log="$tmp/hermes.log"; : > "$hermes_log"

# BOUNDARY_NOTIFY_BACKOFF="0 0" makes retries instant (no real sleep) so the
# test is fast. The script still iterates 3 times (initial + 2 backoffs).
set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_fail" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log" \
bash "$script" > "$tmp/out1" 2>"$tmp/err1"
rc=$?
set -e

hermes_calls=$(wc -l < "$hermes_log")
echo "hermes invocations: $hermes_calls, exit: $rc"

[[ "$hermes_calls" -ge 3 ]] \
  || fail "hermes must retry at least 3 times (initial + 2 backoffs); got $hermes_calls"
ok "hermes retried $hermes_calls times (>= 3)"

[[ "$rc" -eq 1 ]] \
  || fail "hermes exhausted must exit 1 (loud for OnFailure, no fallback); got $rc"
ok "hermes exhaustion exits 1 (loud, no fallback)"

grep -q "DELIVERY FAILED" "$tmp/err1" \
  || fail "stderr must report DELIVERY FAILED; got: $(cat "$tmp/err1")"
ok "DELIVERY FAILED reported on stderr"

# The entry must NOT be marked seen (delivery failed — retry next trigger).
key=$(printf '%s' "$entry_line" | sha256sum | cut -c1-32)
grep -qxF "$key" "$seen" \
  && fail "failed delivery must NOT be marked seen" || ok "failed delivery not marked seen"

# --- scenario 2: hermes succeeds on first try -> delivered, exit 0 ----------
echo "--- scenario 2: hermes succeeds -> delivered, exit 0 ---"
: > "$seen"
hermes_log2="$tmp/hermes2.log"; : > "$hermes_log2"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_ok" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log2" \
bash "$script" > "$tmp/out2" 2>"$tmp/err2"
rc2=$?
set -e

echo "exit: $rc2"
[[ "$rc2" -eq 0 ]] || fail "successful delivery must exit 0; got $rc2"
ok "hermes success exits 0"

grep -q "delivered (hermes, attempt 1)" "$tmp/out2" \
  || fail "output must report hermes delivery; got: $(cat "$tmp/out2")"
ok "hermes delivery reported in output"

grep -qxF "$key" "$seen" \
  || fail "delivered entry must be marked seen"
ok "delivered entry marked seen"

# --- scenario 3: spurious trigger, no unseen entries -> exit 0 --------------
echo "--- scenario 3: spurious trigger (all seen) -> exit 0 ---"
: > "$seen"
# Mark the entry as already seen.
printf '%s\n' "$key" > "$seen"
hermes_log3="$tmp/hermes3.log"; : > "$hermes_log3"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_fail" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log3" \
bash "$script" > "$tmp/out3" 2>"$tmp/err3"
rc3=$?
set -e

echo "exit code: $rc3"
[[ "$rc3" -eq 0 ]] \
  || fail "spurious trigger (all entries seen) must exit 0, not $rc3"
ok "spurious trigger exits 0 (no false failure)"

hermes_calls3=$(wc -l < "$hermes_log3")
[[ "$hermes_calls3" -eq 0 ]] \
  || fail "no delivery attempt on all-seen trigger; got $hermes_calls3 hermes calls"
ok "no delivery attempted when nothing unseen"

# --- scenario 4: no boundary entries at all -> exit 0 -----------------------
echo "--- scenario 4: no boundary entries -> exit 0 ---"
printf '# empty\n' > "$escalations"
: > "$seen"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_fail" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log3" \
bash "$script" > "$tmp/out4" 2>"$tmp/err4"
rc4=$?
set -e

echo "exit code: $rc4"
[[ "$rc4" -eq 0 ]] \
  || fail "no boundary entries must exit 0 (grep no-match must not abort); got $rc4"
ok "no-entries trigger exits 0 (grep no-match does not abort)"

# --- scenario 5: prose-format reserved entry is delivered via hermes --------
# fleet-ops#4048: the old parser only matched the timestamp shape, so a prose
# section (`## YYYY-MM-DD — title` with a NISH ACTION bullet) was never
# delivered while the unit exited 0. The prose-scan detector must deliver it.
# Here hermes SUCCEEDS, so the prose path must deliver via hermes (proving the
# prose path reuses the same retry machinery).
echo "--- scenario 5: prose-format reserved entry is delivered via hermes ---"
cat > "$escalations" <<'EOS'
## 2026-09-08 — drill prose NISH ACTION (fleet-ops#4048)
- **NISH ACTION (money — drill that prose delivery fires):** no-op drill ask; the detector must deliver this, not exit silently.
EOS
: > "$seen"
hermes_log5="$tmp/hermes5.log"; : > "$hermes_log5"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_ok" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log5" \
bash "$script" > "$tmp/out5" 2>"$tmp/err5"
rc5=$?
set -e
echo "exit code: $rc5"

# The run must NOT be a silent green: the prose NISH ACTION must be reported
# as delivered via hermes.
grep -q "delivered (hermes, attempt 1)" "$tmp/out5" \
  || fail "prose reserved entry must be delivered via hermes, not silently dropped; out=$(cat "$tmp/out5")"
ok "prose NISH ACTION delivered via hermes (not a silent green)"

hermes_calls5=$(wc -l < "$hermes_log5")
echo "hermes invocations: $hermes_calls5"
[[ "$hermes_calls5" -ge 1 ]] \
  || fail "prose delivery must invoke hermes at least once; got $hermes_calls5"
ok "prose path reused the retry machinery"

# The prose marker must be marked seen (de-duped on the next trigger).
prose_line="## 2026-09-08 — drill prose NISH ACTION (fleet-ops#4048)|- **NISH ACTION (money — drill that prose delivery fires):** no-op drill ask; the detector must deliver this, not exit silently."
pkey=$(printf '%s' "$prose_line" | sha256sum | cut -c1-32)
grep -qxF "$pkey" "$seen" \
  || fail "delivered prose marker must be marked seen"
ok "prose marker marked seen"

# --- scenario 6: prose reserved entry, delivery fails -> exit 1 (loud) -----
# The mirror of scenario 5: an undeliverable prose reserved item must NOT exit
# 0 either — it exits 1 so OnFailure summons an auditor (fleet-ops#4048).
echo "--- scenario 6: prose reserved entry, undeliverable -> exit 1 ---"
cat > "$escalations" <<'EOS'
## 2026-09-09 — drill prose NISH DECISION NEEDED (fleet-ops#4048)
- **NISH DECISION NEEDED (drill):** this prose item must trip exit 1 when undeliverable.
EOS
: > "$seen"
hermes_log6="$tmp/hermes6.log"; : > "$hermes_log6"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_fail" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log6" \
bash "$script" > "$tmp/out6" 2>"$tmp/err6"
rc6=$?
set -e
echo "exit code: $rc6"
[[ "$rc6" -eq 1 ]] \
  || fail "undeliverable prose reserved entry must exit 1 (loud), got $rc6"
ok "undeliverable prose reserved entry exits 1 (loud)"

grep -q "DELIVERY FAILED" "$tmp/err6" \
  || fail "stderr must report DELIVERY FAILED on prose failure; got: $(cat "$tmp/err6")"
ok "prose DELIVERY FAILED reported on stderr"

# --- scenario 7: old prose marker (<= last delivered) is NOT backfiled ------
# A prose section dated no later than the newest entry-format line must not be
# re-delivered (the backfill must not re-page already-resolved history). Here
# an entry-format line dated 2026-09-07 makes a 2026-09-06 prose NISH ACTION
# (same vintage as the OpenRouter ask) sit BELOW the boundary -> skipped.
echo "--- scenario 7: prose older than last delivered entry is not backfiled ---"
{
  printf '## 2026-09-06 — drill old prose (fleet-ops#4048)\n'
  printf -- '- **NISH ACTION (money — old ask):** must NOT be re-delivered.\n'
  printf '2026-09-07T00:20:00Z MONEY-BOUNDARY newest-delivered-slug\n'
} > "$escalations"
: > "$seen"
hermes_log7="$tmp/hermes7.log"; : > "$hermes_log7"
# Succeeding hermes; but the entry-format line (newest, dated 09-07) is the only
# thing the boundary scan may deliver, so mark it seen in advance to force a
# pure "nothing new" run.
entry_key=$(printf '%s' '2026-09-07T00:20:00Z MONEY-BOUNDARY newest-delivered-slug' | sha256sum | cut -c1-32)
printf '%s\n' "$entry_key" > "$seen"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes_ok" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
HERMES_LOG="$hermes_log7" \
bash "$script" > "$tmp/out7" 2>"$tmp/err7"
rc7=$?
set -e
echo "exit code: $rc7"

# The old prose marker must NOT be delivered (boundary excludes it).
if grep -q "old ask" "$tmp/out7"; then
  fail "prose older than the last delivered entry must not be backfiled"
else
  ok "prose older than last-delivered entry not backfiled"
fi
# Deliveries (hermes) must be zero for this trigger: nothing unseen remains.
hermes_calls7=$(wc -l < "$hermes_log7")
echo "hermes invocations: $hermes_calls7"
set +e
[ "$rc7" -eq 0 ] && [ "$hermes_calls7" -eq 0 ]
rc7b=$?
set -e
[[ "$rc7b" -eq 0 ]] \
  || fail "old-prose-only trigger must exit 0 with zero deliveries (nothing new); rc=$rc7 hermes=$hermes_calls7"
ok "old-prose-only trigger exits 0 with zero deliveries"

echo ""
echo "OK: nish-boundary-notify retry + loud-failure drill (fleet-ops#1458 + #4145) + prose detector (#4048) — 7/7 scenarios pass"
