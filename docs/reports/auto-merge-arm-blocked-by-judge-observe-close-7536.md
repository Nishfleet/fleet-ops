# Observe-close for #7536 — the auto-merge-arm workflow armed #7535 through a label list that never knew blocked-by-judge; the path is deleted in #7861

Issue #7536 (filed 2026-09-17 during the #7501 closeout) observed that fleet-ops
PR #7535 was created with `blocked-by-judge` and `needs-orchestrator` in the
creation command, no worker arm command was issued, yet a REST read showed
`auto_merge` set to squash. It asked which existing arming path enabled it and
for the existing #4557 rule to be enforced there. By the time this claim ran
(2026-09-22 IST), the arming path itself no longer exists; this report is the
identification and resolution record, same convention as the #7426 observe-close
(PR #8114) and the #7399/#7403 observe-closes (#8108/#8111).

## Which arming path enabled it

`.github/workflows/auto-merge-arm.yml` calling
`.github/workflows/reusable-auto-merge-arm.yml` — run **35264899945**, fired on
`pull_request: opened` at 2026-09-17T19:26:30Z on head `c55154eb4` (the exact
head the issue cites), conclusion `success`. The PR timeline records the labels
applied at 19:26:29 and `auto_squash_enabled` at 19:26:52 by
`nishfleet-worker[bot]` — the App token that workflow mints via
`actions/create-github-app-token` (fleet-ops#1469: an App actor so push
workflows still fire, without making Nish the merge actor).

The worker transcript
(`~/.pi/agent/sessions/pi-issue-fleet-ops-7501/2026-09-17T18-52-22-555Z_*.jsonl`)
contains only `gh pr create --label blocked-by-judge --label needs-orchestrator`
and the later `gh pr merge 7535 --disable-auto` — no arm command, matching the
issue's claim.

## Why the #4557 rule did not fire there

The reusable workflow's arm gate was exactly:

```
if: draft == false
    && !contains(title, '[no-merge]')
    && !contains(join(labels.*.name, ','), 'no-auto-merge')
```

plus the stop-the-line freeze check, the quality-ceiling check and the
gate-integrity guard. `blocked-by-judge` is absent from every one of them.

The workflow was **added** in `efb743c7` (PR #4070, 2026-09-08 04:46 IST) and
the #4557 teeth landed ~14h later in `76d23e31` (PR #4564, 2026-09-08 18:58
UTC). #4557 instrumented the *fleet-local* arming surface —
`bin/fleet-judge-block-gate` (refuse + disarm seam), the fleet-heartbeat-tier1
hourly pass, the gh-webhook `labeled` dispatcher — and the worker prompt. The
GitHub-Actions armer, a parallel path with its own opt-out list, was never
updated. Every PR created already carrying `blocked-by-judge` between
2026-09-08 and the workflow's deletion was armed on `opened`; #7535 and #7724
are the two observed instances.

## What enforces the rule now

1. **The identified path is deleted.** `ca67f570` ("cut(ci): drop detector
   scripts, their workflows, and the P14 suite (#7861)", merged 2026-09-19
   17:37 UTC) removed `auto-merge-arm.yml`, `reusable-auto-merge-arm.yml`,
   `enqueue-green-prs.mjs`, `repair-queue-jump.mjs` and the template copy
   `template/.github/workflows/auto-merge-arm.yml`. `git merge-base
   --is-ancestor ca67f570 origin/main` passes at origin/main `1fe30a841`.
   Deletion is the strongest form of "refuse the arm" — the path cannot arm
   anything, labeled or not.
2. **The other #4557 organs are deleted too.** `bin/fleet-judge-block-gate`,
   the tier1 hourly pass and the gh-webhook receiver went out in the 2026-09
   sweeps (`3cec2df61` "delete the gh-webhook organ", 2026-09-18, and the
   surrounding cut commits). No systemd unit, timer or cron entry on this host
   enables auto-merge today (`systemctl --user list-unit-files`, `list-timers`,
   `crontab -l` — all clean of merge/arm/queue/judge machinery).
3. **The surviving arm site already carries the rule.** Worker packet step 9
   (`prompts/worker.md`, mirrored in `AGENTS.md`) is now the only place a fleet
   actor arms a PR, and it refuses while `blocked-by-judge` is present. This PR
   corrects its one stale clause, which still claimed the deleted tier1 pass
   disarms labeled PRs hourly — it now says the disarm is the worker's own
   same-step duty.
4. **The live violation is cleared.** PR #7724 (the #7535 reopen for #7501,
   still carrying `blocked-by-judge`) had been armed by the same workflow at
   2026-09-18T10:51:58Z — 81s after the label — and was still armed when this
   claim ran. `gh pr merge 7724 --disable-auto` now verifies
   `auto_merge:null` with the label intact (2026-09-22 ~03:45 IST).

## Residual exposure — outside this issue's repo scope

`gh search code --owner Nishfleet` finds **live vendored copies** of the same
armer, missing the same opt-out, on three sibling-repo mains:

- `Nishfleet/aiconverter-app` — `.github/workflows/auto-merge-arm.yml` (last
  run 2026-09-19T08:09:14Z, success)
- `Nishfleet/inish-site` — same path (last run 2026-09-19T08:09:20Z, success)
- `Nishfleet/tinystudio-in` — same path (last run 2026-09-18T16:11:04Z)

Each runs `gh pr merge --auto --squash` on `pull_request: [opened,
ready_for_review]` with only draft/`no-auto-merge`/`[no-merge]` opt-outs. None
of the three currently has an open `blocked-by-judge` PR, so nothing armed is
waiting, but the next judge-labeled PR in any of them reproduces #7535.
Filed as **fleet-ops#8136** (plain issue, per the file-extras-as-new-issues
rule).

## Reconciled against the issue

- *"Identify which existing arming path enabled it"*: done —
  `auto-merge-arm.yml`/`reusable-auto-merge-arm.yml`, proven by workflow run
  35264899945 timestamped one second after the label event on the cited head,
  and by the absent arm command in the worker transcript.
- *"Enforce the existing #4557 rule there"*: the site no longer exists —
  deleted in #7861; the surviving arm site (worker step 9) carries the refusal
  and now carries an accurate disarm instruction instead of a pointer to a
  deleted sweep.
- *"Do not merge #7535 until its acceptance mismatch is resolved"*: #7535 was
  already closed 2026-09-18 (head deleted); its successor #7724 stays
  un-merged, un-armed and labeled, pending the authorized reviewer.
- *"No new timer or guard requested"*: none added — one report, one prose
  correction, one live disarm, one filed follow-up.

## Related stale prose (noted, not edited here)

Step 9's verify-receipt clause still says an armed receipt-less PR "gets
`gh pr merge --disable-auto` from the exec-review canary" — that organ was
also deleted in the sweeps; the receipt requirement stands as a body-contract
rule but nothing mechanical enforces it. Same class of stale claim as the
tier1 clause corrected here; flagged for the next worker.md pass.

mechanism: the sweep deleted the offending arming path itself — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7399 → #8108,
fleet-ops#7426 → #8114); live state repaired (PR #7724 disarmed) and residual
sibling exposure filed as fleet-ops#8136.
