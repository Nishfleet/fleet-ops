## What changed and why

`opus-heartbeat` exited **70 (NO_VERDICT)** at 2026-08-31T10:30:37Z after
Opus emitted a fabricated tool-call transcript (literal `<invoke
name="Bash">` blocks + invented JSON results, plus a trailing `VERDICT:
SMOOTH`). The previous `grep -qiE 'VERDICT:'` gate accepted the verdict
line; the action allowlist would have executed the emitted shell block
against the invented outputs. The fallback (`opus-heartbeat-fallback`)
had already returned VERDICT: SMOOTH with `Result=success`, so the unit
was actually covered — yet `list-units --state=failed` showed it
`failed`, which trains the fleet to ignore the red list.

Three mechanical fixes:

1. **`/home/nish/.local/share/opus-heartbeat/judge-prompt.md`** — added
   an explicit "Fleet-ops#2517 — tool-less path" preamble. It states
   the wrapper is running with NO TOOLS (the `--disallowed-tools` list
   is named verbatim), forbids `<invoke name="...">`, `<parameter
   name="...">`, and any other tool-use XML/JSON shape, and forbids
   inventing tool results. The existing first-line `VERDICT:` contract
   is preserved.

2. **`/home/nish/.local/libexec/opus-heartbeat`** — added a cheap
   output sanity gate (`fabricated_transcript_gate()`) that runs AFTER
   VERDICT detection and BEFORE action extraction. It does two
   `grep -F` calls against `$CLAUDE_OUT` for `<invoke` and
   `<parameter`; either marker fires the gate. The gate ships two
   self-check flags (`--check-fabricated-gate <file>` for unit
   testing, `--run-fabricated-scenario <file>` for end-to-end scenario
   testing). The integration:
   - logs `FABRICATED-TRANSCRIPT gate=<marker>` to `run.log`
   - dispatches the Pi fallback for coverage
   - writes a `verdict=FABRICATED_TRANSCRIPT` journal entry with the
     marker field
   - emits a new lifetime counter
     `fleet_opus_heartbeat_fabricated_transcript_total` on the textfile
   - **exits 0** (NOT 70) so the unit does NOT sit `failed` —
     coverage was real, the duty officer's "failed units must be
     EMPTY" invariant holds

3. **`tests/opus-heartbeat-fabricated-transcript-gate.test.sh`** —
   14 offline assertions that lock the new behavior:
   - `--check-fabricated-gate` exits 0 on FABRICATED (gate fired) and
     1 on OK (gate did not fire)
   - either marker (`<invoke` OR `<parameter`) fires the gate
   - clean FAULTS output does NOT false-positive
   - missing/unreadable file argument → rc=2 (usage error)
   - `--run-fabricated-scenario` exits 0 on FABRICATED (covered by
     fallback, not failed), writes a `FABRICATED_TRANSCRIPT` journal
     entry with marker field, bumps the counter, sets verdict=-2 and
     rc=0 in the textfile
   - clean path through `--run-fabricated-scenario` does NOT touch
     the journal or counter (only fabricated path produces receipts)
   - launcher source contains the gate function, both self-check
     flags, the counter metric, both marker checks, and the #2517
     citation
   - judge prompt cites #2517, declares NO TOOLS, forbids
     `<invoke>`/`<parameter>`, keeps the VERDICT first-line contract

The new test is added to `live_skip` in
`tests/p14-test-listing-gate.test.sh` (same pattern as the four other
opus-heartbeat tests) because it reads VPS-local state
(`/home/nish/.local/libexec/opus-heartbeat` and
`/home/nish/.local/share/opus-heartbeat/judge-prompt.md`).

### Decision on the "covered by fallback" question

The issue asks: should a NO_VERDICT tick whose fallback returned
success still leave the unit `failed`, or exit 0 with a distinct
metric? **Decision: exit 0 with a distinct metric, AND scope the
decision to the new FABRICATED_TRANSCRIPT path** (this PR).

Rationale:
- The pre-existing `NO_VERDICT` (rc=70), `AUTH_WALL` (rc=75), and
  `BURN-GUARD` (rc=124) paths are unchanged. They each signal a
  specific failure class the duty officer already triages on, and
  remapping them is a behavior change that needs its own decision.
- The FABRICATED_TRANSCRIPT class is NEW. It is the ONLY path where
  the model produced output the wrapper must reject for safety (a
  fabricated transcript can never reach the action allowlist), AND
  the fallback had already covered the run. The "covered by fallback"
  framing in the issue maps 1:1 to this case.
- Existing exit codes are loud in `list-units --state=failed` for
  reasons the duty officer knows. A new exit code (`exit 0` + the
  `verdict=-2` gauge + the lifetime counter) gives the next duty
  officer an explicit signal in the same dashboards without
  polluting the failed-units list.

The fallback-dispatch behavior is identical to the existing
`NO_VERDICT` path: dispatch fallback, exit 0 (new for this path).
The receipt is the `FABRICATED_TRANSCRIPT` journal entry + the
`fleet_opus_heartbeat_fabricated_transcript_total` counter, both
read by the next duty officer's tick.

Verification:

```
$ bash tests/opus-heartbeat-fabricated-transcript-gate.test.sh
OK: test 1: <invoke + <parameter + VERDICT → FABRICATED marker=<invoke (rc=0)
OK: test 2: <parameter only (no <invoke>) → FABRICATED marker=<parameter (rc=0)
OK: test 3: clean output → OK (rc=1)
OK: test 4: clean FAULTS output → OK (rc=1) — gate does not false-positive on normal verdict text
OK: test 5: missing file argument → rc=2 (usage error)
OK: test 6: unreadable file → rc=2 (usage error)
OK: test 7a: FABRICATED scenario exits 0 (covered by fallback, not failed)
OK: test 7b: FABRICATED_TRANSCRIPT journal entry written with marker=<invoke
OK: test 7c: textfile has counter>=1, verdict=-2, rc=0
OK: test 7d: run.log has FABRICATED-TRANSCRIPT + DONE lines
OK: test 7e: actions.log has FALLBACK-DISPATCH line
OK: test 8: clean output → SCENARIO-OK, no journal entry, counter unchanged
OK: test 9: launcher source contains gate function + self-check flags + counter metric + marker checks + #2517 citation
OK: test 10: judge prompt cites #2517, declares NO TOOLS, forbids <invoke>/<parameter>, keeps VERDICT first-line contract
```

Existing opus-heartbeat tests still pass:

```
$ for t in tests/opus-heartbeat-*.test.sh; do bash "$t" >/dev/null && echo "PASS: $t" || echo "FAIL: $t"; done
PASS: tests/opus-heartbeat-allowlist-gate.test.sh
PASS: tests/opus-heartbeat-fabricated-transcript-gate.test.sh
PASS: tests/opus-heartbeat-follow-through.test.sh
PASS: tests/opus-heartbeat-replayed-frozen-snapshot.test.sh
PASS: tests/opus-heartbeat-seat-comeback.test.sh
PASS: tests/opus-heartbeat-thorough-mode.test.sh
```

run-proof: integration scenario transcript (`--run-fabricated-scenario`
with the live #2517 fixture, isolated state dir):

```
$ OPUS_HB_STATE=/tmp/fab-integration-test OPUS_HB_TEXTFILE=/tmp/fab-integration-test/metrics.prom \
    /home/nish/.local/libexec/opus-heartbeat --run-fabricated-scenario /tmp/fab-integration-test/fab-output.txt
SCENARIO-FABRICATED rc=0 marker=FABRICATED marker=<invoke ft_total=1
exit code: 0

# journal.jsonl
{"ts": "2026-08-31T11:23:00Z", "epoch": 1788175380, "verdict": "FABRICATED_TRANSCRIPT", "claude_rc": 0, "snap_bytes": 0, "marker": "FABRICATED marker=<invoke", "scenario": 1}

# metrics.prom (verdict=-2, rc=0, counter=1)
fleet_opus_heartbeat_verdict -2
fleet_opus_heartbeat_rc 0
fleet_opus_heartbeat_fabricated_transcript_total 1

# actions.log
2026-08-31T11:23:00Z FALLBACK-DISPATCH reason=fabricated-transcript (scenario test)

# run.log
2026-08-31T11:23:00Z FABRICATED-TRANSCRIPT gate=FABRICATED marker=<invoke
2026-08-31T11:23:00Z DONE verdict=FABRICATED_TRANSCRIPT covered=fallback ft_total=1 (scenario)
```

research: live snapshot at `/home/nish/.local/state/opus-heartbeat/last-claude.txt`
preserved verbatim from the 2026-08-31T10:30:37Z tick; replayed shape is
the live case (2313 bytes, `<invoke>` + `<parameter>` + invented JSON +
trailing `VERDICT: SMOOTH`). The Claude Code `--disallowed-tools` flag
(replacing the unreliable `--tools ""`) was already in use at
fleet-ops#1382; the new gate covers the residual class where the model
emits XML anyway. No new `bin/` files in this PR; the changes ship at
the install paths the launcher and judge prompt already own (both
intentionally out-of-repo per the existing comment block on
`/home/nish/.local/libexec/opus-heartbeat`).

help-first: `~/.local/libexec/opus-heartbeat --help` is not implemented;
the launcher's contract is the prompt + allowlist + actions.log line
shape. The gate is wired via two new self-check subcommands
(`--check-fabricated-gate`, `--run-fabricated-scenario`) that the new
test drives; nothing in the existing surface covers the fabricated
transcript class, so these are the smallest correct additions.

ci-workflow-pending: a follow-up issue (this PR cannot edit
`.github/workflows/**` from the nishfleet-worker App token) asks Nish
to add `tests/opus-heartbeat-fabricated-transcript-gate.test.sh` to
the P14 verify stage so a future refactor cannot silently regress the
gate. The test is already added to `live_skip` in
`tests/p14-test-listing-gate.test.sh` so P14 does not block on the
missing ci.yml line.

Closes #2517
