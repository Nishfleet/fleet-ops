## Summary

observe-to-close (`bin/fleet-merged-pr-close`, fleet-ops#1435) treated **any** merged PR that merely referenced an open issue by `#N` (in title **or** body) as the delivery and closed it. On 2026-09-04 PR #3205 implemented #3161 only, but its body carried prose references to `fleet-ops#3140 and #3146` (they had `blocked-on: #3161` upstream) — so the detector read those bare mentions as two more deliveries and wrongly closed both Nish-endorsed critical-path packets. **A mention is not a fix.**

Root cause: the delivery signal was "any reference", too weak. The fix narrows closing to explicit deliveries only, decouples mentions from closes, and protects Nish-critical issues.

### Change

- **Close only on an explicit delivery.** observe-to-close now closes an issue **only** when a merged PR is a delivery for it: (a) its head branch is `claim/issue-<N>`, or (b) its body carries an explicit `Closes|Fixes|Resolves #N` trailer (case-insensitive, exact-number bounded, whitespace gap required). `reason=claim-branch | closes-trailer`.
- **A bare reference never closes.** A title/prose mention, a `blocked-on:` line, a comment, or quoted text is **comment-only**: a deduped `PR #M mentions this issue; not closing (a mention is not a fix)` note, never a close.
- **Protected issues are always comment-only**, even on a real delivery — any issue labelled `critical-path` or authored by `nish3451` (the same rule close-duplicates follows, fleet-ops#3161). This is what would have saved #3140/#3146. They stay open until their own delivery PR merges and closes them.
- **Metric + alert tripwire.** Per-tick `closes_by_reason` summary is written by the detector and exported as `fleet_observe_to_close_total{reason}` (legal: `claim-branch`, `closes-trailer`; `bare-mention` and `protected` must stay 0). New rules `FleetObserveToCloseWrongClose` (critical: fires if a mention- or protected-close ever recurs) and `FleetObserveToCloseAbsent` (warning).
- **Latent newline-split fix.** The merged-PR window projection normalizes embedded newlines in titles/bodies before TSV flattening, so a real multi-line `Closes #N` trailer (always on its own final line) is read on one row instead of being split across rows and corrupted. This was silently present before; the trailer path makes it load-bearing.

### Mechanical prevention

A regression-replay test in `tests/fleet-merged-pr-close.test.sh` replays **PR #3205 vs issues #3140/#3146/#3161** and proves **only 3161 closes**: 3140/3146 get the protected note and stay open. Additional cases prove a bare mention / `blocked-on:` line never closes, protected issues never close even on a claim-branch delivery, and mention notes are deduped across ticks. The metric/alert tripwire fires if the wrong-close class ever recurs.

## Verification

Failing first (old behavior) then passing (fixed), on the hermetic mock: `bash tests/fleet-merged-pr-close.test.sh` -> `all fleet-merged-pr-close cases passed` (exit 0). The regression case asserts `issue close 3161` present and `issue close 3140`/`issue close 3146` ABSENT from the mock close log, plus the protected notes posted.

- `bash tests/fleet-metrics-export.test.sh` -> `fleet-ops#3231: fleet_observe_to_close_total{reason} emitted (missing/legit/wrong/unparseable)` (exit 0).
- `promtool check rules config/fleet_rules.yml` -> `SUCCESS: 81 rules found` (exit 0).
- `sgscan --base origin/main` -> `No new security findings.` (exit 0).
- `bin/fleet-organ-heartbeat-check gate` -> `OK: organ-heartbeat invariant holds (touched organs: gh-rate-limit, metrics-export)` (exit 0).
- `bin/fleet-token-efficiency-check`, `bin/fleet-no-agent-names-check`, `bin/fleet-wipe-lessons-check scan` -> all `OK` (exit 0).
- Live E2E of the actual binary against the real repo in close-OFF (non-destructive) mode -> `merged-pr observe-to-close done: scanned=12 candidates=0 closed=0 ... skipped_protected=1`, exit 0. It classified the delivered critical-path packet #3229 as `PROTECTED-delivery candidate ... no write` — the old binary would have closed it today.

run-proof: live transcript, `timeout 180 env MERGED_PR_CLOSE_REPOS=Nishfleet/fleet-ops MERGED_PR_CLOSE_SUMMARY=/tmp/mpc-live-summary.json MERGED_PR_CLOSE_TRIAGE=/tmp/mpc-live-triage.md ./bin/fleet-merged-pr-close` -> exit 0; key lines:
```
[2026-09-04T15:13:18Z] [fleet-merged-pr-close]   Nishfleet/fleet-ops#3229: PROTECTED-delivery candidate (merged PR #3233) but FLEET_MERGED_PR_CLOSE_OK != 1 — no write
[2026-09-04T15:13:18Z] [fleet-merged-pr-close] merged-pr observe-to-close done: scanned=12 candidates=0 closed=0 ... skipped_mention=0 skipped_protected=1
```
summary written: `{"closes_by_reason":{"claim-branch":0,"closes-trailer":0,"bare-mention":0,"protected":0}}`.

Notes: `crgate` exists but is not signed in on this host (CodeRabbit auth needs a paid account — out of scope), so the local AI-review gate was skipped; `sgscan` (the defensive gate) passed clean.

loose-ends-canary: pr:nishfleet/fleet-ops#3231 stale-worker-pr (armed on open)

Closes #3231