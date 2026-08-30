#!/usr/bin/env bash
# tests/vault-capture.test.sh
#
# fleet-ops#1265: paved-road vault capture. Lock test for the capture wrapper
# and adoption-ratio helper.
#
# Fixtures:
#   1. drop-zone procedure note (default frontmatter)         PASS
#   2. drop-zone live-state note with check-command           PASS
#   3. direct edit through the wrapper                        PASS
#   4. direct edit without the wrapper (manual file)          no audit log
#   5. drop-zone note that fails lint (live state, no check)  REFUSED / exit 2
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
capture="$repo_root/bin/siterep-vault-capture"
ratio="$repo_root/bin/siterep-vault-capture-ratio"
lint="$repo_root/lib/vault-lint.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$capture" ]] || fail "missing $capture"
[[ -x "$ratio" ]] || fail "missing $ratio"
[[ -f "$lint" ]] || fail "missing $lint"

scratch="$(mktemp -d -t vault-capture.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

VAULT="$scratch/vault"
mkdir -p "$VAULT/00 Inbox/agent-drop/terminal-agent"
mkdir -p "$VAULT/03 Knowledge/drafts"
mkdir -p "$VAULT/_system/logs"

export FLEET_VAULT="$VAULT"
# Use a long window so the just-written audit log lines are always in scope.
export SITEREP_CAPTURE_WINDOW=1000

# ---------------------------------------------------------------------------
# 1. drop-zone procedure note: default frontmatter, lint passes
# ---------------------------------------------------------------------------
receipt1=$(printf 'A short procedure note.' | "$capture" --topic 'test-procedure') \
  || fail "procedure drop-zone capture failed: $receipt1"
ok "1: procedure drop-zone capture succeeded"

printf '%s\n' "$receipt1" | grep -q 'wrote ' || fail "receipt missing wrote: $receipt1"
printf '%s\n' "$receipt1" | grep -q 'observed=' || fail "receipt missing observed: $receipt1"
printf '%s\n' "$receipt1" | grep -q 'class=procedure' || fail "receipt missing class: $receipt1"
printf '%s\n' "$receipt1" | grep -q 'check-command=none' || fail "receipt missing check-command: $receipt1"

note1=$(find "$VAULT/00 Inbox/agent-drop/terminal-agent" -name '*-test-procedure.md' | head -1)
[[ -f "$note1" ]] || fail "procedure note not written"
ok "1a: procedure note exists"

grep -q '^observed: ' "$note1" || fail "frontmatter missing observed"
grep -q '^host: ' "$note1" || fail "frontmatter missing host"
grep -q '^evidence: ' "$note1" || fail "frontmatter missing evidence"
grep -q '^class: procedure' "$note1" || fail "frontmatter missing class"
ok "1b: procedure frontmatter correct"

# ---------------------------------------------------------------------------
# 2. drop-zone live-state note with check-command
# ---------------------------------------------------------------------------
receipt2=$(
  printf 'fleet-heartbeat.service Active: active (running).' | \
  "$capture" --topic 'test-live' \
    --class drill-status \
    --evidence 'systemctl --user is-active fleet-heartbeat.timer' \
    --check-command 'systemctl --user is-active fleet-heartbeat.timer'
) || fail "live-state capture failed: $receipt2"
ok "2: live-state drop-zone capture succeeded"

note2=$(find "$VAULT/00 Inbox/agent-drop/terminal-agent" -name '*-test-live.md' | head -1)
[[ -f "$note2" ]] || fail "live-state note not written"
grep -q '^class: drill-status' "$note2" || fail "live-state class wrong"
grep -q '^check-command: ' "$note2" || fail "live-state missing check-command"
grep -q '^evidence: ' "$note2" || fail "live-state missing evidence"
ok "2a: live-state frontmatter correct"

# ---------------------------------------------------------------------------
# 3. direct edit through the wrapper
# ---------------------------------------------------------------------------
receipt3=$(
  printf 'A note written directly to a knowledge draft.' | \
  "$capture" --topic 'direct-wrapper' --class evidence --direct '03 Knowledge/drafts/direct-wrapper.md'
) || fail "direct-wrapper capture failed: $receipt3"
ok "3: direct-with-wrapper capture succeeded"

[[ -f "$VAULT/03 Knowledge/drafts/direct-wrapper.md" ]] || fail "direct note not written"
receipt3_rel=$(printf '%s' "$receipt3" | sed -n 's/^wrote \([^;]*\);.*/\1/p')
[[ "$receipt3_rel" == "03 Knowledge/drafts/direct-wrapper.md" ]] || fail "receipt path wrong: $receipt3"
ok "3a: direct-with-wrapper receipt path correct"

# ---------------------------------------------------------------------------
# 4. direct edit without the wrapper (manual file)
# ---------------------------------------------------------------------------
cat >"$VAULT/03 Knowledge/drafts/manual-direct.md" <<'EOF'
---
observed: 2026-08-28T00:00:00Z
host: netcup-rs2000
evidence: none
class: procedure
---

A manually edited note that never went through the wrapper.
EOF

# The manual file should NOT be in the capture audit log.
if grep -q 'manual-direct.md' "$VAULT/_system/logs/vault-capture.log"; then
  fail "manual direct edit should not appear in the capture audit log"
fi
ok "4: manual direct edit not in audit log"

# ---------------------------------------------------------------------------
# 5. drop-zone note that fails lint (live state without check-command)
# ---------------------------------------------------------------------------
set +e
out5=$(printf 'fleet-heartbeat.service Active: active (running).' | \
  "$capture" --topic 'test-dirty' --class drill-status 2>&1)
rc5=$?
set -e
[[ "$rc5" -eq 2 ]] || fail "lint-dirty note must exit 2, got $rc5: $out5"
dirty_count=$(find "$VAULT/00 Inbox/agent-drop/terminal-agent" -name '*-test-dirty.md' -print -quit 2>/dev/null | wc -l)
[[ "$dirty_count" -eq 0 ]] || fail "lint-dirty note should not be on disk"
printf '%s\n' "$out5" | grep -q 'missing check-command' || fail "lint output must name missing check-command: $out5"
ok "5: lint-dirty note refused and not written"

# ---------------------------------------------------------------------------
# Audit log and ratio
# ---------------------------------------------------------------------------
log="$VAULT/_system/logs/vault-capture.log"
[[ -f "$log" ]] || fail "capture audit log missing"
log_lines=$(wc -l <"$log")
[[ "$log_lines" -eq 3 ]] || fail "expected 3 audit log lines, got $log_lines"
ok "6: audit log has 3 wrapper-captured lines"

grep -q 'drop' "$log" || fail "audit log missing drop entry"
grep -q 'direct' "$log" || fail "audit log missing direct entry"
ok "7: audit log has drop and direct modes"

ratio_out=$("$ratio") || fail "ratio command failed: $ratio_out"
printf '%s\n' "$ratio_out" | grep -q 'ratio=' || fail "ratio output missing ratio: $ratio_out"
# 2 drops + 1 direct = 0.667
printf '%s\n' "$ratio_out" | grep -q 'drops=2' || fail "ratio drops wrong: $ratio_out"
printf '%s\n' "$ratio_out" | grep -q 'direct=1' || fail "ratio direct wrong: $ratio_out"
printf '%s\n' "$ratio_out" | grep -q 'total=3' || fail "ratio total wrong: $ratio_out"
ok "8: drop ratio is 2/3"

# ---------------------------------------------------------------------------
# Alert mode: with 2/3 the ratio is above 50%, so --alert should pass.
# ---------------------------------------------------------------------------
ratio_alert=$("$ratio" --alert) || fail "ratio --alert should pass at 0.667: $ratio_alert"
ok "9: ratio --alert passes above 50%"

# Force a low ratio: 1 drop + 4 direct in a fresh vault.
VAULT2="$scratch/vault2"
mkdir -p "$VAULT2/00 Inbox/agent-drop/terminal-agent"
mkdir -p "$VAULT2/_system/logs"
export FLEET_VAULT="$VAULT2"
for i in 1 2 3 4; do
  printf 'direct note %s' "$i" | "$capture" --topic "direct-$i" --direct "03 Knowledge/drafts/direct-$i.md"
done
printf 'drop note' | "$capture" --topic 'one-drop'

set +e
alert_out=$("$ratio" --alert 2>&1)
alert_rc=$?
set -e
[[ "$alert_rc" -eq 1 ]] || fail "ratio --alert must fail at 1/5, got $alert_rc"
printf '%s\n' "$alert_out" | grep -qi 'ALERT' || fail "alert output must contain ALERT: $alert_out"
ok "10: ratio --alert trips below 50%"

echo "OK: vault-capture.test.sh: 5 fixtures + audit log + ratio"
