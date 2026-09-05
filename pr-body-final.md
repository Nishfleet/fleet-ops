Trim `prompts/worker.md` from 271 lines / ~32 KB to 36 lines (well under
the <= 80-line ceiling, fleet-ops#3245, child of #3120). The trim keeps the
essential contract: identity + token note, hard rules (never close/merge/
push main, no attribution, stay in scope, flag failed commands), workspace
steps, Execution-IS-the-review loop, PR body contract, auto-merge arm, the
final PR-URL line, and the two single-session-waste lines (the ≤80-line
ceiling itself lives in `tests/worker-prompt-size-ceiling.test.sh`).

The trim on its own red'd the suite: the fleet-failed-command tests still
pinned the full failed-command case enumeration inside worker.md, which a
<=80-line prompt cannot carry. This PR re-lands the companion migration
(fleet-ops#3246; PR #3307 was spurious-closed unmerged) so the two compose:
- the 24 enumerate-test "prompt-side lock" sections now grep
  `lib/failed-command-flagged.py`'s docstring (the detector is the
  enforcement, not the prompt); the 7 rule-sentence locks that must stay in
  worker.md are untouched.
- 7 live-case wordings added to the lib docstring so the repointed greps
  match.

Mechanism (fleet-ops#366): `tests/worker-prompt-size-ceiling.test.sh` asserts
worker.md stays <= 80 lines; the repoint is regression-covered by the 24
repointed tests themselves (verified below).

Verification:
```
$ bash tests/worker-prompt-size-ceiling.test.sh
OK: worker packet is 6308B, under 32768B ceiling
OK: worker.md is 36 lines, under 80-line ceiling
OK: longest worker.md line is 620B, under 4096B per-line cap
OK: core failed-command rule, no-match-probe exception, and lint pointer all present
worker-prompt-size-ceiling: PASS
```
```
$ bash tests/worker-packet-size.test.sh
worker-packet-size: PASS (drill green; live check reports 6308B non-0509 / 6296B 0509; ENFORCE=0)
```
```
$ bash tests/seat-lib.test.sh   # P14 host that runs all 24 enumerate tests
seat-lib exit=0 (ALL green)
```
```
$ bash tests/fleet-failed-command-read-enoent-thinking.test.sh   # the test CI red'd on
OK: lib/failed-command-flagged.py cites fleet-ops#953 and the live ENOENT wording
OK: lib/failed-command-flagged.py cites fleet-ops#1001 and the live stale-checkout path
OK: lib/failed-command-flagged.py docstring cites fleet-ops#1001, #1100, #1255
OK: fleet-failed-command-read-enoent-thinking: live #953 / #1001 drills
```
Also verified green: worker-prompt-systemd-run, pstack-worker-prompt,
pi-intake-run, pi-issue-start, no-agent-names, token-efficiency,
wipe-lessons scan, prove-one-run (net -219 lines). No net assertion drop
across the 24 repointed tests (gate-integrity net-delta 0).

run-proof: transcripts above — size-ceiling PASS (exit 0), seat-lib
exit 0, read-enoent-thinking PASS.

net-positive-because: 235 lines and ~26 KB of prompt context removed from
every worker packet while keeping the failed-command suite's enforcement
(now asserted against the detector docstring where the case law lives).

Closes #3245
