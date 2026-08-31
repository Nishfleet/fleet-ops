#!/usr/bin/env bash
# tests/opus-heartbeat-fabricated-transcript-gate.test.sh
#
# fleet-ops#2517: the opus-heartbeat launcher MUST reject any Opus
# output containing tool-call syntax (`<invoke` or `<parameter`),
# even when a `VERDICT:` line is present, so a fabricated transcript
# can never reach the action allowlist. The live case at
# 2026-08-31T10:30:37Z had BOTH a `<invoke name="Bash">` block AND a
# trailing `VERDICT: SMOOTH` line; the previous gate accepted it,
# the action block contained `gh issue list`, and the wrapper would
# have executed that allowlisted command against invented outputs.
# The wrapper then exited 70, leaving the unit `failed` in
# `list-units --state=failed`, even though the Pi fallback had
# returned VERDICT: SMOOTH.
#
# This test pins three layers of the fix:
#
#   1. The `--check-fabricated-gate` self-check flag exits 0 on
#      FABRICATED (gate fired) and 1 on OK (gate did NOT fire).
#   2. The `--run-fabricated-scenario` self-check flag drives the
#      FULL post-judge integration (gate + fallback dispatch + journal
#      entry + metric bump) end-to-end with a fake Claude output,
#      SKIPS gather and Opus, and stubs the fallback to `true` so no
#      Pi seat spins up. The integration MUST:
#        - exit 0 (not 70; coverage was attempted via fallback)
#        - write a FABRICATED_TRANSCRIPT journal entry
#        - bump the lifetime counter on the textfile
#        - log the FABRICATED-TRANSCRIPT line to run.log
#        - leave the actions.log with a FALLBACK-DISPATCH line
#   3. The clean path (no `<invoke`, no `<parameter>`) MUST NOT
#      touch the journal or the counter — only the fabricated path
#      produces receipts.
#
# The launcher is at /home/nish/.local/libexec/opus-heartbeat (the
# canonical install path). All assertions use the
# `--check-fabricated-gate` and `--run-fabricated-scenario` self-check
# flags the launcher ships for exactly this purpose.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention):
# the launcher binary at /home/nish/.local/libexec/opus-heartbeat is
# absent on hosted CI runners, so the test is added to live_skip in
# tests/p14-test-listing-gate.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

LAUNCHER="${OPUS_HB_LAUNCHER:-/home/nish/.local/libexec/opus-heartbeat}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$LAUNCHER" ]] || fail "launcher not executable: $LAUNCHER"
command -v grep >/dev/null 2>&1 || fail "grep missing"

# Isolated state dir so the test does not clobber the live state dir
# the running opus-heartbeat.timer writes to. OPUS_HB_STATE moves every
# file path the launcher touches (JOURNAL, ACTIONS_LOG, RUNLOG, SNAP,
# VERDICT_FILE, CLAUDE_OUT, TEXTFILE) into the scratch dir.
TMP_STATE="$(mktemp -d -t opus-2517-state.XXXXXX)"
TMP_SNAP_DIR="$(mktemp -d -t opus-2517-snapdir.XXXXXX)"
TMP_FIX_DIR="$(mktemp -d -t opus-2517-fix.XXXXXX)"

cleanup() {
  rm -rf "$TMP_STATE" "$TMP_SNAP_DIR" "$TMP_FIX_DIR"
}
trap cleanup EXIT INT TERM

# --- fixtures --------------------------------------------------------------
# 1) FABRICATED output containing <invoke name="Bash"> + <parameter>
#    + a trailing VERDICT: SMOOTH (this is the live #2517 shape).
FAB_OUT="$TMP_FIX_DIR/fabricated.txt"
cat >"$FAB_OUT" <<'EOF'
<invoke name="Bash">
<parameter name="command">gh issue list -R Nishfleet/fleet-ops -l agent-ready --state open</parameter>
<parameter name="description">Check for open duplicate agent-ready issues</parameter>
</invoke>


{"n":2477,"t":"FleetQueueSelfMaintenanceRatioHigh: ...","l":["agent-ready","priority-high"]}


<invoke name="Bash">
<parameter name="command">tail -1 NISH-ESCALATIONS.md</parameter>
<parameter name="description">Append boundary escalation line</parameter>
</invoke>


VERDICT: SMOOTH
EOF

# 2) FABRICATED output containing ONLY <parameter> (no <invoke>).
#    Either marker alone is sufficient.
PARAM_OUT="$TMP_FIX_DIR/parameter-only.txt"
cat >"$PARAM_OUT" <<'EOF'
VERDICT: FAULTS
ACTIONS:
```bash
<parameter name="command">cat /etc/passwd</parameter>
```
EOF

# 3) CLEAN output (no tool-call syntax, has VERDICT line).
CLEAN_OUT="$TMP_FIX_DIR/clean.txt"
cat >"$CLEAN_OUT" <<'EOF'
VERDICT: SMOOTH
EOF

# 4) CLEAN output with an empty ACTIONS block (the FAULTS + ACTIONS
#    shape that the wrapper would pass to the allowlist).
CLEAN_FAULTS_OUT="$TMP_FIX_DIR/clean-faults.txt"
cat >"$CLEAN_FAULTS_OUT" <<'EOF'
VERDICT: FAULTS
ACTIONS:
```bash
gh issue create --repo Nishfleet/fleet-ops --label agent-ready --title test --body test
```
EOF

# --- 1. --check-fabricated-gate: FABRICATED on <invoke> (rc=0) -------------
set +e
out="$("$LAUNCHER" --check-fabricated-gate "$FAB_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 1: expected rc=0 (FABRICATED) on <invoke>, got rc=$rc ($out)"
[[ "$out" == FABRICATED* ]] || fail "test 1: expected FABRICATED prefix, got: $out"
[[ "$out" == *"<invoke"* ]] || fail "test 1: expected marker=<invoke in output, got: $out"
ok "test 1: <invoke + <parameter + VERDICT → FABRICATED marker=<invoke (rc=0)"

# --- 2. --check-fabricated-gate: FABRICATED on <parameter> (rc=0) ----------
set +e
out="$("$LAUNCHER" --check-fabricated-gate "$PARAM_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 2: expected rc=0 (FABRICATED) on <parameter>, got rc=$rc ($out)"
[[ "$out" == FABRICATED* ]] || fail "test 2: expected FABRICATED prefix, got: $out"
[[ "$out" == *"<parameter"* ]] || fail "test 2: expected marker=<parameter in output, got: $out"
ok "test 2: <parameter only (no <invoke>) → FABRICATED marker=<parameter (rc=0)"

# --- 3. --check-fabricated-gate: OK on clean output (rc=1) ------------------
set +e
out="$("$LAUNCHER" --check-fabricated-gate "$CLEAN_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 3: expected rc=1 (OK) on clean output, got rc=$rc ($out)"
[[ "$out" == "OK" ]] || fail "test 3: expected 'OK' literal, got: $out"
ok "test 3: clean output → OK (rc=1)"

# --- 4. --check-fabricated-gate: OK on clean FAULTS output (rc=1) ----------
set +e
out="$("$LAUNCHER" --check-fabricated-gate "$CLEAN_FAULTS_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 4: expected rc=1 (OK) on clean FAULTS output, got rc=$rc ($out)"
[[ "$out" == "OK" ]] || fail "test 4: expected 'OK' literal, got: $out"
ok "test 4: clean FAULTS output → OK (rc=1) — gate does not false-positive on normal verdict text"

# --- 5. --check-fabricated-gate: missing file is a usage error (rc=2) -----
set +e
out="$("$LAUNCHER" --check-fabricated-gate 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "test 5: expected rc=2 (usage error) when no file given, got rc=$rc ($out)"
ok "test 5: missing file argument → rc=2 (usage error)"

# --- 6. --check-fabricated-gate: unreadable file is a usage error (rc=2) --
set +e
out="$("$LAUNCHER" --check-fabricated-gate /nonexistent/path/garbage 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "test 6: expected rc=2 (usage error) when file is unreadable, got rc=$rc ($out)"
ok "test 6: unreadable file → rc=2 (usage error)"

# --- 7. End-to-end scenario: FABRICATED output drives full integration ---
# Reset state, then run with --run-fabricated-scenario. Must exit 0 (not
# 70), write a FABRICATED_TRANSCRIPT journal entry, and bump the counter.
TMP_TEXTFILE="$TMP_STATE/metrics.prom"
JOURNAL="$TMP_STATE/journal.jsonl"
ACTIONS_LOG="$TMP_STATE/actions.log"
RUNLOG="$TMP_STATE/run.log"
: >"$JOURNAL"
: >"$ACTIONS_LOG"
: >"$RUNLOG"
: >"$TMP_TEXTFILE"

set +e
out="$(OPUS_HB_STATE="$TMP_STATE" OPUS_HB_TEXTFILE="$TMP_TEXTFILE" \
        "$LAUNCHER" --run-fabricated-scenario "$FAB_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 7: expected rc=0 (covered by fallback) on FABRICATED scenario, got rc=$rc ($out)"
echo "$out" | grep -q '^SCENARIO-FABRICATED' || fail "test 7: expected SCENARIO-FABRICATED prefix, got: $out"
ok "test 7a: FABRICATED scenario exits 0 (covered by fallback, not failed)"

# Journal has exactly one FABRICATED_TRANSCRIPT entry.
n_journal="$(grep -c '"verdict": "FABRICATED_TRANSCRIPT"' "$JOURNAL" || true)"
[[ "$n_journal" -eq 1 ]] || fail "test 7b: expected exactly 1 FABRICATED_TRANSCRIPT journal entry, got $n_journal"
grep -q '"marker": "FABRICATED marker=<invoke"' "$JOURNAL" \
  || fail "test 7b: journal entry missing marker field, journal was: $(cat "$JOURNAL")"
ok "test 7b: FABRICATED_TRANSCRIPT journal entry written with marker=<invoke"

# Metrics textfile has the counter at >=1 and verdict=-2 and rc=0.
grep -q '^fleet_opus_heartbeat_fabricated_transcript_total ' "$TMP_TEXTFILE" \
  || fail "test 7c: missing lifetime counter metric in textfile"
counter="$(awk '/^fleet_opus_heartbeat_fabricated_transcript_total /{print $2}' "$TMP_TEXTFILE")"
[[ "$counter" =~ ^[0-9]+$ ]] || fail "test 7c: counter not an integer, got: $counter"
[[ "$counter" -ge 1 ]] || fail "test 7c: expected counter >= 1, got $counter"
grep -q '^fleet_opus_heartbeat_verdict -2$' "$TMP_TEXTFILE" \
  || fail "test 7c: expected verdict=-2 in textfile (FABRICATED_TRANSCRIPT)"
grep -q '^fleet_opus_heartbeat_rc 0$' "$TMP_TEXTFILE" \
  || fail "test 7c: expected rc=0 in textfile (covered, not failed)"
ok "test 7c: textfile has counter>=1, verdict=-2, rc=0"

# run.log has the FABRICATED-TRANSCRIPT line.
grep -q 'FABRICATED-TRANSCRIPT ' "$RUNLOG" \
  || fail "test 7d: missing FABRICATED-TRANSCRIPT line in run.log"
grep -q 'DONE verdict=FABRICATED_TRANSCRIPT' "$RUNLOG" \
  || fail "test 7d: missing DONE line in run.log"
ok "test 7d: run.log has FABRICATED-TRANSCRIPT + DONE lines"

# actions.log has the FALLBACK-DISPATCH line.
grep -q 'FALLBACK-DISPATCH reason=fabricated-transcript' "$ACTIONS_LOG" \
  || fail "test 7e: missing FALLBACK-DISPATCH line in actions.log"
ok "test 7e: actions.log has FALLBACK-DISPATCH line"

# --- 8. End-to-end scenario: CLEAN output does NOT touch journal/metric ---
# Reset state, then run with --run-fabricated-scenario. Must exit 0,
# must NOT add a journal entry, must NOT bump the counter.
: >"$JOURNAL"
: >"$ACTIONS_LOG"
: >"$RUNLOG"
PRE_COUNTER="$counter"

set +e
out="$(OPUS_HB_STATE="$TMP_STATE" OPUS_HB_TEXTFILE="$TMP_TEXTFILE" \
        "$LAUNCHER" --run-fabricated-scenario "$CLEAN_OUT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 8: expected rc=0 on clean scenario, got rc=$rc ($out)"
[[ "$out" == "SCENARIO-OK" ]] || fail "test 8: expected SCENARIO-OK literal, got: $out"
n_journal="$(grep -c '"verdict": "FABRICATED_TRANSCRIPT"' "$JOURNAL" || true)"
[[ "$n_journal" -eq 0 ]] || fail "test 8b: clean path should NOT write FABRICATED_TRANSCRIPT journal entry, got $n_journal"
POST_COUNTER="$(awk '/^fleet_opus_heartbeat_fabricated_transcript_total /{print $2}' "$TMP_TEXTFILE")"
[[ -z "$POST_COUNTER" ]] || [[ "$POST_COUNTER" == "$PRE_COUNTER" ]] \
  || fail "test 8c: clean path bumped the counter ($PRE_COUNTER -> $POST_COUNTER)"
ok "test 8: clean output → SCENARIO-OK, no journal entry, counter unchanged"

# --- 9. Launcher source locks the gate ------------------------------------
grep -q 'fabricated_transcript_gate' "$LAUNCHER" \
  || fail "launcher missing fabricated_transcript_gate function"
grep -q 'fleet-ops#2517' "$LAUNCHER" \
  || fail "launcher does not cite fleet-ops#2517"
grep -q '\-\-check-fabricated-gate' "$LAUNCHER" \
  || fail "launcher does not ship the --check-fabricated-gate self-check flag"
grep -q '\-\-run-fabricated-scenario' "$LAUNCHER" \
  || fail "launcher does not ship the --run-fabricated-scenario self-check flag"
grep -q "fleet_opus_heartbeat_fabricated_transcript_total" "$LAUNCHER" \
  || fail "launcher does not export the lifetime counter metric"
grep -q "FABRICATED_TRANSCRIPT" "$LAUNCHER" \
  || fail "launcher does not tag the FABRICATED_TRANSCRIPT verdict"
grep -qF '<invoke' "$LAUNCHER" \
  || fail "launcher does not check for <invoke marker"
grep -qF '<parameter' "$LAUNCHER" \
  || fail "launcher does not check for <parameter marker"
ok "test 9: launcher source contains gate function + self-check flags + counter metric + marker checks + #2517 citation"

# --- 10. Judge prompt locks the no-tools contract ------------------------
PROMPT_FILE="${OPUS_HB_PROMPT_FILE:-/home/nish/.local/share/opus-heartbeat/judge-prompt.md}"
[[ -s "$PROMPT_FILE" ]] || fail "judge prompt missing at $PROMPT_FILE"
grep -qiE '#2517' "$PROMPT_FILE" \
  || fail "judge prompt does not cite fleet-ops#2517"
grep -qE 'NO TOOLS' "$PROMPT_FILE" \
  || fail "judge prompt does not state NO TOOLS contract"
grep -qF '<invoke' "$PROMPT_FILE" \
  || fail "judge prompt does not name <invoke as forbidden syntax"
grep -qF '<parameter' "$PROMPT_FILE" \
  || fail "judge prompt does not name <parameter as forbidden syntax"
grep -qE 'fabricated' "$PROMPT_FILE" \
  || fail "judge prompt does not warn against fabricating transcripts"
# First-line VERDICT contract is unchanged.
grep -qE 'VERDICT:[[:space:]]*SMOOTH' "$PROMPT_FILE" \
  || fail "judge prompt lost the VERDICT: SMOOTH first-line contract"
grep -qE 'VERDICT:[[:space:]]*FAULTS' "$PROMPT_FILE" \
  || fail "judge prompt lost the VERDICT: FAULTS first-line contract"
ok "test 10: judge prompt cites #2517, declares NO TOOLS, forbids <invoke>/<parameter>, keeps VERDICT first-line contract"

exit 0
