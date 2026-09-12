#!/usr/bin/env bash
# tests/fleet-escalation-drain.test.sh
#
# fleet-ops#2677 + #2773: NISH-ESCALATIONS.md and alert-repair packets
# accumulate indefinitely; the drain keeps the live files bounded by
# archiving RESOLVED / REVOKED / non-class noise out of NISH and deleting
# consumed alert-repair packets. Proves the drain is idempotent, safe,
# and bounds the live file to FLEET_ESCALATION_DRAIN_MAX_LINES (50 by
# default).
#
# All scenarios run against a scratch agent-state dir; the LIVE state is
# never mutated by this test. Three planes are exercised:
#
#   1. NISH-ESCALATIONS.md (no-op boundary case): already-bounded file.
#      Re-running is a no-op (idempotency).
#   2. NISH-ESCALATIONS.md (canonical drain case): the live-file shape
#      before this fix (370-line pre-class-gate history + delivered
#      boundary entries) drains to MAX_LINES entries, archives the rest,
#      preserves ACTIVE- boundary entries (entries NOT in the seen set).
#   3. alert-repair packet drain: packet-*.md files whose dispatch cycle
#      TERMINATED in chains.terminated.jsonl (a terminal record for the
#      alertname with end_ts >= the packet's dispatch instant) are deleted.
#      Intermediate dispatches absorbed by a later terminal are deleted;
#      packets dispatched AFTER the latest terminal (in-flight re-fire) and
#      packets for alertnames with NO terminal record (stuck chain) are
#      preserved. Skip-list (canary/guard scaffolding without
#      `<alert>-<ts>.md` suffix) is preserved as well.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-escalation-drain"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "drain not executable: $bin"

scratch="$(mktemp -d -t esc-drain.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/agent-state"
mkdir -p "$AS/alert-repair" "$AS/lanes"

# Build a seen-keys fixture: 3 delivered entries (MONEY, LEGAL,
# CREDENTIAL) and 1 active (CREDENTIAL-BOUNDARY remains ACTIVE because
# its hash is NOT in the seen set).
build_seen() {
    local delivered="$1"
    : > "$AS/lanes/nish-boundary-notify.seen"
    printf '%s\n' "$delivered" >> "$AS/lanes/nish-boundary-notify.seen"
}

# Compute the seen-key (first 32 hex of sha256) for a given line.
key_of() {
    printf '%s' "$1" | sha256sum | cut -c1-32
}

# ---------------------------------------------------------------------------
# Scenario 1: NISH-ESCALATIONS.md no-op case - already bounded file.
# Re-running must produce a no-op summary and zero archive writes.
# ---------------------------------------------------------------------------
{
    printf '# Nish escalations - out-of-band surface (auditor failure channel)\n'
    printf '\n'
    printf 'One line per escalation, append-only.\n'
    printf 'Two lines of header text.\n'
    printf 'Three lines of header text.\n'
    printf '\n'
    printf 'Format: `<UTC ISO8601> <REASON> hash=<sha256> [detail...]`\n'
    printf '2026-08-26T16:57Z CREDENTIAL-BOUNDARY hash=active-1 count=1\n'
    printf '  body: not delivered yet.\n'
} > "$AS/NISH-ESCALATIONS.md"

run_drain() {
    FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
    FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
    FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
    FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
    FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
        bash "$bin" 2>"$scratch/run.stderr"
}

# No seen file = no delivered entries; drain must be a no-op.
rm -f "$AS/lanes/nish-boundary-notify.seen"
run_drain
grep -q "nothing to archive" "$scratch/run.stderr" \
    || fail "scenario 1: already-bounded file must drain as a no-op; stderr: $(cat "$scratch/run.stderr")"
ok "scenario 1: bounded NISH-ESCALATIONS.md drains as a no-op"

# ---------------------------------------------------------------------------
# Scenario 2: canonical pre-fix file shape (370-line pre-class-gate
# history). The drain must archive RESOLVED, REVOKED-BY-PROBE, and
# non-class entries; deliver delivered boundary entries (in seen set)
# only when the file is still over MAX_LINES AFTER the unconditional
# archive; preserve ACTIVE boundary entries (NOT in seen set).
# ---------------------------------------------------------------------------
active_line='2026-08-26T16:57Z CREDENTIAL-BOUNDARY hash=auto-revert-active count=1'
delivered_legal='2026-08-27T18:42:20Z LEGAL-BOUNDARY hash=legal-active count=1'
delivered_money='2026-08-25T23:02:12Z MONEY-BOUNDARY hash=money-active count=1'

{
    # Header (7 lines, including blank separator + Format line)
    printf '# Header line 1\n'
    printf '\n'
    printf 'Header line 3\n'
    printf 'Header line 4\n'
    printf 'Header line 5\n'
    printf 'Header line 6\n'
    printf '\n'
    printf 'Format: `<UTC ISO8601> <REASON> hash=<sha256> [detail...]`\n'

    # RESOLVED line - always archived
    printf '2026-08-26T05:35:00Z RESOLVED hash=resolved-marker - FALSE PAGE.\n'
    # REVOKED line - always archived
    printf '2026-08-26T05:40:00Z REVOKED-BY-PROBE revoking previous page\n'
    # Non-class noise - always archived
    printf '2026-08-25T17:45:58Z SEAT-UNHEALTHY hash=seatnoise class=rate_limited\n'
    printf '2026-08-25T17:46:00Z LADDER-WALLED hash=ladder reason=unit-failure\n'
    # Fill to push kept_lines over MAX_LINES (50) AFTER the unconditional
    # archive: deliver 40 MONEY-BOUNDARY entries (each with a continuation).
    # After first pass the kept_lines will be ~47 entries + 7-line header =
    # 54 lines, which trips the second-pass MAX_LINES check.
    for i in $(seq 1 40); do
        printf '2026-08-28T05:%02d:00Z MONEY-BOUNDARY hash=m%d delivered=true\n' "$((i % 60))" "$i"
        printf '  SUMMARY: prepaid fill %d.\n' "$i"
    done
    # Class-gated delivered boundary - only archived if over MAX_LINES
    printf '%s\n' "$delivered_legal"
    printf '  SUMMARY: legal sweep.\n'
    printf '%s\n' "$delivered_money"
    printf '  SUMMARY: prepaid seats.\n'
    # ACTIVE boundary - must be preserved (NOT in seen set)
    printf '%s\n' "$active_line"
    printf '  body: needs Nish.\n'
} > "$AS/NISH-ESCALATIONS.md"

# Mark the delivered entries as seen. The 40 fill entries are also seen
# (so they get promoted when the second pass kicks in).
build_seen_keys=()
build_seen_keys+=("$(key_of "$delivered_legal")")
build_seen_keys+=("$(key_of "$delivered_money")")
for i in $(seq 1 40); do
    line="2026-08-28T05:$((i % 60)):00Z MONEY-BOUNDARY hash=m${i} delivered=true"
    build_seen_keys+=("$(key_of "$line")")
done
printf '%s\n' "${build_seen_keys[@]}" > "$AS/lanes/nish-boundary-notify.seen"

run_drain

# Live file must contain the header + the ACTIVE entry only.
grep -qF "$active_line" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 2: ACTIVE entry must be preserved in live file"
grep -qF "  body: needs Nish." "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 2: ACTIVE entry's continuation must be preserved"
grep -qF "$delivered_legal" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 2: delivered LEGAL entry must be archived" || true
grep -qF "$delivered_money" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 2: delivered MONEY entry must be archived" || true
grep -qF "RESOLVED hash=resolved-marker" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 2: RESOLVED marker must be archived" || true
grep -qF "REVOKED-BY-PROBE" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 2: REVOKED-BY-PROBE marker must be archived" || true
grep -qF "SEAT-UNHEALTHY" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 2: non-class noise must be archived" || true
ok "scenario 2: delivered + RESOLVED + REVOKED + non-class archived; ACTIVE preserved"

# Archive file must contain all moved lines.
day="$(date -u +%Y-%m-%d)"
archive="$AS/nish-escalations-archive/$day.md"
[[ -f "$archive" ]] || fail "scenario 2: archive file not created at $archive"
grep -qF "$delivered_legal" "$archive" \
    || fail "scenario 2: delivered LEGAL must be in archive"
grep -qF "$delivered_money" "$archive" \
    || fail "scenario 2: delivered MONEY must be in archive"
grep -qF "RESOLVED hash=resolved-marker" "$archive" \
    || fail "scenario 2: RESOLVED must be in archive"
grep -qF "REVOKED-BY-PROBE" "$archive" \
    || fail "scenario 2: REVOKED-BY-PROBE must be in archive"
grep -qF "SEAT-UNHEALTHY" "$archive" \
    || fail "scenario 2: SEAT-UNHEALTHY must be in archive"
grep -qF "$active_line" "$archive" \
    && fail "scenario 2: ACTIVE must NOT be in archive" || true
ok "scenario 2: archive contains RESOLVED + REVOKED + non-class + delivered; ACTIVE NOT archived"

# Idempotency: re-running on the now-bounded file is a no-op.
rm -f "$scratch/run.stderr"
run_drain
grep -q "nothing to archive" "$scratch/run.stderr" \
    || fail "scenario 2: re-run on bounded file must be a no-op; stderr: $(cat "$scratch/run.stderr")"
ok "scenario 2: re-run on bounded file is a no-op (idempotency)"

# ---------------------------------------------------------------------------
# Scenario 3: alert-repair packet drain - packets whose dispatch cycle
# TERMINATED in chains.terminated.jsonl are deleted; intermediate
# dispatches absorbed by a later terminal are deleted; packets dispatched
# AFTER the latest terminal (in-flight re-fire) and packets for alertnames
# with NO terminal record (stuck chain) are preserved; canary/guard
# scaffolding (no timestamp suffix) is preserved.
# ---------------------------------------------------------------------------
rm -rf "$AS/alert-repair"
mkdir -p "$AS/alert-repair"

# Ledger fixture (chains.terminated.jsonl - the alert-repair
# termination ledger mirrored under alert-repair/):
#   FleetA  terminated green  end=09-01T18:00Z  -> packet at 06:00Z consumed
#   FleetB  terminated esc     end=09-01T12:00Z  -> packet at 10:00Z consumed
#                                                -> packet at 13:00Z NOT (re-fire)
#   FleetC  NO terminal record                   -> packets NOT consumed
#   NonSense record with an EMPTY end_ts        -> ignored by the parser
{
    cat <<'JSON'
{"alertname": "FleetA", "end_ts": "2026-09-01T18:00:00Z", "start_ts": "2026-09-01T06:00:00Z", "terminal": "green", "unit": "alert-repair-FleetA-20260901T060000Z"}
{"alertname": "FleetB", "end_ts": "2026-09-01T12:00:00Z", "start_ts": "2026-09-01T08:00:00Z", "terminal": "escalated", "unit": "alert-repair-FleetB-20260901T100000Z"}
{"alertname": "NonSense", "end_ts": "", "start_ts": "2026-09-01T07:00:00Z", "terminal": "green", "unit": ""}
JSON
} > "$AS/alert-repair/chains.terminated.jsonl"

# Webhook packet files:
touch "$AS/alert-repair/packet-FleetA-20260901T060000Z.md"   # consumed, terminated after -> DELETE
# Intermediate dispatch absorbed by FleetB's 12:00Z terminal:
touch "$AS/alert-repair/packet-FleetB-20260901T100000Z.md"   # consumed, end_ts >= ts -> DELETE
touch "$AS/alert-repair/packet-FleetB-20260901T130000Z.md"   # re-fired AFTER terminal -> KEEP (in-flight)
touch "$AS/alert-repair/packet-FleetC-20260901T050000Z.md"   # no ledger record -> KEEP (stuck chain)
touch "$AS/alert-repair/packet-FleetStuck-20260820T000000Z.md" # old, no ledger -> KEEP + LOUD STUCK-PACKET
# Canary/guard scaffolding - no `<alert>-<ts>.md` suffix:
touch "$AS/alert-repair/packet-11-canary-scaffold.md"
touch "$AS/alert-repair/packet-13-undersaturation-guard.md"
touch "$AS/alert-repair/packet-red-main-2.md"

run_drain

# Assertions:
[[ ! -f "$AS/alert-repair/packet-FleetA-20260901T060000Z.md" ]] \
    || fail "scenario 3: FleetA (terminated after dispatch) must be DELETED"
[[ ! -f "$AS/alert-repair/packet-FleetB-20260901T100000Z.md" ]] \
    || fail "scenario 3: FleetB 10:00Z (intermediate dispatch under 12:00Z terminal) must be DELETED"
[[ -f "$AS/alert-repair/packet-FleetB-20260901T130000Z.md" ]] \
    || fail "scenario 3: FleetB 13:00Z (dispatched AFTER terminal) must be KEPT (in-flight)"
[[ -f "$AS/alert-repair/packet-FleetC-20260901T050000Z.md" ]] \
    || fail "scenario 3: FleetC (no ledger terminal) must be KEPT (stuck chain)"
[[ -f "$AS/alert-repair/packet-FleetStuck-20260820T000000Z.md" ]] \
    || fail "scenario 3: FleetStuck (old, no terminal) must be KEPT (never silently deleted)"
grep -q "STUCK-PACKET.*packet-FleetStuck-20260820T000000Z.md" "$scratch/run.stderr" \
    || fail "scenario 3: drain must flag old no-terminal packets LOUD; stderr: $(cat "$scratch/run.stderr")"
[[ -f "$AS/alert-repair/packet-11-canary-scaffold.md" ]] \
    || fail "scenario 3: canary scaffolding (packet-11-) must be KEPT (no ts suffix)"
[[ -f "$AS/alert-repair/packet-13-undersaturation-guard.md" ]] \
    || fail "scenario 3: guard scaffolding (packet-13-) must be KEPT (no ts suffix)"
[[ -f "$AS/alert-repair/packet-red-main-2.md" ]] \
    || fail "scenario 3: legacy scaffolding (packet-red-main-2) must be KEPT (no ts suffix)"
grep -q "deleted packet-FleetA-20260901T060000Z.md" "$scratch/run.stderr" \
    || fail "scenario 3: drain log must name the FleetA deletion; stderr: $(cat "$scratch/run.stderr")"
ok "scenario 3: terminated packets deleted; in-flight / no-terminal / scaffolding preserved"
# Idempotency: re-running is a no-op for the packet drain too.
rm -f "$scratch/run.stderr"
run_drain
grep -q "packet_deleted=0" "$scratch/run.stderr" \
    || fail "scenario 3: re-run must delete nothing (idempotent); stderr: $(cat "$scratch/run.stderr")"
ok "scenario 3: re-run on drained packet dir is a no-op (idempotency)"

# ---------------------------------------------------------------------------
# Scenario 4: bounded file under MAX_LINES - drain does NOT promote
# delivered boundary entries (they stay until the file is over MAX_LINES).
# ---------------------------------------------------------------------------
{
    printf '# Header line 1\n'
    printf '\n'
    printf 'Header line 3\n'
    printf 'Header line 4\n'
    printf 'Header line 5\n'
    printf 'Header line 6\n'
    printf '\n'
    printf 'Format: `<UTC ISO8601> <REASON> hash=<sha256> [detail...]`\n'
    printf '2026-08-26T05:00:00Z RESOLVED hash=resolved-no-promote\n'
    # 10 delivered boundary entries, all in seen set. File stays small.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        printf '2026-08-26T05:%02d:00Z MONEY-BOUNDARY hash=m%d delivered=true\n' "$i" "$i"
    done
} > "$AS/NISH-ESCALATIONS.md"

delivered_keys=()
for i in 1 2 3 4 5 6 7 8 9 10; do
    line="2026-08-26T05:0${i}:00Z MONEY-BOUNDARY hash=m${i} delivered=true"
    delivered_keys+=("$(key_of "$line")")
done
printf '%s\n' "${delivered_keys[@]}" > "$AS/lanes/nish-boundary-notify.seen"

run_drain

# The RESOLVED line is archived unconditionally. The delivered MONEY-BOUNDARY
# entries are NOT archived (file is small after RESOLVED removal).
grep -qF "RESOLVED hash=resolved-no-promote" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 4: RESOLVED must be archived even on a small file" || true
grep -qF "MONEY-BOUNDARY hash=m1 delivered=true" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 4: delivered boundary on small file must be KEPT (not over MAX_LINES)"
ok "scenario 4: small file does NOT promote delivered boundary entries (size check)"

# ---------------------------------------------------------------------------
# Scenario 5: STUCK_AGE_S threshold (fleet-ops#2677 follow-up). A
# webhook packet older than the threshold with no terminal record is
# flagged LOUD. The default threshold is 6h (21600s); a 7h-old packet
# must trip the LOUD line, a 1h-old packet must not. Threshold is
# configurable via FLEET_ESCALATION_DRAIN_STUCK_AGE_S so a tighter SRE
# can raise it without editing the drain.
# ---------------------------------------------------------------------------
rm -rf "$AS/alert-repair"
mkdir -p "$AS/alert-repair"
# Empty ledger (no terminal records - every packet is "no terminal").
: > "$AS/alert-repair/chains.terminated.jsonl"

# Compute packet filenames whose embedded webhook timestamps bracket the
# 6h threshold from now. The drain ages a packet by its filename ISO,
# NOT by mtime (the file may have been re-touched by hand without
# changing the dispatch instant). The packet name IS the contract.
ts_7h_ago="$(date -u -d '7 hours ago' +%Y%m%dT%H%M%SZ)"
ts_1h_ago="$(date -u -d '1 hour ago' +%Y%m%dT%H%M%SZ)"

# 7h-old packet (filename ts = now-7h): MUST be flagged LOUD.
touch "$AS/alert-repair/packet-FleetStaleA-${ts_7h_ago}.md"
# 1h-old packet (filename ts = now-1h): must NOT be flagged LOUD.
touch "$AS/alert-repair/packet-FleetStaleB-${ts_1h_ago}.md"
# Canary scaffolding (no ts suffix): must be preserved and never LOUD.
touch "$AS/alert-repair/packet-11-canary-scaffold.md"

run_drain

# Both packets must be preserved (never silently deleted).
[[ -f "$AS/alert-repair/packet-FleetStaleA-${ts_7h_ago}.md" ]] \
    || fail "scenario 5: 7h-old packet (no terminal) must be KEPT, never silently deleted"
[[ -f "$AS/alert-repair/packet-FleetStaleB-${ts_1h_ago}.md" ]] \
    || fail "scenario 5: 1h-old packet (no terminal) must be KEPT, never silently deleted"
[[ -f "$AS/alert-repair/packet-11-canary-scaffold.md" ]] \
    || fail "scenario 5: canary scaffolding must be KEPT (no ts suffix)"

# 7h-old packet must be flagged LOUD.
grep -q "STUCK-PACKET.*packet-FleetStaleA-${ts_7h_ago}.md" "$scratch/run.stderr" \
    || fail "scenario 5: 7h-old no-terminal packet MUST trip LOUD STUCK-PACKET; stderr: $(cat "$scratch/run.stderr")"
# 1h-old packet must NOT be in the LOUD line (the LOUD line only names
# packets older than the threshold).
if grep -q "STUCK-PACKET.*packet-FleetStaleB-${ts_1h_ago}.md" "$scratch/run.stderr"; then
    fail "scenario 5: 1h-old packet must NOT trip LOUD STUCK-PACKET; stderr: $(cat "$scratch/run.stderr")"
fi
# Canary scaffolding must never appear in the LOUD line.
if grep -q "STUCK-PACKET.*packet-11-canary-scaffold.md" "$scratch/run.stderr"; then
    fail "scenario 5: canary scaffolding must NEVER appear in LOUD line; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 5: 6h threshold - 7h packet LOUD, 1h packet silent, scaffolding ignored"

# Override the threshold: with STUCK_AGE_S=2h (7200s), a 3h-old packet
# must now LOUD (it was silent under the 6h default), and the line must
# echo the override value. The 1h-old packet stays silent either way.
ts_3h_ago="$(date -u -d '3 hours ago' +%Y%m%dT%H%M%SZ)"
rm -f "$scratch/run.stderr"
touch "$AS/alert-repair/packet-FleetStaleC-${ts_3h_ago}.md"
FLEET_ESCALATION_DRAIN_STUCK_AGE_S=7200 \
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run.stderr"
grep -q "STUCK-PACKET.*packet-FleetStaleC-${ts_3h_ago}.md" "$scratch/run.stderr" \
    || fail "scenario 5: override STUCK_AGE_S=2h must flag 3h-old packet LOUD; stderr: $(cat "$scratch/run.stderr")"
# The override should be reflected in the LOUD line.
grep -q "older than 7200s" "$scratch/run.stderr" \
    || fail "scenario 5: override STUCK_AGE_S must echo the new threshold in the LOUD line; stderr: $(cat "$scratch/run.stderr")"
# The 1h-old packet must STILL be silent under the tighter override
# (1h < 2h threshold) - proves the threshold is the only signal.
if grep -q "STUCK-PACKET.*packet-FleetStaleB-${ts_1h_ago}.md" "$scratch/run.stderr"; then
    fail "scenario 5: 1h-old packet must STAY silent under STUCK_AGE_S=2h; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 5: FLEET_ESCALATION_DRAIN_STUCK_AGE_S override is honored"

# ---------------------------------------------------------------------------
# Scenario 6: bad arg path (usage error).
# ---------------------------------------------------------------------------
set +e
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" bash "$bin" --bogus-arg 2>"$scratch/bad.err" >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "scenario 6: usage error must exit 2, got rc=$rc"
ok "scenario 6: --bogus-arg exits 2 with usage message"

# ---------------------------------------------------------------------------
# Scenario 7: condition-resolution pass (fleet-ops#3996). A money-wall prose
# section whose provider is now healthy is archived; a money-wall section
# whose provider is still 402 is kept and counted live; a non-money prose
# section (credential / legal) is kept untouched.
#
# Seat fixtures:
#   openrouter  -> http_status 200, health_class healthy  (wall GONE)
#   bai         -> http_status 402, health_class quota_exhausted (wall LIVE)
# ---------------------------------------------------------------------------
mkdir -p "$AS/lanes/seats"
cat >"$AS/lanes/seats/openrouter__deepseek-v4-flash.json" <<'JSON'
{"provider":"openrouter","model":"deepseek-v4-flash","http_status":200,"health_class":"healthy"}
JSON
cat >"$AS/lanes/seats/bai__deepseek-v4-flash.json" <<'JSON'
{"provider":"bai","model":"deepseek-v4-flash","http_status":402,"health_class":"quota_exhausted"}
JSON

# NISH fixture: header + 3 prose sections + 1 formal MONEY-BOUNDARY entry.
#   - openrouter section: wall GONE -> archived by condition-drain
#   - bai section: wall LIVE -> kept, counted live
#   - credential section: not a money wall -> kept untouched
#   - formal MONEY-BOUNDARY openrouter: wall GONE -> archived
{
    printf '# Nish escalations\n'
    printf '\n'
    printf 'One line per escalation.\n'
    printf 'Three lines of header.\n'
    printf 'Four lines of header.\n'
    printf '\n'
    printf 'Format: entry line.\n'
    # Prose: openrouter money wall (condition RESOLVED)
    printf '## 2026-09-06 - OpenRouter credits exhausted (402 across all openrouter-routed units)\n'
    printf '%s\n' '- OpenRouter is out of credits. 402 quota_exhausted on every seat.'
    printf '%s\n' '- NISH ACTION: add credits at openrouter.ai/settings/credits.'
    # Prose: bai money wall (condition LIVE)
    printf '## 2026-09-04 - bai credits exhausted (402 quota_exhausted)\n'
    printf '%s\n' '- bai account balance is 0. 402 on every bai seat.'
    printf '%s\n' '- NISH ACTION: top up bai.'
    # Prose: credential boundary (NOT a money wall)
    printf '## 2026-09-06 - AUTO-REVERT workflow bug: needs Workflows-scope token\n'
    printf '%s\n' '- The nishfleet-worker App token does not have Workflows scope.'
    printf '%s\n' '- NISH ACTION: push the one-line fix with a human gh session.'
    # Formal: MONEY-BOUNDARY openrouter (condition RESOLVED)
    printf '2026-09-06T14:35Z MONEY-BOUNDARY hash=openrouter-402 reason=ladder-walled:402:openrouter quota_exhausted\n'
    printf '  SUMMARY: openrouter credits exhausted, 402 across all seats.\n'
} > "$AS/NISH-ESCALATIONS.md"

# No seen file needed for the condition pass (it does not use the seen set).
rm -f "$AS/lanes/nish-boundary-notify.seen"

FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run7.stderr"

# The openrouter prose section must be ARCHIVED (condition resolved).
grep -qF "OpenRouter credits exhausted" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 7: resolved openrouter prose section must be archived" || true
# The bai prose section must be KEPT (condition still live).
grep -qF "bai credits exhausted" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 7: live bai prose section must be kept"
# The credential section must be KEPT (not a money wall).
grep -qF "AUTO-REVERT workflow bug" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 7: non-money credential section must be kept"
# The formal MONEY-BOUNDARY openrouter entry must be ARCHIVED (condition resolved).
grep -qF "hash=openrouter-402" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 7: resolved formal MONEY-BOUNDARY entry must be archived" || true
# The summary must report the split.
grep -q "nish_condition_resolved=2" "$scratch/run7.stderr" \
    || fail "scenario 7: summary must report 2 resolved; stderr: $(cat "$scratch/run7.stderr")"
grep -q "nish_condition_live=1" "$scratch/run7.stderr" \
    || fail "scenario 7: summary must report 1 live; stderr: $(cat "$scratch/run7.stderr")"
# The archive must contain the resolved entries.
day="$(date -u +%Y-%m-%d)"
archive="$AS/nish-escalations-archive/$day.md"
grep -qF "OpenRouter credits exhausted" "$archive" \
    || fail "scenario 7: archive must contain resolved openrouter section"
grep -qF "hash=openrouter-402" "$archive" \
    || fail "scenario 7: archive must contain resolved formal entry"
# The archive must NOT contain the live bai section.
grep -qF "bai credits exhausted" "$archive" \
    && fail "scenario 7: archive must NOT contain live bai section" || true
ok "scenario 7: resolved money-wall entries archived; live + non-money kept; split reported"

# Idempotency: re-running on the drained file is a no-op for the condition pass.
rm -f "$scratch/run7b.stderr"
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run7b.stderr"
grep -q "nish_condition_resolved=0" "$scratch/run7b.stderr" \
    || fail "scenario 7: re-run must report 0 resolved (idempotent); stderr: $(cat "$scratch/run7b.stderr")"
ok "scenario 7: re-run is idempotent (0 resolved on second pass)"

# ---------------------------------------------------------------------------
# Scenario 8: condition-drain disabled via FLEET_ESCALATION_DRAIN_CONDITION_DRAIN=0.
# The money-wall entries stay even when the provider is healthy.
# ---------------------------------------------------------------------------
{
    printf '# Nish escalations\n'
    printf '\n'
    printf 'One line per escalation.\n'
    printf 'Three lines of header.\n'
    printf 'Four lines of header.\n'
    printf '\n'
    printf 'Format: entry line.\n'
    printf '## 2026-09-06 - OpenRouter credits exhausted (402 across all openrouter-routed units)\n'
    printf '%s\n' '- OpenRouter is out of credits. 402 quota_exhausted on every seat.'
} > "$AS/NISH-ESCALATIONS.md"

FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_CONDITION_DRAIN=0 \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run8.stderr"

grep -qF "OpenRouter credits exhausted" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 8: condition-drain disabled must keep money-wall entry"
grep -q "nish_condition_resolved=0" "$scratch/run8.stderr" \
    || fail "scenario 8: condition-drain disabled must report 0 resolved"
ok "scenario 8: CONDITION_DRAIN=0 skips the condition pass"

# ---------------------------------------------------------------------------
# Scenario 9: no seat dir -> condition-drain treats all providers as
# not-walled. A money-wall entry is archived (no proof of a live wall).
# This is the conservative default: absent seat files = no wall evidence.
# ---------------------------------------------------------------------------
rm -rf "$AS/lanes/seats"
{
    printf '# Nish escalations\n'
    printf '\n'
    printf 'One line per escalation.\n'
    printf 'Three lines of header.\n'
    printf 'Four lines of header.\n'
    printf '\n'
    printf 'Format: entry line.\n'
    printf '## 2026-09-06 - OpenRouter credits exhausted (402 across all openrouter-routed units)\n'
    printf '%s\n' '- OpenRouter is out of credits. 402 quota_exhausted on every seat.'
} > "$AS/NISH-ESCALATIONS.md"

FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run9.stderr"

grep -qF "OpenRouter credits exhausted" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 9: no seat dir -> resolved entry must be archived" || true
grep -q "nish_condition_resolved=1" "$scratch/run9.stderr" \
    || fail "scenario 9: no seat dir -> must report 1 resolved; stderr: $(cat "$scratch/run9.stderr")"
ok "scenario 9: no seat dir -> absent providers treated as not-walled (entry archived)"

# ---------------------------------------------------------------------------
# Scenario 10: body-level RESOLVED marker drain (fleet-ops#3996). A formal
# class-gated entry (CREDENTIAL-BOUNDARY) whose continuation lines carry
# `  RESOLVED 2026-...Z:` is archived by drain_nish even though the header
# class is NOT literally RESOLVED. A prose section with `- **RESOLVED by
# orchestrator ...**` is archived by drain_nish_conditions. A live entry
# (no RESOLVED marker, no resolved condition) is kept.
#
# This is the gap PR #4099 left: entries that record their own resolution in
# the body, not the header, were never aged out — the live file grew
# monotonically. This scenario proves the body-RESOLVED pass closes it.
# ---------------------------------------------------------------------------
rm -rf "$AS/lanes/seats"
mkdir -p "$AS/lanes/seats"
# No seat files -> no provider walls (conservative default).
{
    printf '# Nish escalations\n'
    printf '\n'
    printf 'One line per escalation.\n'
    printf 'Three lines of header.\n'
    printf 'Four lines of header.\n'
    printf '\n'
    printf 'Format: entry line.\n'
    # Formal CREDENTIAL-BOUNDARY with body RESOLVED marker (archived by drain_nish)
    printf '2026-08-26T16:57Z CREDENTIAL-BOUNDARY hash=auto-revert-pat count=1\n'
    printf '  SUMMARY: fleet-ops auto-revert workflow fails on every main push.\n'
    printf '  NISH DECISION NEEDED: regenerate the AUTO_REVERT PAT.\n'
    printf '  RESOLVED 2026-08-27T06:07Z: fixed via the nishfleet-worker GitHub App.\n'
    # Prose section with body RESOLVED marker (archived by drain_nish_conditions)
    printf '## 2026-09-05 - 0509 AUTO-REVERT HALT #1687: main red on Gate-B E2E\n'
    printf '%s\n' '- State: main is in a sustained red chain.'
    printf '%s\n' '- **RESOLVED by orchestrator (fable-fleet-check):** the revert-order question is not Nish'"'"'s.'
    # Live entry: no RESOLVED marker, no money-wall condition (kept)
    printf '## 2026-09-07 - ORACLE ALWAYS FREE: signup needs Nish card\n'
    printf '%s\n' '- NISH ACTION: sign up at cloud.oracle.com/free.'
} > "$AS/NISH-ESCALATIONS.md"

rm -f "$AS/lanes/nish-boundary-notify.seen"

FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run10.stderr"

# The formal CREDENTIAL-BOUNDARY with body RESOLVED must be ARCHIVED.
grep -qF "auto-revert-pat" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 10: formal entry with body RESOLVED must be archived" || true
# The prose section with body RESOLVED must be ARCHIVED.
grep -qF "AUTO-REVERT HALT #1687" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 10: prose section with body RESOLVED must be archived" || true
# The live entry (no RESOLVED) must be KEPT.
grep -qF "ORACLE ALWAYS FREE" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 10: live entry without RESOLVED must be kept"
# The summary must report the body-resolved split.
grep -q "nish_body_resolved=2" "$scratch/run10.stderr" \
    || fail "scenario 10: summary must report 2 body_resolved; stderr: $(cat "$scratch/run10.stderr")"
# The archive must contain the resolved entries.
day10="$(date -u +%Y-%m-%d)"
archive10="$AS/nish-escalations-archive/$day10.md"
grep -qF "auto-revert-pat" "$archive10" \
    || fail "scenario 10: archive must contain formal body-RESOLVED entry"
grep -qF "AUTO-REVERT HALT #1687" "$archive10" \
    || fail "scenario 10: archive must contain prose body-RESOLVED section"
ok "scenario 10: body-level RESOLVED entries archived; live entry kept; split reported"

# Idempotency: re-running on the drained file is a no-op.
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run10b.stderr"
grep -q "nish_body_resolved=0" "$scratch/run10b.stderr" \
    || fail "scenario 10: re-run must report 0 body_resolved (idempotent); stderr: $(cat "$scratch/run10b.stderr")"
ok "scenario 10: re-run is idempotent (0 body_resolved on second pass)"

# ---------------------------------------------------------------------------
# Scenario 11: retired-mechanism regression (fleet-ops#4418). The drain's
# STUCK-PACKET escalation reference must never point a stuck packet at a
# retired mechanism. The retired-mechanisms ledger (vault) is the source of
# truth. If the ledger is absent (hosted CI), skip this check rather than
# inventing a stale snapshot.
# ---------------------------------------------------------------------------
retired_ledger="/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/retired-mechanisms.md"
if [[ -f "$retired_ledger" ]]; then
    # Extract mechanism names: text before the first '(', split on '+' and ':'.
    # Also generate the fleet-prefix-stripped variant so a shortened
    # reference (e.g. "completion-canary" for "fleet-completion-canary")
    # is still caught.
    mech_variants="$(grep '^\- ' "$retired_ledger" \
        | sed 's/^\- //' | cut -d'(' -f1 \
        | tr '+:' '\n' \
        | sed 's/[[:space:]]*$//;s/^[[:space:]]*//' \
        | grep -v '^$' \
        | while IFS= read -r name; do
            printf '%s\n' "$name"
            [[ "$name" == fleet-* ]] && printf '%s\n' "${name#fleet-}"
            true
          done \
        | sort -u)"
    stuck_line="$(grep 'STUCK-PACKET' "$bin" || true)"
    [[ -n "$stuck_line" ]] \
        || fail "scenario 11: drain must have a STUCK-PACKET escalation line"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if echo "$stuck_line" | grep -qi "$name"; then
            fail "scenario 11: drain STUCK-PACKET line references retired mechanism '$name' (retired-mechanisms ledger)"
        fi
    done <<< "$mech_variants"
    ok "scenario 11: drain STUCK-PACKET line references no retired mechanism (ledger source of truth)"
else
    echo "SKIP: retired-mechanisms ledger absent (hosted CI) — skipping retired-mechanism regression"
fi

echo
echo "fleet-escalation-drain: all scenarios passed (fleet-ops#2677 + #2773 + #3996 + #4418)"

echo
# fleet-ops#5624 bound-breach second stage (breach stamp + LOUD alert +
# oldest-first digest): hosted subtest — workers cannot edit
# .github/workflows/**, so this keeps the P14 reachable-set gate green.
bash "$here/escalation-drain-bound.test.sh"