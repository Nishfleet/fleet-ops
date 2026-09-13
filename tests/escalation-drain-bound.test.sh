#!/usr/bin/env bash
# tests/escalation-drain-bound.test.sh
#
# fleet-ops#5624: the live escalation file sat at 114 lines vs MAX_LINES=50
# for days — the unconditional/condition drains had no path to the bound on
# all-prose content, and the over-bound state itself was escalated nowhere.
# The bound-breach second stage makes "over bound forever" a detected state
# (breach stamp + LOUD [BOUND-BREACH]) and gives it a converging path
# (oldest-first digest into digest-YYYY-MM-DD.md, every removal a logged
# disposition). Active (never-delivered) boundary entries are never digest
# candidates.
#
# All scenarios run against a scratch agent-state dir; the LIVE state is
# never mutated by this test.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-escalation-drain"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "drain not executable: $bin"

scratch="$(mktemp -d -t esc-bound.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/agent-state"
mkdir -p "$AS/alert-repair" "$AS/lanes"

key_of() { printf '%s' "$1" | sha256sum | cut -c1-32; }

# Write the breach stamp with a chosen epoch (tests control age directly).
stamp_at() {
    mkdir -p "$AS/lanes"
    printf '%s\n%s\n' "$1" "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)" \
        > "$AS/lanes/fleet-escalation-drain.over-bound"
}

run_drain() {
    FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
    FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
    FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
    FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
    FLEET_ESCALATION_DRAIN_ARCHIVE_DIR="$AS/nish-escalations-archive" \
    FLEET_ESCALATION_DRAIN_DIGEST_DIR="$AS/nish-escalations-archive" \
    FLEET_ESCALATION_DRAIN_OVER_BOUND_STAMP="$AS/lanes/fleet-escalation-drain.over-bound" \
    FLEET_ESCALATION_DRAIN_OVER_BOUND_AGE_S=86400 \
    FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
    FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
        bash "$bin" 2>"$scratch/run.stderr"
}

# Real-shape fixture: 6-line format header + documentation strays (the
# preamble the live file carries), then N `## ` prose sections of 5 lines
# each — the exact shape that had no drain path (zero formal entries).
build_prose_file() {
    local n_sections="$1"
    {
        printf '# Nish escalations — out-of-band surface (auditor failure channel)\n'
        printf '\n'
        printf 'One line per escalation, append-only.\n'
        printf 'Header line 4\n'
        printf 'Header line 5\n'
        printf '\n'
        printf 'Format: `<UTC ISO8601> <REASON> hash=<sha256> [detail...]`\n'
        printf '=== ENTRY-LINE FORMAT THE DELIVERER READS ===\n'
        printf '(documentation block kept as preamble strays)\n'
        local i
        for i in $(seq 1 "$n_sections"); do
            printf '## 2026-09-%02d — stale prose section %d needing Nish\n' "$i" "$i"
            printf '%s\n' "- **State.** body line for section $i."
            printf '%s\n' "- **More.** second body line for section $i."
            printf '%s\n' "- **NISH ACTION.** do the thing for section $i."
            printf '\n'
        done
    } > "$AS/NISH-ESCALATIONS.md"
}

# ---------------------------------------------------------------------------
# Scenario 1: fresh breach — over-bound file, no stamp. First observation
# writes the stamp and nothing else moves (the 24h grace lets the normal
# drains try first).
# ---------------------------------------------------------------------------
build_prose_file 10   # 9 preamble + 50 unit lines = 59 > 50
rm -f "$AS/lanes/fleet-escalation-drain.over-bound"
cp "$AS/NISH-ESCALATIONS.md" "$scratch/s1.before"

run_drain

[[ -f "$AS/lanes/fleet-escalation-drain.over-bound" ]] \
    || fail "scenario 1: first over-bound observation must write the breach stamp; stderr: $(cat "$scratch/run.stderr")"
grep -q "bound-breach clock started" "$scratch/run.stderr" \
    || fail "scenario 1: clock-start must be logged; stderr: $(cat "$scratch/run.stderr")"
cmp -s "$scratch/s1.before" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 1: file must be untouched on first observation (24h grace)"
if grep -q "BOUND-BREACH\|digested:" "$scratch/run.stderr"; then
    fail "scenario 1: no alert/digest may fire inside the 24h grace; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 1: fresh breach writes stamp, file untouched inside grace window"

# ---------------------------------------------------------------------------
# Scenario 2: sub-threshold breach — stamp 1h old. Still no digest; the
# run logs the waiting state with the since timestamp.
# ---------------------------------------------------------------------------
stamp_at "$(date -u -d '1 hour ago' +%s)"
run_drain
grep -q "no digest yet" "$scratch/run.stderr" \
    || fail "scenario 2: sub-threshold breach must log the waiting state; stderr: $(cat "$scratch/run.stderr")"
cmp -s "$scratch/s1.before" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 2: file must be untouched below the 24h threshold"
if grep -q "BOUND-BREACH" "$scratch/run.stderr"; then
    fail "scenario 2: LOUD must not fire below the threshold; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 2: 1h-old breach waits — no alert, no digest"

# ---------------------------------------------------------------------------
# Scenario 3: persistent breach — stamp 25h old. The bound-breach path
# fires: LOUD alert, oldest units digested with a logged disposition,
# live file converges to <= MAX_LINES, DRAIN-DIGEST pointer appended,
# stamp cleared.
# ---------------------------------------------------------------------------
stamp_at "$(date -u -d '25 hours ago' +%s)"
run_drain

lines_now=$(wc -l < "$AS/NISH-ESCALATIONS.md")
[[ "$lines_now" -le 50 ]] \
    || fail "scenario 3: live file must converge to <= 50 after digest, got $lines_now"
grep -q "LOUD \[BOUND-BREACH\]" "$scratch/run.stderr" \
    || fail "scenario 3: persistent breach must emit LOUD [BOUND-BREACH]; stderr: $(cat "$scratch/run.stderr")"
grep -q "digesting [0-9]* oldest live entries" "$scratch/run.stderr" \
    || fail "scenario 3: LOUD line must name the digest count; stderr: $(cat "$scratch/run.stderr")"

# Oldest sections moved out; newest stayed.
grep -qF "## 2026-09-01 — stale prose section 1" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 3: oldest section must be digested off the live file" || true
grep -qF "## 2026-09-10 — stale prose section 10" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 3: newest section must stay on the live file"

# Disposition: digested units preserved in the day digest, each named in
# the log — nothing silently dropped.
day="$(date -u +%Y-%m-%d)"
digest="$AS/nish-escalations-archive/digest-$day.md"
[[ -f "$digest" ]] || fail "scenario 3: digest file missing at $digest"
grep -qF "## 2026-09-01 — stale prose section 1" "$digest" \
    || fail "scenario 3: digested section must be preserved in the digest file"
grep -qF "do the thing for section 1" "$digest" \
    || fail "scenario 3: digested unit's continuation lines must move with it"
grep -q "digested: ## 2026-09-01" "$scratch/run.stderr" \
    || fail "scenario 3: every digested unit needs a logged disposition; stderr: $(cat "$scratch/run.stderr")"
grep -qF "Disposition: digested" "$digest" \
    || fail "scenario 3: digest file must record the disposition"

# Pointer: the live board names where the stale items went.
grep -q "^## DRAIN-DIGEST .* moved to $digest" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 3: live file must carry a DRAIN-DIGEST pointer to $digest"

# Converged — the breach stamp is cleared.
[[ ! -f "$AS/lanes/fleet-escalation-drain.over-bound" ]] \
    || fail "scenario 3: converged file must clear the breach stamp"
ok "scenario 3: >24h breach — LOUD + oldest-first digest, file converges, disposition logged, stamp cleared"

# Idempotency: a re-run on the converged file digests nothing and stays
# silent on the bound path.
cp "$AS/NISH-ESCALATIONS.md" "$scratch/s3.after"
rm -f "$scratch/run.stderr"
run_drain
cmp -s "$scratch/s3.after" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 3: re-run on converged file must be a no-op (idempotent)"
if grep -q "digested:\|BOUND-BREACH" "$scratch/run.stderr"; then
    fail "scenario 3: re-run must not re-alert or re-digest; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 3: re-run on converged file is a no-op"

# ---------------------------------------------------------------------------
# Scenario 4: never-lose invariant — an ACTIVE boundary entry (formal
# class entry whose hash is NOT in the seen set) is never a digest
# candidate, even when it is the oldest unit. A DELIVERED entry (hash in
# the seen set) is removed by the existing delivered-promotion pass —
# the digest only ever sees what promotion could not move.
# ---------------------------------------------------------------------------
active_line='2026-09-01T00:00:00Z CREDENTIAL-BOUNDARY hash=active-undelivered count=1'
delivered_line='2026-09-01T00:10:00Z MONEY-BOUNDARY hash=delivered-old count=1'
{
    printf '# Nish escalations — out-of-band surface\n'
    printf '\n'
    printf 'One line per escalation, append-only.\n'
    printf 'Header line 4\n'
    printf 'Header line 5\n'
    printf '\n'
    printf 'Format: `<UTC ISO8601> <REASON> hash=<sha256> [detail...]`\n'
    printf '(preamble documentation line)\n'
    # Oldest units: the active entry, then the delivered entry, then prose.
    printf '%s\n' "$active_line"
    printf '  body: page never delivered — must stay live.\n'
    printf '%s\n' "$delivered_line"
    printf '  body: delivered long ago.\n'
    for i in $(seq 1 9); do
        printf '## 2026-09-%02d — stale prose section %d\n' "$i" "$i"
        printf '%s\n%s\n%s\n\n' "- body a $i" "- body b $i" "- body c $i"
    done
} > "$AS/NISH-ESCALATIONS.md"
# File = 8 preamble + 2 + 2 + 45 = 57 > 50.
key_of "$delivered_line" > "$AS/lanes/nish-boundary-notify.seen"
stamp_at "$(date -u -d '30 hours ago' +%s)"

run_drain

grep -qF "$active_line" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 4: ACTIVE (undelivered) entry must NEVER be digested"
grep -qF "page never delivered" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 4: ACTIVE entry's continuation must stay with it"
grep -qF "$delivered_line" "$AS/NISH-ESCALATIONS.md" \
    && fail "scenario 4: DELIVERED entry must be promoted out of the live file" || true
archive="$AS/nish-escalations-archive/$day.md"
[[ -f "$archive" ]] || fail "scenario 4: archive file missing at $archive"
grep -qF "$delivered_line" "$archive" \
    || fail "scenario 4: delivered entry's disposition is the archive"
lines_now=$(wc -l < "$AS/NISH-ESCALATIONS.md")
[[ "$lines_now" -le 50 ]] \
    || fail "scenario 4: file must converge around the protected active entry, got $lines_now"
ok "scenario 4: active undelivered entry protected; delivered entry digested"

# ---------------------------------------------------------------------------
# Scenario 5: under-bound file clears a stale stamp.
# ---------------------------------------------------------------------------
build_prose_file 3   # 9 + 15 = 24 <= 50
stamp_at "$(date -u -d '48 hours ago' +%s)"
run_drain
[[ ! -f "$AS/lanes/fleet-escalation-drain.over-bound" ]] \
    || fail "scenario 5: at/under-bound file must clear the breach stamp"
grep -q "bound-breach cleared" "$scratch/run.stderr" \
    || fail "scenario 5: stamp removal must be logged; stderr: $(cat "$scratch/run.stderr")"
ok "scenario 5: converged file clears the stamp"

# ---------------------------------------------------------------------------
# Scenario 6: DRY_RUN reports the digest but writes nothing — no file
# rewrite, no digest file, no stamp churn.
# ---------------------------------------------------------------------------
build_prose_file 10
stamp_at "$(date -u -d '26 hours ago' +%s)"
cp "$AS/NISH-ESCALATIONS.md" "$scratch/s6.before"
rm -f "$digest"

FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_ARCHIVE_DIR="$AS/nish-escalations-archive" \
FLEET_ESCALATION_DRAIN_DIGEST_DIR="$AS/nish-escalations-archive" \
FLEET_ESCALATION_DRAIN_OVER_BOUND_STAMP="$AS/lanes/fleet-escalation-drain.over-bound" \
FLEET_ESCALATION_DRAIN_OVER_BOUND_AGE_S=86400 \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" --dry-run 2>"$scratch/run.stderr"

grep -q "DRY: bound-digest would move" "$scratch/run.stderr" \
    || fail "scenario 6: dry-run must report the planned digest; stderr: $(cat "$scratch/run.stderr")"
cmp -s "$scratch/s6.before" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 6: dry-run must not rewrite the live file"
[[ ! -f "$digest" ]] \
    || fail "scenario 6: dry-run must not write the digest file"
ok "scenario 6: --dry-run reports the bound-breach digest and touches nothing"

# ---------------------------------------------------------------------------
# Scenario 7: alert without digest — BOUND_DIGEST=0 still fires the LOUD
# alert on a persistent breach (detected state) but moves nothing.
# ---------------------------------------------------------------------------
stamp_at "$(date -u -d '26 hours ago' +%s)"
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_OVER_BOUND_STAMP="$AS/lanes/fleet-escalation-drain.over-bound" \
FLEET_ESCALATION_DRAIN_OVER_BOUND_AGE_S=86400 \
FLEET_ESCALATION_DRAIN_SEAT_DIR="$AS/lanes/seats" \
FLEET_ESCALATION_DRAIN_BOUND_DIGEST=0 \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run.stderr"

grep -q "LOUD \[BOUND-BREACH\].*bound-digest disabled" "$scratch/run.stderr" \
    || fail "scenario 7: disabled digest must still fire the LOUD alert; stderr: $(cat "$scratch/run.stderr")"
cmp -s "$scratch/s6.before" "$AS/NISH-ESCALATIONS.md" \
    || fail "scenario 7: disabled digest must not rewrite the live file"
ok "scenario 7: BOUND_DIGEST=0 alerts without converging"

echo "PASS: escalation-drain-bound — bound-breach alert, oldest-first digest, dispositions, active-entry protection, stamp lifecycle"
