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
#   3. fail-open: when filing is unavailable, packets stay + LOUD (unchanged),
#   4. the disposed chain also gets a TERMINAL RECORD in
#      chains.terminated.jsonl (terminal=escalated, start_ts = dispatch
#      instant, end_ts = disposal instant) — the consumption proof the
#      retired fleet-completion-canary stopped writing (fleet-ops#5869);
#      the record absorbs later re-dispatches of the same episode so the
#      stuck set returns to 0 instead of the backlog trending up.
#   5. fleet-ops#6430: a stuck-scanned packet already gone at disposal
#      time still gets its DISPOSITION (terminal per the mv-path rule),
#      logged and counted. Never a silent bare continue: #6430's issue
#      names a disposal no production surface proves.
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

# fleet-ops#6642 probe seam: a canned Prometheus /api/v1/alerts payload.
# Every alertname this file's scenarios dispatch as a packet is marked
# FIRING here — the drain's resolved-side probe must never eat them (the
# drain on this box would otherwise see live Prometheus and consume them
# all as resolved). Scenario 9 swaps the fixture to test the probe itself.
FIRING_FIX="$scratch/firing-alerts.json"
set_firing() {
    {
        printf '{"status":"success","data":{"alerts":['
        local i=0 a
        for a in "$@"; do
            [ "$i" -gt 0 ] && printf ','
            printf '{"state":"firing","labels":{"alertname":"%s"}}' "$a"
            i=$((i+1))
        done
        printf ']}}'
    } > "$FIRING_FIX"
}
set_firing FreshInFlight FleetStuckOne FleetStuckFail FleetStuckLate \
    FleetStuckFresh FleetAlpha FleetZulu FleetGhost FleetPhantom \
    FleetStillFiring

ts_11h_ago="$(date -u -d '11 hours ago' +%Y%m%dT%H%M%SZ)"
ts_9h_ago="$(date -u -d '9 hours ago' +%Y%m%dT%H%M%SZ)"
ts_8h_ago="$(date -u -d '8 hours ago' +%Y%m%dT%H%M%SZ)"
ts_7h_ago="$(date -u -d '7 hours ago' +%Y%m%dT%H%M%SZ)"
ts_1h_ago="$(date -u -d '1 hour ago' +%Y%m%dT%H%M%SZ)"

run_drain() {
    # run_drain <issue-file-stub> [firing-file]
    FLEET_ESCALATION_DRAIN_ISSUE_FILE="$1" \
    FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
    FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
    FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
    FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
    FLEET_ESCALATION_DRAIN_FIRING_FILE="${2:-$FIRING_FIX}" \
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

# fleet-ops#5869: the disposal appended exactly ONE terminal record for the
# episode, carrying the legal terminal, the episode bounds and the receipt.
n_fleetstuckone_records="$(jq -c 'select(.alertname == "FleetStuckOne")' "$AS/alert-repair/chains.terminated.jsonl" | wc -l)"
[[ "$n_fleetstuckone_records" -eq 1 ]] \
    || fail "scenario 2: disposal must append exactly one terminal record to chains.terminated.jsonl (got $n_fleetstuckone_records)"
disp_iso="${ts_9h_ago:0:4}-${ts_9h_ago:4:2}-${ts_9h_ago:6:2}T${ts_9h_ago:9:2}:${ts_9h_ago:11:2}:${ts_9h_ago:13:2}Z"
jq -e --arg d "$disp_iso" 'select(.alertname == "FleetStuckOne") | .terminal == "escalated" and .start_ts == $d and .end_ts >= $d and .issue == "999" and .unit == "escalation-drain"' \
    "$AS/alert-repair/chains.terminated.jsonl" >/dev/null \
    || fail "scenario 2: terminal record must be terminal=escalated with start_ts=dispatch, end_ts>=dispatch, issue receipt; ledger: $(cat "$AS/alert-repair/chains.terminated.jsonl")"
ok "scenario 2: stuck packet archived + decision-logged + filed once + terminal record; re-run silent"

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

# fleet-ops#6345: the fail-open leftover's duty (kept + LOUD) ends here.
# Remove it so scenario 4a's burst is exactly the covered-older packet and
# the true-MAX watermark (not this older prop) decides fresh-vs-covered:
# with the prop kept, the 4a burst's newest (8h-ago) exceeds the state
# watermark (9h-ago) and legitimately re-opens the burst with a fresh
# filing instead of taking the reasoned-drop path 4a exists to prove.
rm -f "$AS/alert-repair/packet-FleetStuckFail-${ts_8h_ago}.md"

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

# ---------------------------------------------------------------------------
# Scenario 5 (fleet-ops#5869): the terminal record CONSUMES the episode —
# a same-alertname re-fire dispatched before the disposal instant is
# absorbed under the terminal on the next run (deleted, no filing, no
# LOUD), while a different alertname still in flight is kept. This is the
# termination clause: the stuck set returns to 0 instead of the backlog
# trending up.
# ---------------------------------------------------------------------------
ts_refire="$(date -u -d "@$(( $(date -u +%s) - 6 * 3600 - 1800 ))" +%Y%m%dT%H%M%SZ)"
touch "$AS/alert-repair/packet-FleetStuckOne-${ts_refire}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ -s "$STUB_LOG" ]] \
    && fail "scenario 5: an absorbed re-fire must NOT re-file (calls: $(cat "$STUB_LOG"))"
[[ ! -f "$AS/alert-repair/packet-FleetStuckOne-${ts_refire}.md" ]] \
    || fail "scenario 5: same-alertname re-fire dispatched before the terminal end_ts must be CONSUMED by the record; stderr: $(cat "$scratch/run.stderr")"
n_fleetstuckone_records_after="$(jq -c 'select(.alertname == "FleetStuckOne")' "$AS/alert-repair/chains.terminated.jsonl" | wc -l)"
[[ "$n_fleetstuckone_records_after" -eq "$n_fleetstuckone_records" ]] \
    || fail "scenario 5: consuming a re-fire must not append another terminal record (got $n_fleetstuckone_records_after, want $n_fleetstuckone_records)"
[[ -f "$AS/alert-repair/packet-FreshInFlight-${ts_1h_ago}.md" ]] \
    || fail "scenario 5: a different alertname still in flight must be KEPT"
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "scenario 5: absorbed episode must not re-LOUD; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 5: terminal record absorbs the episode's re-fire — stuck set returns to 0 (fleet-ops#5869)"

# ---------------------------------------------------------------------------
# Scenario 6 (fleet-ops#6345): the newest-packet watermark takes the MAX
# dispatch instant across the burst, not the lexically-last stuck packet.
# Glob order is (alertname, ts) lexicographic, NOT dispatch order, so a
# burst mixing alertnames puts its newest dispatch anywhere in the list.
# Observed 2026-09-13T11:43:48Z: the issue evidence reported "newest
# dispatch instant 04:44:52Z" while FleetLitellmProxyAbsent-053252Z
# (dispatched 05:32:52Z) was in that very burst — the recorded watermark
# understated the newest covered packet, which decides fresh-filing vs
# reasoned-drop for the NEXT burst.
#
# FleetAlpha (7h ago) is the true newest; FleetZulu (9h ago) sorts LAST in
# glob order. The legacy last-entry read reports 9h-ago; the fixed read
# must report 7h-ago in BOTH the filing evidence and the state watermark.
# ---------------------------------------------------------------------------
rm -f "$AS/alert-repair/stuck-escalation-state.json"
touch "$AS/alert-repair/packet-FleetAlpha-${ts_7h_ago}.md"
touch "$AS/alert-repair/packet-FleetZulu-${ts_9h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ "$(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)" -eq 1 ]] \
    || fail "scenario 6: exactly one filing expected for the fresh burst; calls: $(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)"
alpha_iso="${ts_7h_ago:0:4}-${ts_7h_ago:4:2}-${ts_7h_ago:6:2}T${ts_7h_ago:9:2}:${ts_7h_ago:11:2}:${ts_7h_ago:13:2}Z"
grep -F "newest dispatch instant $alpha_iso" "$STUB_LOG" >/dev/null \
    || fail "scenario 6: filing evidence must report the TRUE newest dispatch instant ($alpha_iso), not the lexically-last packet's (${ts_9h_ago}Z); stub: $(cat "$STUB_LOG")"
jq -e --arg a "$alpha_iso" '.newest_packet_iso == $a' "$AS/alert-repair/stuck-escalation-state.json" >/dev/null \
    || fail "scenario 6: state watermark must be the true newest dispatch instant ($alpha_iso); state: $(cat "$AS/alert-repair/stuck-escalation-state.json" 2>/dev/null || true)"
grep -F "DISPOSITION stuck-packet packet=packet-FleetAlpha-${ts_7h_ago}.md terminal=escalated-filed issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 6: FleetAlpha (true newest) must be disposed; log: $(tail -4 "$AS/alert-repair/actions.log")"
grep -F "DISPOSITION stuck-packet packet=packet-FleetZulu-${ts_9h_ago}.md terminal=escalated-filed issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 6: FleetZulu (lexically last) must be disposed; log: $(tail -4 "$AS/alert-repair/actions.log")"
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "scenario 6: fully disposed burst must NOT re-LOUD; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 6: newest-packet watermark = MAX dispatch instant, not the lexically-last stuck packet (fleet-ops#6345)"

# ---------------------------------------------------------------------------
# Scenario 7 (fleet-ops#6430): the vanish gap. A stuck-scanned packet that
# is already gone at disposal time must still get its TERMINAL DISPOSITION:
# a vanished: journal line, a DISPOSITION decision in actions.log, counted,
# never silently dropped. #6430 lived it: the 14:15:47Z run filed its
# escalation, then lost the packet between scan and disposal, and no
# production surface recorded either fact.
#
# Black-box recipe, no race: a stuck-listed "packet" that is a DIRECTORY.
# It globs, its name matches the webhook pattern, the stuck list carries
# it, but [ -f ] fails at disposal. Fresh state (removed here) so the
# burst takes the escalated-filed path, proving the vanished: branch emits
# the same terminal a successful mv would have.
# ---------------------------------------------------------------------------
rm -f "$AS/alert-repair/stuck-escalation-state.json"
mkdir -p "$AS/alert-repair/packet-FleetGhost-${ts_8h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ "$(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)" -eq 1 ]] \
    || fail "scenario 7: the vanished packet's burst must still file exactly once; calls: $(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)"
grep -F "vanished: packet-FleetGhost-${ts_8h_ago}.md" "$scratch/run.stderr" >/dev/null \
    || fail "scenario 7: the vanished packet must be named in the journal; stderr: $(cat "$scratch/run.stderr")"
grep -F "DISPOSITION stuck-packet packet=packet-FleetGhost-${ts_8h_ago}.md terminal=escalated-filed issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 7: the vanished packet must still get its DISPOSITION decision line; log: $(tail -3 "$AS/alert-repair/actions.log" 2>/dev/null || true)"
[[ -d "$AS/alert-repair/packet-FleetGhost-${ts_8h_ago}.md" ]] \
    || fail "scenario 7: the vanished packet's witness must survive (the drain did not move it)"
[[ ! -f "$AS/alert-repair/archived/stuck/packet-FleetGhost-${ts_8h_ago}.md" ]] \
    || fail "scenario 7: a vanished (non-file) unit cannot be archived; it must not pretend it was"
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "scenario 7: a vanished-and-dispositioned burst is settled, must NOT re-LOUD; stderr: $(cat "$scratch/run.stderr")"
fi
ok "scenario 7: vanished-at-disposal packet decision-logged, counted, never silent (fleet-ops#6430)"

# ---------------------------------------------------------------------------
# Scenario 8 (fleet-ops#6536): the filing seam is production-only. A run
# with an overridden packet dir and NO explicit FLEET_ESCALATION_DRAIN_ISSUE_FILE
# must refuse to file into the production tracker and fail open (packet
# kept, LOUD, no DISPOSITION, no archive, no state write). 6536's own
# thread carries the leak this pins: a dedup comment citing "drain run at
# 2026-09-13T20:48:42Z ... newest dispatch instant 2026-09-13T13:48:42Z"
# — a run present in no escalation-drain journal and a packet that never
# existed in the production packet dir. The #1212 gate contained that one
# as a score=1.00 dedup comment; a borderline score would have filed a
# GHOST issue instead.
#
# Scenario 7's FleetGhost witness is a directory and would still be
# stuck-listed; remove it so this scenario's burst is exactly the phantom
# prop (scenario 7's assertions already ran).
# ---------------------------------------------------------------------------
rm -rf "$AS/alert-repair/packet-FleetGhost-${ts_8h_ago}.md"
rm -f "$AS/alert-repair/stuck-escalation-state.json"
unset FLEET_ESCALATION_DRAIN_ISSUE_FILE
touch "$AS/alert-repair/packet-FleetPhantom-${ts_8h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
# Deliberately NO FLEET_ESCALATION_DRAIN_ISSUE_FILE: the unstubbed-hermetic
# shape the guard exists for.
FLEET_ESCALATION_DRAIN_AGENT_STATE="$AS" \
FLEET_ESCALATION_DRAIN_NISH="$AS/NISH-ESCALATIONS.md" \
FLEET_ESCALATION_DRAIN_SEEN="$AS/lanes/nish-boundary-notify.seen" \
FLEET_ESCALATION_DRAIN_PACKET_DIR="$AS/alert-repair" \
FLEET_ESCALATION_DRAIN_FIRING_FILE="$FIRING_FIX" \
FLEET_ESCALATION_DRAIN_MAX_LINES=50 \
    bash "$bin" 2>"$scratch/run.stderr" \
    || fail "scenario 8: a refused filing is fail-open, the drain must still exit 0; stderr: $(cat "$scratch/run.stderr")"
grep -F "WARN refusing stuck-packet filing" "$scratch/run.stderr" >/dev/null \
    || fail "scenario 8: the refusal must be journaled with its reason; stderr: $(cat "$scratch/run.stderr")"
grep -q "STUCK-PACKET" "$scratch/run.stderr" \
    || fail "scenario 8: a refused filing must fail open with the LOUD line; stderr: $(cat "$scratch/run.stderr")"
[[ -f "$AS/alert-repair/packet-FleetPhantom-${ts_8h_ago}.md" ]] \
    || fail "scenario 8: refused-filing packet must be KEPT (never silently deleted)"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetPhantom-${ts_8h_ago}.md" ]] \
    && fail "scenario 8: refused-filing packet must NOT be archived" || true
[[ -f "$AS/alert-repair/stuck-escalation-state.json" ]] \
    && fail "scenario 8: a refused filing must not write the state watermark" || true
grep -qF "packet-FleetPhantom" "$AS/alert-repair/actions.log" \
    && fail "scenario 8: a refused filing must not log a DISPOSITION" || true
[[ -s "$STUB_LOG" ]] \
    && fail "scenario 8: the real seam must never be reached from an unstubbed non-production run; stub: $(cat "$STUB_LOG")" || true
ok "scenario 8: unstubbed non-production run refuses to file, fails open loud (fleet-ops#6536)"

# Negative control: the SAME burst with the seam stubbed converges — the
# guard is the only delta, not the packet shape.
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ "$(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)" -eq 1 ]] \
    || fail "scenario 8: with the seam stubbed the same burst must file exactly once; calls: $(cat "$STUB_LOG" 2>/dev/null || true)"
grep -F "DISPOSITION stuck-packet packet=packet-FleetPhantom-${ts_8h_ago}.md terminal=escalated-filed issue=999" \
    "$AS/alert-repair/actions.log" >/dev/null \
    || fail "scenario 8: stubbed re-run must dispose the packet; log: $(tail -3 "$AS/alert-repair/actions.log" 2>/dev/null || true)"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetPhantom-${ts_8h_ago}.md" ]] \
    || fail "scenario 8: stubbed re-run must archive the packet"
ok "scenario 8: stubbed seam converges the same burst — the guard is the only delta"

# ---------------------------------------------------------------------------
# Scenario 9 (fleet-ops#6642): the resolved-side terminal producer. The AM
# executor never runs the dispatch on status=resolved (the repair-dispatch
# receiver sets send_resolved:false, and the executor itself only signals
# in-flight commands on a resolve), and the retired completion-canary was
# the only other ledger producer — so an alertname absent from Prometheus's
# firing set is observed HERE. An unconsumed webhook packet for a
# not-firing alert gets a terminal=resolved record appended to
# chains.terminated.jsonl and is then consumed by the ordinary rule: no
# filing, no LOUD, no archive.
# ---------------------------------------------------------------------------
rm -f "$AS/alert-repair/stuck-escalation-state.json"

# 9a: a resolved alert's packet -> resolved record + consume.
touch "$AS/alert-repair/packet-FleetResolvedA-${ts_8h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ -s "$STUB_LOG" ]] \
    && fail "9a: a resolved packet must never reach the filing stub (calls: $(cat "$STUB_LOG"))"
[[ ! -f "$AS/alert-repair/packet-FleetResolvedA-${ts_8h_ago}.md" ]] \
    || fail "9a: a resolved packet must be consumed; stderr: $(cat "$scratch/run.stderr")"
disp_iso="${ts_8h_ago:0:4}-${ts_8h_ago:4:2}-${ts_8h_ago:6:2}T${ts_8h_ago:9:2}:${ts_8h_ago:11:2}:${ts_8h_ago:13:2}Z"
jq -e --arg d "$disp_iso" 'select(.alertname == "FleetResolvedA") | .terminal == "resolved" and .unit == "fleet-escalation-drain" and .start_ts == $d and .end_ts >= $d' \
    "$AS/alert-repair/chains.terminated.jsonl" >/dev/null \
    || fail "9a: ledger must carry terminal=resolved start_ts=dispatch unit=fleet-escalation-drain; ledger: $(cat "$AS/alert-repair/chains.terminated.jsonl")"
[[ ! -f "$AS/alert-repair/stuck-escalation-state.json" ]] \
    || fail "9a: a resolved consume is not a stuck burst — no state write"
if grep -q "STUCK-PACKET" "$scratch/run.stderr"; then
    fail "9a: a resolved packet must not LOUD-flag; stderr: $(cat "$scratch/run.stderr")"
fi
ok "9a: resolved alert's unconsumed packet -> terminal=resolved record, consumed, no filing"

# 9b: the one record absorbs the episode — a second same-alert packet is
# consumed under it with NO second record.
touch "$AS/alert-repair/packet-FleetResolvedB-${ts_9h_ago}.md" \
      "$AS/alert-repair/packet-FleetResolvedB-${ts_7h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ ! -f "$AS/alert-repair/packet-FleetResolvedB-${ts_9h_ago}.md" ]] \
    || fail "9b: older resolved packet must be consumed"
[[ ! -f "$AS/alert-repair/packet-FleetResolvedB-${ts_7h_ago}.md" ]] \
    || fail "9b: newer resolved packet must be absorbed under the same record"
n_resolved_b="$(jq -c 'select(.alertname == "FleetResolvedB")' "$AS/alert-repair/chains.terminated.jsonl" | wc -l)"
[[ "$n_resolved_b" -eq 1 ]] \
    || fail "9b: one resolved record must absorb the episode's packets (got $n_resolved_b)"
[[ -s "$STUB_LOG" ]] \
    && fail "9b: absorbed packets must not file (calls: $(cat "$STUB_LOG"))"
ok "9b: one resolved terminal absorbs the episode's packets (episode-collapse)"

# 9c: a still-FIRING alert's old packet is NOT resolved — it takes the
# ordinary stuck path (filed + archived), and no resolved record exists.
touch "$AS/alert-repair/packet-FleetStillFiring-${ts_8h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub"
[[ "$(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)" -eq 1 ]] \
    || fail "9c: a still-firing stuck packet must escalate via the filing path; calls: $(cat "$STUB_LOG" 2>/dev/null || true)"
[[ -f "$AS/alert-repair/archived/stuck/packet-FleetStillFiring-${ts_8h_ago}.md" ]] \
    || fail "9c: a still-firing stuck packet must be disposed, not resolved"
n_resolved_firing="$(jq -c 'select(.alertname == "FleetStillFiring" and .terminal == "resolved")' "$AS/alert-repair/chains.terminated.jsonl" | wc -l)"
[[ "$n_resolved_firing" -eq 0 ]] \
    || fail "9c: a firing alert must never get a resolved record (got $n_resolved_firing)"
ok "9c: still-firing alert's packet -> stuck escalation, never resolved-eaten"

# 9d: probe DARK fails closed — an unreadable firing payload disables the
# producer entirely; the same not-firing packet then takes the ordinary
# stuck path.
rm -f "$AS/alert-repair/stuck-escalation-state.json"
touch "$AS/alert-repair/packet-FleetProbeDark-${ts_8h_ago}.md"
: > "$STUB_LOG"
rm -f "$scratch/run.stderr"
run_drain "$scratch/fleet-issue-file-stub" "$scratch/firing-file-missing.json"
grep -q "resolved-side probe unavailable" "$scratch/run.stderr" \
    || fail "9d: a dark probe must be journaled; stderr: $(cat "$scratch/run.stderr")"
[[ "$(grep -c "^stub-call " "$STUB_LOG" 2>/dev/null || true)" -eq 1 ]] \
    || fail "9d: with the probe dark the stuck path must still file; calls: $(cat "$STUB_LOG" 2>/dev/null || true)"
n_resolved_dark="$(jq -c 'select(.alertname == "FleetProbeDark" and .terminal == "resolved")' "$AS/alert-repair/chains.terminated.jsonl" | wc -l)"
[[ "$n_resolved_dark" -eq 0 ]] \
    || fail "9d: a dark probe must never write resolved records (got $n_resolved_dark)"
ok "9d: probe dark -> fail-closed, ordinary stuck escalation, no resolved record"

echo "OK: fleet-ops#6642 resolved-side terminal producer pass"

echo
echo "alert-repair-stuck-packet: all scenarios passed (fleet-ops#5622)"
