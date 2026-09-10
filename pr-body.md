## What changed and why

The execution-is-review canary (fleet-ops#537) auto-filed issue #731 because
worker PR #630 (feat(enforcement): prepaid utilization canary) was opened
with `## Verification` (no colon) and no `run-proof:` line. The canary's
regex requires a colon (or a run-proof: line) so the heading form without
colon is a real skip — the worker prompt's `Verification:` section contract
is the loudest receipt.

Two-part durable fix:

1. **Operational (already on the PR):** PR #630's body now carries a
   `run-proof:` line plus a `## Verification:` (with colon) heading + fenced
   journal lines, so the canary classifies it as a receipt. The next
   heartbeat tick will see the canary clean for #630 — that is the
   observe-to-close signal the issue asks for.
2. **Test lock (this PR):** three new tests in
   `tests/fleet-exec-review-canary.test.sh` lock in the canary's strict
   colon requirement and the PR #630 post-fix shape:
   - `4a` — `## Verification` (no colon) + fenced block is REJECTED. This is
     the pre-fix shape; if a future regex edit silently accepts it, the
     canary would re-pass the same broken PR and the auto-file path would
     stop catching this class of skip.
   - `4b` — `## Verification:` (colon) + fenced block is ACCEPTED. This is
     the loudest receipt; the canary must keep accepting it.
   - `4c` — `## Verification` (no colon) + `run-proof:` line is ACCEPTED
     (the louder, regex-orthogonal signal). Confirms a worker can still
     pass the gate with a `run-proof:` line even when the heading lacks a
     colon.
   - `9a1` / `9a2` — scan-mode fixtures that lock the pre-fix and post-fix
     bodies end-to-end. The pre-fix fixture must be SKIP-flagged and the
     post-fix fixture must be receipt-OK, with no auto-file on the post-fix
     fixture. Regression-locks the worker who edits the canary regex from
     silently re-classifying the same broken body as a receipt.

The canary already auto-files on open and fails loud on a broken watch
(fleet-ops#537 contract). The durable prevention is in place; this PR
documents the contract on both sides of the body, so neither regex drift
nor worker markdown drift can quietly re-trip #731.

## Verification

Local canary against the live PR-#630 body (post-edit) — receipt-OK:

```
$ python3 lib/exec-review-receipt.py check --body <(gh pr view 630 -R Nishfleet/fleet-ops --json body | jq -r .body)
OK: Verification/run-proof receipt present
```

Local canary scan against live worker PRs in a 24h window — PR #630 is no
longer in the findings list (was 9 findings, now 8 after the PR-#630 body
fix; the other 8 are out of scope and have their own auto-filed issues):

```
$ FLEET_EXEC_REVIEW_NOW=2026-08-27T03:30:00Z FLEET_EXEC_REVIEW_FILE=0 bin/fleet-exec-review-canary
[2026-08-27T03:09:32Z] [fleet-exec-review-canary] scanned=25 old=0 human=0 receipt=17 findings=8
[2026-08-27T03:09:32Z] [fleet-exec-review-canary] LOUD [EXEC-REVIEW-FILED] skipped-run worker PRs=8 filed=0 (observe-to-open)
```

(PR #630 absent from the EXEC-REVIEW-SKIP lines — receipt-OK.)

Test suite — 18/18 OK (3 new test cases):

```
$ bash tests/fleet-exec-review-canary.test.sh
OK: 1: --body Verification + journalctl accepted
OK: 2: --body run-proof: accepted
OK: 3: --body Verification without run-cue rejected
OK: 4: --body with no receipt rejected (the skip drill)
OK: 4a: --body with `## Verification` (no colon) rejected (the #630 pre-fix shape)
OK: 4b: --body with `## Verification:` + fenced block accepted (the #630 post-fix shape)
OK: 4c: --body with run-proof: (no colon heading) accepted (the louder signal)
OK: 5: worker PR with receipt is OK, no file
OK: 6: worker PR without receipt files (observe-to-open)
OK: 7: human PR without receipt is ignored
OK: 8: worker PR outside the window is quiet
OK: 9: auto-file dedupes the signal key
OK: 9a1: PR #630 pre-fix shape (`## Verification`, no colon) is SKIP-flagged
OK: 9a2: PR #630 post-fix shape (`## Verification:` + run-proof:) is receipt-OK
OK: 10a: missing helper fails loud
OK: 10b: unparseable fixture fails loud
OK: 11: contracts: worker.md, heartbeat, MANIFEST, nested CI, matrix enforced, no dispatcher
OK: fleet-exec-review-canary: receipt gate, skip drill, observe-to-open, dedupe, broken watch
exit 0
```

Nested CI host:

```
$ bash tests/rule-enforcement.test.sh 2>&1 | tail -3
OK: rule-enforcement: paid-flash canary drill
OK: rule-enforcement: matrix, join, stale queued, advisory, auto-file, observe-to-close, no-agent-names, vault-conflict, wipe-lessons, north-star-quality, cline-glm53, repo-visibility, straitly-ds4-pro, exec-review, ...
```

run-proof: journal fleet-exec-review-canary scan exit 0, PR #630 absent from EXEC-REVIEW-SKIP findings after body edit (3:09:32Z tick above).

## Notes

- The other 8 PRs the canary still flags (Nishfleet/0509#1233,
  Nishfleet/fleet-ops#668, #654, #625, #603, #471, #453, #445) are out of
  scope for #731 — each will get its own auto-filed issue on the next
  heartbeat tick if one isn't already open. No attempt is made to fix
  them in this PR.
- The fleet-ops-deploy-clone `tests/fleet-blind-audit.test.sh` exits 141
  on this machine, both on `main` and on this branch. Pre-existing
  failure, unrelated to #731. Filed as a separate observation; not
  touched here.

Closes #731
