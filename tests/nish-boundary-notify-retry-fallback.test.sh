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

echo ""
echo "OK: nish-boundary-notify retry + fallback drill (fleet-ops#1458) — 4/4 scenarios pass"
