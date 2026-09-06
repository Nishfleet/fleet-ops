#!/usr/bin/env bash
# tests/nish-boundary-notify-retry-fallback.test.sh
#
# fleet-ops#1458: nish-boundary-notify failed delivery twice silently on
# 2026-08-28 (00:12 + 00:15 IST) — the Nish-reserved channel delivered 7h
# late during an active Grok-401 incident. The root cause (seats= grep abort
# under set -euo pipefail) was fixed by #1349; this test locks the REMAINING
# mechanical guarantee from #1458: on delivery failure the unit must
#   (a) retry hermes on a short backoff, AND
#   (b) fall back to a delivery path that does NOT share the failed
#       dependency (the direct Telegram Bot API, bypassing hermes).
#
# The drill forces a hermes failure (a fake hermes that always exits 1) and
# proves both the retry count and the fallback fire. A second scenario proves
# that when both paths fail the script exits 1 (loud — OnFailure summons an
# auditor). A third scenario proves a spurious trigger (no unseen entries)
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
  printf '  SUMMARY: drill test for fleet-ops#1458 retry + fallback\n'
  printf '  NISH DECISION NEEDED: prove retry and fallback both fire\n'
} > "$escalations"

# Fake hermes that always fails — logs each invocation (one line each) so the
# test can count retries. Exits 1 to simulate a hermes outage.
fake_hermes="$tmp/fake-hermes"
cat > "$fake_hermes" <<'EOF'
#!/usr/bin/env bash
printf 'hermes-invoked\n' >> "$HERMES_LOG"
exit 1
EOF
chmod +x "$fake_hermes"

# Fake fallback curl that always succeeds — logs each invocation (one line
# each) so the test can prove the fallback fired. Installed as $tmp/curl so
# PATH lookup finds it before the real /usr/bin/curl. Exits 0.
fake_curl="$tmp/curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-invoked\n' >> "$CURL_LOG"
exit 0
EOF
chmod +x "$fake_curl"

# A fake Telegram bridge env with dummy values (the script reads the token
# and chat_id from here; the fake curl never actually calls the API).
tgenv="$tmp/tg.env"
{
  printf 'CLAUDE_TELEGRAM_BOT_TOKEN=drill-dummy-token\n'
  printf 'CLAUDE_TELEGRAM_ALLOWED_USER_ID=1144372019\n'
} > "$tgenv"

# --- scenario 1: hermes fails, retry fires, fallback delivers ---------------
echo "--- scenario 1: hermes fails -> retry -> fallback delivers ---"
hermes_log="$tmp/hermes.log"; : > "$hermes_log"
curl_log="$tmp/curl.log"; : > "$curl_log"

# BOUNDARY_NOTIFY_BACKOFF="0 0" makes retries instant (no real sleep) so the
# test is fast. The script still iterates 3 times (initial + 2 backoffs).
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log" \
CURL_LOG="$curl_log" \
PATH="$tmp:/usr/bin:/bin" \
bash "$script" > "$tmp/out1" 2>"$tmp/err1" || true

hermes_calls=$(wc -l < "$hermes_log")
curl_calls=$(wc -l < "$curl_log")
echo "hermes invocations: $hermes_calls, fallback curl invocations: $curl_calls"

[[ "$hermes_calls" -ge 3 ]] \
  || fail "hermes must retry at least 3 times (initial + 2 backoffs); got $hermes_calls"
ok "hermes retried $hermes_calls times (>= 3)"

[[ "$curl_calls" -eq 1 ]] \
  || fail "fallback must fire exactly once after hermes exhausts; got $curl_calls"
ok "fallback direct-API fired once"

grep -q "delivered (fallback direct API)" "$tmp/out1" \
  || fail "output must report fallback delivery; got: $(cat "$tmp/out1")"
ok "fallback delivery reported in output"

# The entry must be marked seen (delivered).
key=$(printf '%s' "$entry_line" | sha256sum | cut -c1-32)
grep -qxF "$key" "$seen" \
  || fail "delivered entry must be marked seen"
ok "delivered entry marked seen"

# --- scenario 2: both hermes AND fallback fail -> exit 1 (loud) -------------
echo "--- scenario 2: both paths fail -> exit 1 ---"
: > "$seen"
# Replace fake curl with one that fails.
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-invoked\n' >> "$CURL_LOG"
exit 1
EOF
chmod +x "$tmp/curl"
hermes_log2="$tmp/hermes2.log"; : > "$hermes_log2"
curl_log2="$tmp/curl2.log"; : > "$curl_log2"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log2" \
CURL_LOG="$curl_log2" \
PATH="$tmp:/usr/bin:/bin" \
bash "$script" > "$tmp/out2" 2>"$tmp/err2"
rc=$?
set -e

echo "exit code: $rc"
[[ "$rc" -eq 1 ]] \
  || fail "both paths failing must exit 1 (loud for OnFailure); got $rc"
ok "both-paths-fail exits 1 (loud)"

grep -q "DELIVERY FAILED" "$tmp/err2" \
  || fail "stderr must report DELIVERY FAILED; got: $(cat "$tmp/err2")"
ok "DELIVERY FAILED reported on stderr"

# Entry must NOT be marked seen (delivery failed — retry next trigger).
grep -qxF "$key" "$seen" \
  && fail "failed delivery must NOT be marked seen" || ok "failed delivery not marked seen"

# --- scenario 3: spurious trigger, no unseen entries -> exit 0 --------------
echo "--- scenario 3: spurious trigger (all seen) -> exit 0 ---"
: > "$seen"
# Mark the entry as already seen.
printf '%s\n' "$key" > "$seen"
hermes_log3="$tmp/hermes3.log"; : > "$hermes_log3"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log3" \
PATH="$tmp:/usr/bin:/bin" \
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
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log3" \
PATH="$tmp:/usr/bin:/bin" \
bash "$script" > "$tmp/out4" 2>"$tmp/err4"
rc4=$?
set -e

echo "exit code: $rc4"
[[ "$rc4" -eq 0 ]] \
  || fail "no boundary entries must exit 0 (grep no-match must not abort); got $rc4"
ok "no-entries trigger exits 0 (grep no-match does not abort)"

# --- scenario 5: prose-format reserved entry is NOT silently dropped -------
# fleet-ops#4048: the old parser only matched the timestamp shape, so a prose
# section (`## YYYY-MM-DD — title` with a NISH ACTION bullet) was never
# delivered while the unit exited 0. The prose-scan detector must deliver it.
# Fake hermes still fails here, so the fallback curl must carry the delivery
# (proving the prose path reuses the same retry/fallback machinery).
echo "--- scenario 5: prose-format reserved entry is delivered, not silent ---"
cat > "$escalations" <<'EOS'
## 2026-09-08 — drill prose NISH ACTION (fleet-ops#4048)
- **NISH ACTION (money — drill that prose delivery fires):** no-op drill ask; the detector must deliver this, not exit silently.
EOS
: > "$seen"
# Restore the succeeding fake curl for this scenario.
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-invoked\n' >> "$CURL_LOG"
exit 0
EOF
chmod +x "$tmp/curl"
curl_log5="$tmp/curl5.log"; : > "$curl_log5"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log3" \
CURL_LOG="$curl_log5" \
PATH="$tmp:/usr/bin:/bin" \
bash "$script" > "$tmp/out5" 2>"$tmp/err5"
rc5=$?
set -e
echo "exit code: $rc5"

# The run must NOT be a silent green: the prose NISH ACTION must be reported
# as delivered (here on the fallback path since fake hermes always fails).
grep -q "delivered (fallback direct API)" "$tmp/out5" \
  || fail "prose reserved entry must be delivered, not silently dropped; out=$(cat "$tmp/out5")"
ok "prose NISH ACTION delivered (not a silent green)"

fallback_curl5=$(wc -l < "$curl_log5")
echo "fallback curl invocations: $fallback_curl5"
[[ "$fallback_curl5" -ge 1 ]] \
  || fail "prose delivery must fire the fallback at least once; got $fallback_curl5"
ok "prose path reused the retry/fallback machinery"

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
# Failing fake curl again (both delivery paths blocked).
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-invoked\n' >> "$CURL_LOG"
exit 1
EOF
chmod +x "$tmp/curl"
curl_log6="$tmp/curl6.log"; : > "$curl_log6"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log3" \
CURL_LOG="$curl_log6" \
PATH="$tmp:/usr/bin:/bin" \
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
curl_log7="$tmp/curl7.log"; : > "$curl_log7"
# Succeeding curl; but the entry-format line (newest, dated 09-07) is the only
# thing the boundary scan may deliver, so mark it seen in advance to force a
# pure "nothing new" run.
entry_key=$(printf '%s' '2026-09-07T00:20:00Z MONEY-BOUNDARY newest-delivered-slug' | sha256sum | cut -c1-32)
printf '%s\n' "$entry_key" > "$seen"
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-invoked\n' >> "$CURL_LOG"
exit 0
EOF
chmod +x "$tmp/curl"

set +e
UNIT_ESCALATION_AGENT_STATE="$state" \
BOUNDARY_NOTIFY_HERMES="$fake_hermes" \
BOUNDARY_NOTIFY_TGENV="$tgenv" \
BOUNDARY_NOTIFY_BACKOFF="0 0" \
BOUNDARY_NOTIFY_FALLBACK=1 \
HERMES_LOG="$hermes_log3" \
CURL_LOG="$curl_log7" \
PATH="$tmp:/usr/bin:/bin" \
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
# Deliveries (fallback) must be zero for this trigger: nothing unseen remains.
fallback_curl7=$(wc -l < "$curl_log7")
echo "fallback curl invocations: $fallback_curl7"
set +e
[ "$rc7" -eq 0 ] && [ "$fallback_curl7" -eq 0 ]
rc7b=$?
set -e
[[ "$rc7b" -eq 0 ]] \
  || fail "old-prose-only trigger must exit 0 with zero deliveries (nothing new); rc=$rc7 fallback=$fallback_curl7"
ok "old-prose-only trigger exits 0 with zero deliveries"

echo ""
echo "OK: nish-boundary-notify retry + fallback drill (fleet-ops#1458) + prose detector (fleet-ops#4048) — 7/7 scenarios pass"
