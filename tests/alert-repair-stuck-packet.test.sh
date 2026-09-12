#!/usr/bin/env bash
# tests/alert-repair-stuck-packet.test.sh
#
# fleet-ops#5622: a webhook packet older than STUCK_AGE_S with NO terminated
# chain is a repair claim nobody picked up; the drain used to only LOUD it
# hourly forever (260 packets, oldest 2026-09-05, +10/2h growth). Now the
# drain gives every stuck packet a TERMINAL DISPOSITION in the same run:
#
#   1. one aggregate escalation issue per burst (fleet-issue-file, deduped
#      via a state file + newest-packet watermark),
#   2. each disposed packet archived to archived/stuck/ with a DISPOSITION
#      decision line in actions.log (terminal=escalated-filed, or
#      terminal=reasoned-drop when an existing filing covers it),
#   3. fail-open: when filing is unavailable, packets stay + LOUD (unchanged).
#
# Hermetic: scratch ALERT dir, fake chains.terminated.jsonl, and a stub
# fleet-issue-file. The real GitHub API and the live agent-state dir are
# never touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-escalation-drain"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "drain not executable: $bin"

scratch="$(mktemp -d -t stuck-pkt.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/agent-state"
mkdir -p "$AS/alert-repair"

# Success stub: records invocations, prints a fixture issue URL (the drain
# parses issue #999 from it), never touches the network.
STUB_LOG="$scratch/stub-calls.log"
cat > "$scratch/fleet-issue-file-stub" <<STUB
#!/usr/bin/env bash
echo "stub-call \$*" >> "$STUB_LOG"
echo "https://github.com/Nishfleet/fleet-ops/issues/999"
STUB
chmod +x "$scratch/fleet-issue-file-stub"

# Failing stub for the fail-open case.
cat > "$scratch/fleet-issue-file-fail" <<'STUB'
#!/usr/bin/env bash
echo "gh: filing refused (stub)" >&2
exit 1
STUB
chmod +x "$scratch/fleet-issue-file-fail"

# Empty terminal ledger: every older-than-cutoff webhook packet is "stuck".
: > "$AS/alert-repair/chains.terminated.jsonl"

ts_11h_ago="$(date -u -d '11 hours ago' +%Y%m%dT%H%M%SZ)"
ts_9h_ago="$(date -u -d '9 hours ago' +%Y%m%dT%H%M%SZ)"
ts_8h_ago="$(date -u -d '8 hours ago' +%Y%m%dT%H%M%SZ)"
ts_7h_ago="$(date -u -d '7 hours ago' +%Y%m%dT%H%M%SZ)"
ts_1h_ago="$(date -u -d '1 hour ago' +%Y%m%dT%H%M%SZ)"

run_drain() {
    FLEET_ESCALATION_DRAIN_ISSUE_FILE="$1" \
    FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
    FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
    FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
    FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
    FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
        bash "$bin" 2>"$scratch/run.stderr"
}

# ---------------------------------------------------------------------------
# Scenario 1: no stuck packets -> filing stub never called, no LOUD, fresh
# in-flight packet untouched (bounded signal, zero network).
# ---------------------------------------------------------------------------
touch "$AS/alert-repair/packet-FreshInFlight-${ts_1h_ago}.md"
: > "$STUB_LOG"
run_drain "$scratch/fleet-issue-file-stub"
[[ -s "$STUB_LOG" ]] && fail "scenario 1: no stuck packets must NOT invoke the filing stub (calls: $(cat "$STUB_LOG"))"
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "scenario 1: fresh in-flight packet must not trip LOUD; stderr: $(cat "$scratch/run.stderr")"
fi
[[ -f "$AS/alert-repair/packet-FreshInFlight-${ts_1h_ago}.md" ]] \
    || fail "scenario 1: fresh in-flight packet must be KEPT"
ok "scenario 1: fresh packet untouched; no filing, no LOUD"

# ---------------------------------------------------------------------------
# Scenario 2: stuck packet + filing success -> CONVERGES: exactly one
# aggregate filing, packet archived, DISPOSITION decision logged with the
# issue number, no LOUD line, second run a no-op.
# ---------------------------------------------------------------------------
touch "$AS/alert-repair/packet-FleetStuckOne-${ts_9h_ago}.md"
: > "$STUB_LOG"
run_drain "$scratch/fleet-issue-file-stub"

[[ "$(grep -c "^stub-call " "$STUB_LOG")" -eq 1 ]] \
    || fail "scenario 2: exactly one fleet-issue-file call expected per burst; got $(grep -c "^stub-call " "$STUB_LOG")"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetStuckOne-${ts_9h_ago}.md" ]] \
    || fail "scenario 2: stuck packet must be archived under archived/stuck/"
[[ ! -f "$AS/alert-repair/packet-FleetStuckOne-${ts_9h_ago}.md" ]] \
    || fail "scenario 2: disposed packet must not remain in the live dir"

# Decision line names the real packet, the terminal and the issue.
grep -F "DISPOSITION stuck-packet packet=packet-FleetStuckOne-${ts_9h_ago}.md terminal=escalated-filed issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 2: actions.log must carry the DISPOSITION line; log: $(cat "$AS/alert-repair/actions.log" 2>/dev/null || true)"

# The stalled signal converged: no LOUD after a settled burst.
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "scenario 2: settled burst must NOT re-LOUD; stderr: $(cat "$scratch/run.stderr")"
fi

# State file records the watermark (newest stuck packet instant) + issue.
[[ -f "$AS/alert-repair/stuck-escalation-state.json" ]] \
    || fail "scenario 2: state file must be written"
jq -e '.issue == "999" and .n_packets == 1' "$AS/alert-repair/stuck-escalation-state.json" >/dev/null \
    || fail "scenario 2: state file must record issue + packet count"

# Idempotency: second run files nothing and archives nothing further.
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ -s "$STUB_LOG" ]] && fail "scenario 2: re-run must be a no-op, no second filing"
n_disposition_lines_pre="$(grep -c DISPOSITION "$AS/alert-repair/actions.log")"
[[ "$n_disposition_lines_pre" -eq 1 ]] \
    || fail "scenario 2: re-run must not double-log dispositions (got $n_disposition_lines_pre)"
ok "scenario 2: stuck packet archived + decision-logged + filed once; re-run silent"

# ---------------------------------------------------------------------------
# Scenario 3: filing path unavailable -> fail-open (packet kept + LOUD),
# identical to the pre-#5622 behaviour. Nothing archived, no state write.
# ---------------------------------------------------------------------------
touch "$AS/alert-repair/packet-FleetStuckFail-${ts_8h_ago}.md"
run_drain "$scratch/fleet-issue-file-fail"
grep -q "STUCK-PACKET.*packet-FleetStuckFail-${ts_8h_ago}.md" "$scratch/run.stderr" \
    || fail "scenario 3: failed filing must fail open with the LOUD line; stderr: $(cat "$scratch/run.stderr")"
[[ -f "$AS/alert-repair/packet-FleetStuckFail-${ts_8h_ago}.md" ]] \
    || fail "scenario 3: failed-filing packet must be KEPT (never silently deleted)"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetStuckFail-${ts_8h_ago}.md" ]] \
    && fail "scenario 3: failed-filing packet must NOT be archived" || true
ok "scenario 3: filing failure keeps the packet + LOUD (fail open)"

# ---------------------------------------------------------------------------
# Scenario 4: state watermark dedupe — an OLDER- THAN-watermark stuck packet
# arriving after a settled burst is a reasoned drop under the EXISTING filing
# (no second network filing); a NEWER one re-opens the burst with a FRESH
# filing.
# ---------------------------------------------------------------------------
# 4a. 11h-ago < 9h-ago watermark: covered -> reasoned drop, no filing.
touch "$AS/alert-repair/packet-FleetStuckLate-${ts_11h_ago}.md"
: > "$STUB_LOG"
run_drain "$scratch/fleet-issue-file-stub"
[[ -s "$STUB_LOG" ]] \
    && fail "scenario 4a: packet covered by the state watermark must NOT re-file (calls: $(cat "$STUB_LOG"))"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetStuckLate-${ts_11h_ago}.md" ]] \
    || fail "scenario 4a: covered packet must still be archived (reasoned drop)"
grep -F "DISPOSITION stuck-packet packet=packet-FleetStuckLate-${ts_11h_ago}.md terminal=reasoned-drop issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 4a: covered packet must be logged as reasoned-drop under the existing filing; log: $(tail -3 "$AS/alert-repair/actions.log")"

# 4b. a NEW STUCK packet NEWER than the watermark re-opens the burst.
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
touch "$AS/alert-repair/packet-FleetStuckFresh-${ts_7h_ago}.md"
run_drain "$scratch/fleet-issue-file-stub"
[[ "$(grep -c "^stub-call " "$STUB_LOG")" -eq 1 ]] \
    || fail "scenario 4b: a newer stuck packet must re-open the burst with a fresh filing; calls: $(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetStuckFresh-${ts_7h_ago}.md" ]] \
    || fail "scenario 4b: new burst packet must be disposed; stderr: $(cat "$scratch/run.stderr")"
ok "scenario 4: watermark dedupe — covered packets are reasoned drops, newer ones re-file"

echo
echo "alert-repair-stuck-packet: all scenarios passed (fleet-ops#5622)"
