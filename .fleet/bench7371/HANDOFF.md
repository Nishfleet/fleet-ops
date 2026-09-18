# Issue 7371 handoff, 2026-09-17T22:02Z (session 3)

Incomplete. No benchmark scores, PR, push, or gate change. Stopped under the
ten-minute acceptance stall rule at the next safe boundary (fleet-ops#6929),
after the q3/q4 acquisition fix. Stop advisory: jev-eval --site
benchmark-7371-stall, ref Nishfleet/fleet-ops#7371, stopWithHandoff p=0.91.

## Preserved state

Branch benchmark/issue-7371-clean = a48e0568b (based on origin/main ea98e470e).
Tree clean. Earlier sessions: 2e8c305 (salvage), 8fd42d9 (session-2 salvage).
The helper half (bin/jev-eval.mjs + tests/jev-eval.test.sh) is ALREADY LANDED on
origin/main via 9f4d08bfe (#7554, #7405); this packet keeps the benchmark half.
Host spend counter read $0.2234 at 21:52Z (shared usage, not packet spend).

## Valid evidence now on the branch

- a-cohort-certified.json, SHA256 fbbe36e5...d9b9 (unchanged): 200 merged 0509
  PRs before 2026-09-17T00:00Z, four quarters of 50, merge-ordered, unique.
- a-events-q1.json baf924fe... / a-events-q2.json 29ddbf6... (unchanged,
  valid): per-PR full event histories via issues/N/events, REST-only.
- a-events-q3.json 875f8dd8... and a-events-q4.json 0a9593e0... (this session,
  commit a48e0568b): REPLACEMENT event histories, same endpoint, same shape,
  complete=True, 0 errors, exact quarter membership asserted
  (issues/N/events?per_page=100, --paginate --slurp; 475 + 406 events).
  The earlier labels-snapshot attempt in this session was discarded: it fetched
  present labels, not label history, violating the events-API truth rule.
- a-truth-class3.json d4cdde99... (this session): deterministic class (iii)
  truth per PR from the certified cohort files (auth / payments /
  d1+migrations / .github/workflows / lockfiles): 51 of 200 PRs positive.

## Baseline sources pinned for A

- Current review-gate rules: Nishfleet/0509 .github/workflows/review-gate.yml
  at HEAD ea98e470 (fetched 21:56Z, /tmp/7371-0509-review-gate.yml, 134 lines).
  Python classifier: CRITICAL/BROAD/LOCKFILES/DOCS hints, churn, budget bar
  (0.5/0.85 of cap 30) -> review:deep flag decision per PR.
- Class (iii) truth: a-truth-class3.json (above). Class (i): label events
  present across all four quarter files (q1/q2 recorded zero review:deep
  events; q3/q4 histories now enumerable). Class (ii): outcome events/issues/
  PRs citing the merge SHA within 7 days of merge - NOT yet acquired; the last
  7-day window ends 2026-09-21T18:32:08Z, so final A truth waits regardless.

## Not yet done (next session, in order)

1. Class (ii) acquisition: for each PR, post-merge outcome search (issues/PRs
   citing merge SHA or PR number within 7d; deploy-fault/repair:red classes).
2. Baseline: implement the pinned review-gate classifier offline over the 200
   cohort rows; report its flag rate alongside Jev thresholds.
3. Replays: Jev on title+body+file list+diffstat, questions needsDeepReview
   (boolean), riskClass (choice), blastRadius (score 0-4); four quarters, rows
   tagged with quarter; live receipts under a 7371 benchmark site.
4. Benchmark B acquisition: closed fleet-ops + 0509 issues with label events
   nish-reserved / question / escalate-senior / needs-orchestrator (newest
   first, up to 200) + 100 random closed controls (no such events); pre-decision
   text = title+body+comments BEFORE first nish3451 or decision-resolved
   comment; blind labels from canonical reserved classes; independent 30%
   relabel by reviewer subagent; disagreement > 15% is itself a no-go.
5. Report docs/jev-benchmark-2026-09.md (fixed cohort list, precision/recall/
   flag-rate at p>=0.5/0.7/0.9, calibration buckets, latency p50/p95, cost per
   1k, child go/no-go at measured thresholds, spend before/after). No gate wiring.

mechanism-impossible: final seven-day outcome labels for benchmark A cannot be
certified before 2026-09-21T18:32:08Z. Acquisition, baseline, replays, and all
of B do not wait on that window.
