## fix(pi-audit): guard empty-verdict/reason extraction so the log branch is reachable

Closes #4409

### Problem

`extract_verdict` ends in a `grep -m1` pipeline. On no match, `pipefail`
makes the function return 1 and `set -e` killed the script AT the
assignment `verdict=$(extract_verdict "$combined")` — before the
`if [ -z "$verdict" ]` log+exit-1 branch. That branch was dead code: a
seat exiting 0 with no PASS/FAIL token produced no log line, no vote,
exit 1 — a silent death with zero diagnostics. The repair loop hunted a
fault with no log trail.

### Fix

- Guard both assignments (`|| verdict=""` / `|| reason=""`) so the
  empty-verdict/reason branches are reachable.
- Make each branch emit a distinguishing log line before exiting 1
  (systemd retry contract kept deliberately — a seat emitting garbage is
  a genuine audit failure, not a transient provider wall, so it should
  retry once and escalate, not be silently SKIPped).
- Extend scenario 4 to assert the log line (not just the rc), and add
  scenario 4b for the empty-reason path, locking out the silent-death
  class.

### Verification

`bash tests/pi-audit-run.test.sh` — exit 0, all 10 scenarios green,
including the new assertions:

```
OK: scenario4: missing verdict exits 1 and logs a distinguishing line
OK: scenario4b: empty reason exits 1 and logs a distinguishing line
```

Confirmed the old code died silently: reverting the guard produced
`line 125: f: unbound variable` with no verdict log line; the new code
logs `auditor output did not contain a PASS/FAIL verdict (empty verdict;
exiting 1 for systemd retry)`.

Related suites also green: `pi-audit-run-product-repo-reality.test.sh`,
`pi-audit-run-strip-preamble.test.sh`, `pi-audit-tally-escalate-senior.test.sh`.
`bin/sgscan` — no new security findings.

run-proof: `bash tests/pi-audit-run.test.sh` (10 scenarios, exit 0)

net-positive-because: the added lines are the distinguishing log lines and the test assertions that lock out the silent-death class — the whole point of the issue; without them the empty-verdict path dies with zero diagnostics.
