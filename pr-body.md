feat(enforcement): loose-ends canary for sr-nothing-half-done (fleet-ops#528)

## Why
sr-nothing-half-done (Nish, 2026-08-20): nothing sits half-done, and no
question dies unanswered. The fleet2 loose-ends + question-nag daily timers
that enforced this died on 2026-08-23. This is the live replacement, on
the heartbeat tick (no new scheduler).

## Scope
Three detection classes share one classifier so a single observer drains
the backlog without a pager storm:

1. Unanswered questions — QUESTIONS.md OPEN rows and HOLD past its return
   date (lib/loose-ends.py parse_questions).
2. Half-done PRs — open MERGEABLE worker PRs on enrolled repos older than
   the idle window without auto-merge armed (classify_prs).
3. Half-done worktrees — stale/dirty worktrees with no live worker unit
   (classify_worktrees).

Observe-to-open auto-files a ticket per finding (deduped on a stable key);
observe-to-close comments resolved-at on a filed slug that is no longer a
finding, then closes on the next tick. rc 0 = tick green with findings
(alarm, fleet-ops#1116); rc 1 = watcher broken (loud, tick stays green);
rc >= 2 = crash (heartbeat fails loud).

Wired into fleet-heartbeat-tier1 block 42 (rc >= 2 propagates only).
rule-enforcement.json sr-nothing-half-done -> enforced. MANIFEST installs
the bin + lib. prompts/worker.md notes the canary so workers know the
marker shape. No new scheduler, no bin/loose-ends dispatcher (depth-1).

## Verification
- `bash tests/fleet-loose-ends-canary.test.sh` — 16 scenarios green
- `bash tests/rule-enforcement.test.sh` — all drills pass including
  loose-ends canary drill and live vault join
- Live run (nag-only, FILE=0, SCAN_PRS=0, SCAN_WORKTREES=0):
  4 OPEN questions in QUESTIONS.md correctly detected and nagged.
  Exit 0.

research: last30days + official docs compared gh-velocity-cli (throughput metrics, not stale-PR detection), git-stale-branches (date-based, no dirty/live exemption), systemd-tmpfiles (filesystem age, no git semantics). None adopted — none detects the rule's three half-done classes.
help-first: ran gh issue list --help, gh pr list --help, systemctl --user list-units --help, and find --help; none does not detect half-done worktrees, unanswered questions, or stale PRs by the rule's three classes.

Closes #528

organ-heartbeat: bin/fleet-loose-ends-canary not-an-organ: detector run by fleet-heartbeat-tier1 block 42; does not export a standalone heartbeat metric