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
#   3. alert-repair packet drain: packet-*.md files with a complete
#      chain in actions.log (DISPATCH AND RESOLVED|FAILED) AND older
#      than PACKET_MIN_AGE_S are deleted. Skip-list (canary/guard
#      scaffolding without `<alert>-<ts>.md` suffix) is preserved.

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
    FLEET_ESCALATION_DRAIN_ACTIONS_LOG="$AS/alert-repair/actions.log" \
    FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    FLEET_ESCALATION_DRAIN_PACKET_MIN_AGE_S=60 \
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
# Scenario 3: alert-repair packet drain — packets with complete chain
# (DISPATCH AND RESOLVED|FAILED) AND older than PACKET_MIN_AGE_S are
# deleted; canary/guard scaffolding (no timestamp suffix) is preserved.
# ---------------------------------------------------------------------------
rm -rf "$AS/alert-repair"
mkdir -p "$AS/alert-repair"

now_epoch="$(date -u +%s)"
old_ts=$(date -u -d "@$((now_epoch - 7200))" +%Y%m%dT%H%M%SZ)  # 2h old (past 1h min age)
fresh_ts=$(date -u -d "@$((now_epoch - 30))" +%Y%m%dT%H%M%SZ)    # 30s old (under 1h min age)
old_dispatch_ts=$(date -u -d "@$((now_epoch - 7000))" +%Y-%m-%dT%H:%M:%SZ)
old_resolved_ts=$(date -u -d "@$((now_epoch - 6800))" +%Y-%m-%dT%H:%M:%SZ)
fresh_dispatch_ts=$(date -u -d "@$((now_epoch - 20))" +%Y-%m-%dT%H:%M:%SZ)

# Webhook packet files:
touch "$AS/alert-repair/packet-FleetA-$old_ts.md"          # consumed, old -> DELETE
touch "$AS/alert-repair/packet-FleetB-$old_ts.md"          # dispatched, NOT resolved -> KEEP (in-flight)
touch "$AS/alert-repair/packet-FleetC-$fresh_ts.md"        # consumed, fresh -> KEEP (under min age)
touch "$AS/alert-repair/packet-FleetD-$old_ts.md"          # not in actions.log -> KEEP (no chain)
# Canary/guard scaffolding — no `<alert>-<ts>.md` suffix:
touch "$AS/alert-repair/packet-11-completion-canary.md"
touch "$AS/alert-repair/packet-13-undersaturation-guard.md"
touch "$AS/alert-repair/packet-red-main-2.md"

{
    printf '[%s] DISPATCH alertname=FleetA seat=devin/glm-5-2 unit=alert-repair-FleetA-%s rc=0\n' "$old_dispatch_ts" "$old_ts"
    printf '[%s] RESOLVED alertname=FleetA root_cause=test\n' "$old_resolved_ts"
    printf '[%s] DISPATCH alertname=FleetB seat=devin/glm-5-2 unit=alert-repair-FleetB-%s rc=0\n' "$old_dispatch_ts" "$old_ts"
    # NO RESOLVED for FleetB -> chain incomplete -> packet kept.
    printf '[%s] DISPATCH alertname=FleetC seat=devin/glm-5-2 unit=alert-repair-FleetC-%s rc=0\n' "$fresh_dispatch_ts" "$fresh_ts"
    printf '[%s] RESOLVED alertname=FleetC root_cause=test\n' "$fresh_dispatch_ts"
    # FleetD: no DISPATCH at all -> packet kept (no chain proof).
} > "$AS/alert-repair/actions.log"

run_drain

# Assertions:
[[ ! -f "$AS/alert-repair/packet-FleetA-$old_ts.md" ]] \
    || fail "scenario 3: FleetA (complete chain, old) must be DELETED"
[[ -f "$AS/alert-repair/packet-FleetB-$old_ts.md" ]] \
    || fail "scenario 3: FleetB (no RESOLVED) must be KEPT (in-flight chain)"
[[ -f "$AS/alert-repair/packet-FleetC-$fresh_ts.md" ]] \
    || fail "scenario 3: FleetC (under PACKET_MIN_AGE_S) must be KEPT"
[[ -f "$AS/alert-repair/packet-FleetD-$old_ts.md" ]] \
    || fail "scenario 3: FleetD (no actions.log chain) must be KEPT"
[[ -f "$AS/alert-repair/packet-11-completion-canary.md" ]] \
    || fail "scenario 3: canary scaffolding (packet-11-) must be KEPT (no ts suffix)"
[[ -f "$AS/alert-repair/packet-13-undersaturation-guard.md" ]] \
    || fail "scenario 3: guard scaffolding (packet-13-) must be KEPT (no ts suffix)"
[[ -f "$AS/alert-repair/packet-red-main-2.md" ]] \
    || fail "scenario 3: legacy scaffolding (packet-red-main-2) must be KEPT (no ts suffix)"
ok "scenario 3: consumed+old packet deleted; in-flight/fresh/no-chain/scaffolding preserved"

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
# Scenario 5: bad arg path (usage error).
# ---------------------------------------------------------------------------
set +e
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" bash "$bin" --bogus-arg 2>"$scratch/bad.err" >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "scenario 5: usage error must exit 2, got rc=$rc"
ok "scenario 5: --bogus-arg exits 2 with usage message"

echo
echo "fleet-escalation-drain: all scenarios passed (fleet-ops#2677 + #2773)"