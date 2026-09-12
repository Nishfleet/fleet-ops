## Summary

Ports the regression test half of #5617 (branch `claim/issue-5611`, commit `2f121f698`) into `tests/fleet-blind-audit.test.sh`. #5613 (`0ce5358c2`) already landed the production `--slurpfile` fix; this PR ships the missing prevention mechanism named in #5650 accept 1. Test-only change: no production code, no live host edits.

What the port adds:

- The fake `gh issue list` pads body-carrying calls (`--state open`/`closed`, no `-l` filter) past 131072 bytes (`MAX_ARG_STRLEN`) via `BIG_ISSUES_FILE`; the `-l gap-audit` panel pre-fetch stays small, as in production.
- The full `bin/fleet-blind-audit` harness run asserts exit 0, `run.log` contains `recurrence hunt merged`, and no `Argument list too long`.
- A standalone replay of the old argv pattern (`jq -n --argjson closed <~206KB blob>`) is asserted to exit 126 on this host, matching the 2026-09-12 03:30 IST unit signature — noted in the test comment so the regression test provably fails before / passes after the class of change.

## Verification

```
$ bash tests/fleet-blind-audit.test.sh
... (full suite)
OK: fleet-blind-audit: panel, filing, dedupe, deliberate-state loud, stamp, report ledger
OK: drill: fixture finding filed as gap-audit + agent-ready issue with report linked
OK: drill refuses to file when no stub gh is declared (fleet-ops#5037)
OK: drill refuses to file when its declared stub gh is not the resolved gh (fleet-ops#5037)
OK: token-less drill keeps the stub gh first and files through it (fleet-ops#5037)
OK: fail-loud: unfiled PASS finding exits 1 and is recorded in the report
OK: noncanonical products/fleet-ops root retargets and auto-files
OK: noncanonical tooling/fleet-ops parent retargets
OK: AUDIT_ALLOW_NONCANONICAL=1 skips retarget
OK: open #367-marker issue suppresses a second detector file
OK: prompt carries the manual-seam lens
OK: gap-closure cycle criteria include the seam hunt
OK: enumerator matches, files, and accepts-as-manual
OK: seam naming an explicit issue ref matches the queued mechanism (fleet-ops#1708)
OK: github-issue seams self-match open or delivered mechanisms (fleet-ops#5477)
OK: collect drops worker claims, gap-audit filings, and timer-parent starts
OK: auditor report bullets filtered from actions-log (fleet-ops#2706)
OK: scheduled fable-check/fleet-judge outcomes filtered from memoryctl (fleet-ops#5472)
OK: harness writes the seam table and files unmatched seams
OK: manual-seam lens (fleet-ops#377)
OK: no deliberate-state row with passed expiry (or a stale fleet-paused row)
deliberate-states-registry test: OK
OK: drill FLAG: closed issue with unmerged referencing PR is flagged
OK: drill QUIET: closed issue with a merged referencing PR is not flagged
OK: drill EXCLUDE: duplicate / wontfix / triage-mass-close are not flagged
OK: drill NO-REFS: closed-by-hand issue with no PR refs is not flagged
OK: stdin and --input produce the same result
OK: blind-audit wires the closed-but-undelivered hunt (fleet-ops#3683)
OK: closed-undelivered detector (fleet-ops#3683)
OK: no head -N truncation pipes in fleet-blind-audit
OK: panel #3680 gate: rejects bare find -mtime freshness findings, passes named-file findings
OK: fleet-blind-audit.test.sh
OK: all carriers extend PATH only when gh is missing
OK: stub gh stayed first (resolved: /tmp/tmp.4GPT5bsZzC/bin/gh)
OK: guard still extends PATH when gh is missing
PASS: app-token-mint-stub-respect
EXIT: 0
```

run-proof: `bash tests/fleet-blind-audit.test.sh` exits 0 on this branch in worktree `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-5654`; suite is P14-listed at `.github/workflows/ci.yml:156`.

research: n/a — test-only port of an already-reviewed fixture (claim/issue-5611 @ 2f121f698); no new bin/ file, no live-search needed. Compared: port verbatim vs re-derive — adopted verbatim port plus the 126-replay assertion the issue's accept bullets require.

help-first: n/a — no new tool; `bash tests/fleet-blind-audit.test.sh` is the existing P14 suite entry.

organ-heartbeat: tests/fleet-blind-audit.test.sh not-an-organ: test fixture file, not a running unit/timer/organ.

loose-ends: none — test-only PR, no live host edits.

Closes #5654
