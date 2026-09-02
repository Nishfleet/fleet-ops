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
# Scenario 1: NISH-ESCALATIONS.md no-op case — already bounded file.
# Re-running must produce a no-op summary and zero archive writes.
# ---------------------------------------------------------------------------
{
    printf '# Nish escalations — out-of-band surface (auditor failure channel)\n'
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

    # RESOLVED line — always archived
    printf '2026-08-26T05:35:00Z RESOLVED hash=resolved-marker — FALSE PAGE.\n'
    # REVOKED line — always archived
    printf '2026-08-26T05:40:00Z REVOKED-BY-PROBE revoking previous page\n'
    # Non-class noise — always archived
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
    # Class-gated delivered boundary — only archived if over MAX_LINES
    printf '%s\n' "$delivered_legal"
    printf '  SUMMARY: legal sweep.\n'
    printf '%s\n' "$delivered_money"
    printf '  SUMMARY: prepaid seats.\n'
    # ACTIVE boundary — must be preserved (NOT in seen set)
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
# Scenario 3: alert-repair packet drain — packets whose dispatch cycle
# TERMINATED in chains.terminated.jsonl are deleted; intermediate
# dispatches absorbed by a later terminal are deleted; packets dispatched
# AFTER the latest terminal (in-flight re-fire) and packets for alertnames
# with NO terminal record (stuck chain) are preserved; canary/guard
# scaffolding (no timestamp suffix) is preserved.
# ---------------------------------------------------------------------------
rm -rf "$AS/alert-repair"
mkdir -p "$AS/alert-repair"

# Ledger fixture (chains.terminated.jsonl — the fleet-completion-canary
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
# Canary/guard scaffolding — no `<alert>-<ts>.md` suffix:
touch "$AS/alert-repair/packet-11-completion-canary.md"
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
[[ -f "$AS/alert-repair/packet-11-completion-canary.md" ]] \
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
# Scenario 4: bounded file under MAX_LINES — drain does NOT promote
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
# Empty ledger (no terminal records — every packet is "no terminal").
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
touch "$AS/alert-repair/packet-11-completion-canary.md"

run_drain

# Both packets must be preserved (never silently deleted).
[[ -f "$AS/alert-repair/packet-FleetStaleA-${ts_7h_ago}.md" ]] \
    || fail "scenario 5: 7h-old packet (no terminal) must be KEPT, never silently deleted"
[[ -f "$AS/alert-repair/packet-FleetStaleB-${ts_1h_ago}.md" ]] \
    || fail "scenario 5: 1h-old packet (no terminal) must be KEPT, never silently deleted"
[[ -f "$AS/alert-repair/packet-11-completion-canary.md" ]] \
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
if grep -q "STUCK-PACKET.*packet-11-completion-canary.md" "$scratch/run.stderr"; then
    fail "scenario 5: canary scaffolding must NEVER appear in LOUD line; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 5: 6h threshold — 7h packet LOUD, 1h packet silent, scaffolding ignored"

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
# (1h < 2h threshold) — proves the threshold is the only signal.
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

echo
echo "fleet-escalation-drain: all scenarios passed (fleet-ops#2677 + #2773)"