# Observe-close for #7403 — judge cascade site deleted in the sweep; no surviving organ emits a flagship PR verdict

Issue #7403 (filed 2026-09-17, Jev epic #7370 "further uses" sibling, net 0.6)
asked for a Jev cascade at `pi-audit-run` / the senior ladder (judge group)
call path: before a flagship judge run, Jev answers `meets_accept_lines`
(score), `mergeable_as_is` (bool) and `claims_match_ci` (bool); outside the
uncertain band the verdict is Jev's, advisory-first with both verdicts
recorded for 100 PRs plus an agreement report and a prepaid-quota delta.

By the time this re-claim ran (2026-09-22), the site itself no longer exists.
This report is the resolution record, same convention as the #7399
observe-close (PR #8108).

## What was found

1. **The named site is deleted.** `d02760b53` ("fix(install): drop MANIFEST
   entries whose source file no longer exists", 2026-09-18 16:42 IST) removed
   `bin/pi-audit-run` (761 lines), `bin/pi-audit-tally` (534),
   `systemd/pi-audit@.service`, `systemd/pi-audit.slice`, its concurrency
   drop-in and 7 test files — 2,981 lines. `git merge-base --is-ancestor
   d02760b53 origin/main` passes; origin/main is `71049e973`.
2. **What the site judged was never what the acceptance prices.** The deleted
   header (`d02760b53^:bin/pi-audit-run`) reads "scout = the standard
   admission panel (PASS/FAIL)": it built a packet for a candidate *issue*
   and extracted PASS/FAIL admission votes through a seat ladder (devin /
   free-glm / `senior_seats_in_order`, LiteLLM `senior` group as documented
   fallback). The 2026-09-17 block on this issue already proved the mismatch
   at `dc5c8b6e`: no candidate-PR diff or CI results ever entered that call.
   The orchestrator DEP held: keep the original judge and original PR
   acceptance; no invented PR baseline or score mapping; #7371 owns the
   task-specific calibration contract.
3. **No surviving organ makes the equivalent call.** The `judge` model group
   still exists as router config (`config/litellm-proxy.yaml` `model_name:
   judge`; `config/pi-models.json` "LiteLLM judge group (senior ladder with
   proxy-owned fallbacks)") but its only consumer was the deleted
   audit/escalation pipeline (`pi-escalation-audit@` "Senior escalation panel
   vote" units — visible in `.fleet/bench7371/b-labels.jsonl` journal
   excerpts, absent from `systemd/`). Live check 2026-09-22 ~02:30 IST:
   `systemctl --user list-units` shows only the empty leftover slices
   `app-pi-escalation-audit.slice` / `app-unit-escalation.slice`; grep for a
   `judge`-group caller across `prompts/`, `systemd/`, `bin/`,
   `template/extensions/` finds only the `blocked-by-judge` PR label and
   router config. The spec-judge pass is also deleted (README records it;
   residual file removal is open PR #7777). The worker-packet step-8
   reviewer round is a review-*advice* subagent returning adjudication
   buckets — it emits no meets-accept/mergeable verdict object to shadow.
4. **The helper constraint survives but is moot.** `bin/jev-eval` was deleted
   in `47e2421a0` (2026-09-19) — Jev is now a LiteLLM pass-through
   (`POST 127.0.0.1:4000/jev`, proxy-owned $1/month cap and spend log; live:
   unauthenticated POST → 401, `litellm_deployment_state{typesafe-ai/jev}=0`).
   "Reuse the sibling helper, never a second client" maps onto the
   pass-through — but there is no call site to attach it to.
5. **The calibration contract #7371 owed this packet does not exist.**
   `docs/jev-benchmark-2026-09.md` scores only epic children 1–9 (A =
   review-gate NO-GO at every threshold; B = reserved-class NO-GO; children
   3, 5–9 missing evidence) and states "No child has a passing measured
   threshold. This packet does not file follow-up issues and does not wire a
   gate." Judge cascade is a "further uses" sibling, not one of the nine —
   no `meets_accept_lines`/`mergeable_as_is`/`claims_match_ci` replay, score
   range, or uncertain band was ever measured. Defining them now is exactly
   the invented score mapping the binding DEP forbids.
6. **The agreement report has no second term.** "Both recorded for 100 PRs"
   requires stored flagship verdicts; the audit judge emitted issue PASS/FAIL
   and no PR-verdict record exists anywhere to replay or shadow against.
   The cheap-decision slot on the surviving PR path is already occupied:
   `prompts/worker.md` step 7 wires Jev `needs_review` advisory through
   `/jev` (fleet-ops#7401, the "reviewer skip" sibling), logging to
   `~/.local/state/pi-packet/jev/reviewer-needs-review.jsonl`.

## Reconciled against the packet

- *Jev answers three typed questions before the flagship judge run*:
  impossible — the flagship judge run is deleted.
- *Uncertain band routes the verdict*: impossible — no measured band exists
  and inventing one is forbidden.
- *Advisory first, both recorded for 100 PRs, agreement report*: impossible
  — no site emits rows and no flagship verdict record exists to pair with.
- *Prepaid-quota delta reported*: moot — zero calls wired.
- *Termination: JSONL rows from the judge path*: no judge path emits rows.

## Residual path

If the fleet wants a Jev PR-merge cascade it is a NEW organ — Nish's explicit
yes is required before one is built (no-glue rule) — preceded by its own
task-specific benchmark over real PRs with recorded verdicts. Nothing here
claims that cascade is wanted; the newest authoritative act on the site is
its deletion.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7399 → #8108).
