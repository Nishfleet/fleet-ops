# Observe-close for #7553 — the intake-tier 200-row comparison is unreachable: the observation site was deleted before rows could accumulate

Issue #7553 (Jev epic #7370 child, follow-up to #7405, "intake tier advice:
compare 200 real outcome-linked rows before activation") asked for the
pre-activation comparison for the intake tier shadow: at least 200 real,
non-synthetic `pi-intake-tier` observations joined to actual run outcomes
(OOM, timeout, empty run) by issue, unit and observation time; replays
without a matched run and duplicate observations of the same run excluded;
missing outcomes and cohort counts reported; the normal-tier mapping and
measured thresholds reviewed; and an explicit go/no-go before any config
flip. Acceptance: a checked-in report citing the actual records, a reviewed
mapping and explicit go/no-go — no activation merely because 200 rows
exist.

By the time this run executed (2026-09-22), the observation site no longer
exists and zero rows have ever persisted on this host. This report is the
resolution record, same convention as the #7403, #7399 and #7405
observe-closes (PRs #8111, #8108, #8115).

## What was found

1. **The site shipped, then was swept four days before this run.** PR #7554
   (merged 2026-09-17T20:43:41Z) added `jev_tier_log()` to
   `lib/pi-intake-tick.sh`: one `bin/jev-eval` call per claimed issue asking
   `tier` (choice: light/normal/heavy/keystone) and `privacy` (choice:
   public/private), each row joining Jev's probabilities to the same
   `issue_difficulty()` pass's answer in
   `~/.local/state/pi-packet/jev/pi-intake-tier-observations.jsonl`, behind
   rollback flag `PI_INTAKE_JEV_TIER=0`.
2. **Logger, heuristic and consumer deleted in one commit.** `ca33faa96`
   ("refactor(rail): the unit IS the worker — collapse intake/worker/scout
   to pi --print", 2026-09-18) removed `lib/pi-intake-tick.sh` (3,320 lines)
   with the entire `lib/` tree — `issue_difficulty()` (the heuristic the
   advice was logged beside), `jev_tier_log()` (the logger), and the second
   intake Jev site `pi-intake-acquisition-rank`. The heuristic fed
   `packet_difficulty()` in the likewise-deleted `lib/litellm-seat.sh`.
   Verified this run: `git merge-base --is-ancestor ca33faa96 origin/main`
   passes; origin/main is `12cfacbd4`. A `git grep` for
   `jev_tier_log`/`pi-intake-tier-observations` on origin/main matches only
   the #7405 observe-close record.
3. **The helper is gone too.** `47e2421a0` ("cut(jev): register Jev as a
   LiteLLM pass-through, delete the Node helper", 2026-09-19) removed
   `bin/jev-eval`; Jev calls are now `POST 127.0.0.1:4000/jev` under the
   proxy-owned `jev-eval` virtual key. Verified ancestor of origin/main.
4. **No surviving organ makes the call.** Intake is now a Pi session —
   `pi --print --provider litellm --model worker-cheap` running
   `prompts/intake.md`. Its only per-issue choice is an engine ladder on
   live unit counts (devin<5 → cursor<3 → pi), not a difficulty assessment,
   and the prompt carries no tier question. Every unit hardwires its model
   (`pi-issue@` → worker-capable, `pi-intake@` → worker-cheap,
   `devin-issue@` → swe-2-max, `cursor-issue@` → cursor-grok-4.6-high). The
   seat-group consumer the tier fed has no consumer and no config surface —
   nothing exists to flip.
5. **The row log is absent — population zero.** Live listing this run
   (2026-09-22 ~04:15 IST): `~/.local/state/pi-packet/jev/` holds 16 site
   files — alert-dispatch 3, alert-repair 1, alert-triage 3, auto-revert 2,
   claim-check-pr 14, claim-check-report 15, dependency-pr-arm 1,
   fleet-weekly-review-triage 1, gha-stuck-run-watch 2, hermes-digest 22,
   merge-queue-batches 1, merge-queue-enqueue 17, reviewer-needs-review 21,
   scout 13, second-opinion-reserved 12, worker-context 11 — and no
   `pi-intake-tier-observations.jsonl`. Even the two delivered rows recorded
   in the #7405 observe-close (function proof 2026-09-17T20:27:24Z: light
   p=0.66, public p=0.66; live intake-tick row 2026-09-17T20:52:24Z: light
   p=0.74, public p=0.60, advisory_only=true, synthetic=false,
   dry_run=false, state_sha256=6ac64307…0c30) no longer exist on disk; they
   are cited here from that record, not from the log.

## The join, run honestly

The issue's comparison joins observations (left side) to worker outcome
records (right side). The left side has **0 rows**:

| cohort | rows |
|---|---|
| observations joined to a matched run | 0 |
| replays without a matched run (excluded) | 0 |
| duplicate observations of one run (excluded) | 0 |
| outcomes: OOM / timeout / empty-run / normal | 0 / 0 / 0 / 0 |
| missing-outcome share | undefined — no observations exist to lack outcomes |

Worker outcome records exist in the systemd journal, but there is nothing
to join them to. The "at least 200" precondition is not merely unmet — it
is unreachable: the row source is deleted, so the count is 0 and stays 0.

## Normal-tier mapping review

The deleted mapping, end to end: `issue_difficulty()` classified the issue
light/normal/heavy from labels/title/body; `jev_tier_log()` logged Jev's
`tier` (light/normal/heavy/keystone) and `privacy` (public/private) answers
beside it; the heuristic answer fed `packet_difficulty()` in
`lib/litellm-seat.sh`, which selected the `litellm_seat` group. All three
layers are deleted; today each unit hardwires a single model, so neither
the heuristic nor the advice has a consumer.

Measured thresholds: none were ever recorded for this site — the 200-row
benchmark that would have produced them can never run. The standing act
bands remain the `JEV_CASCADE_HI`/`_LO` defaults (0.9/0.1) per
`docs/jev-cascade.md`: "a band a benchmark did not measure is not a band."

## Verdict

**NO-GO** — permanent, by construction. Activation would require the site
to exist and emit outcome-linkable rows; the logger, the heuristic it
shadowed, the helper it called and the seat-group consumer it fed are all
deleted. This is not "200 rows not yet reached": no rows can accumulate.
No activation is proposed and none is possible against the shipped tree.
Privacy rules, routing caps and review gates are untouched — nothing ships
but this record.

## Contract carried forward

The comparison contract itself survives on the live shadow sites per
`docs/jev-cascade.md`, and per-site scoring of the existing shadow logs
against real outcomes is already tracked under fleet-ops#7754 — rescoping
this issue to a live site would duplicate it, so no new issue is filed.
Each live site keeps its own flip bar: merge-queue-enqueue waits on the
review-gate benchmark's go row (#7371, re-run #7909); dependency-pr-arm
needs 50 real dependency-PR rows; claim-check stays `blocking=false` until
100 labelled rows show ≥95% precision (#7754 scores it).

## Residual path

If a per-issue tier or seat-group decision point is ever reintroduced, the
shadow attaches via the `/jev` pass-through under the cascade pattern in
`docs/jev-cascade.md` — a new organ requiring Nish's explicit yes (no-glue
rule), preceded by its own benchmark over real outcome-linked rows. The
newest authoritative act on this site is its deletion.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7403 → #8111,
fleet-ops#7399 → #8108, fleet-ops#7405 → #8115).
