# Observe-close for #7405 — intake tier site deleted in the rail cut; the heuristic it shadowed no longer exists

Issue #7405 (filed 2026-09-17, Jev epic #7370 child, "cheapest-capable seat
choice per packet", saving 2.1 / effort 1.7) asked for Jev's
light/normal/heavy/keystone × public/private choice with probabilities, logged
beside the intake difficulty heuristic, with a config flip after 200 rows were
compared against real run outcomes (OOM, timeouts, empty runs). Named site:
"pi-intake difficulty/tier assignment feeding litellm_seat group choice".
`termination:` = "next intake tick logs the jev tier per issue".

By the time this re-claim ran (2026-09-22), the site itself no longer exists.
This report is the resolution record, same convention as the #7403 and #7399
observe-closes (PRs #8111, #8108).

## What was found

1. **Delivery landed and the termination event fired before the cut.** PR
   #7554 (merged 2026-09-17T20:43:41Z, +111 lines across
   `lib/pi-intake-tick.sh` and `tests/pi-intake-tick-difficulty-from-issue.test.sh`)
   added `jev_tier_log()`: one `bin/jev-eval` call per claimed issue asking
   `tier` (choice: light/normal/heavy/keystone) and `privacy` (choice:
   public/private), each row joining Jev's probabilities to the same
   `issue_difficulty()` pass's answer in
   `~/.local/state/pi-packet/jev/pi-intake-tier-observations.jsonl`, behind
   rollback flag `PI_INTAKE_JEV_TIER=0`. Real records on this very issue:
   a function proof at 2026-09-17T20:27:24Z (fleet-ops#7405: light p=0.66,
   public p=0.66) and a live intake-tick row at 2026-09-17T20:52:24Z
   (light p=0.74, public p=0.60; advisory_only=true, synthetic=false,
   dry_run=false; state_sha256=6ac64307…0c30), paired to claim comment
   5721066874 and the `pi-intake@fleet-ops.service` journal finish at
   20:52:41Z. The `termination:` clause fired with that row.
2. **The named site is deleted.** `ca33faa96` ("refactor(rail): the unit IS
   the worker — collapse intake/worker/scout to pi --print", 2026-09-18
   16:39 IST) removed `lib/pi-intake-tick.sh` (3,320 lines) with the entire
   `lib/` tree — `issue_difficulty()` (the heuristic the advice was logged
   beside), `jev_tier_log()` (the logger), and a second intake Jev site
   (`pi-intake-acquisition-rank`, default-off) in the same commit. The
   heuristic fed `packet_difficulty()` in the likewise-deleted
   `lib/litellm-seat.sh`. `git merge-base --is-ancestor ca33faa96
   origin/main` passes; origin/main is `ee10d8ec8`.
3. **No surviving organ makes the call.** Intake is now a Pi session —
   `pi --print --provider litellm --model worker-cheap` running
   `prompts/intake.md`. Its only per-issue choice is an engine ladder on live
   unit counts (devin<5 → cursor<3 → pi), not a difficulty assessment, and
   the prompt contains no tier question. Every unit hardwires its model:
   `pi-issue@` → `worker-capable`, `pi-intake@` → `worker-cheap`,
   `devin-issue@` → `swe-2-max`, `cursor-issue@` → `cursor-grok-4.6-high`
   (`--model` grep across `systemd/*.service`, 2026-09-22). The
   "litellm_seat group choice" the tier fed has no consumer.
4. **The helper constraint is moot.** `bin/jev-eval` was deleted in
   `47e2421a0` ("cut(jev): register Jev as a LiteLLM pass-through, delete the
   Node helper", 2026-09-19); Jev calls are now
   `POST 127.0.0.1:4000/jev` under the proxy-owned `jev-eval` virtual key
   ($1/month cap). "Reuse the sibling helper, never a second client" maps
   onto the pass-through — but there is no call site to attach it to.
5. **The row log is gone.** Live listing 2026-09-22 ~02:40 IST:
   `~/.local/state/pi-packet/jev/` holds only the current sites' files
   (alert-dispatch, auto-revert, fleet-weekly-review-triage,
   gha-stuck-run-watch, hermes-digest, merge-queue-enqueue,
   reviewer-needs-review); `pi-intake-tier-observations.jsonl` is absent —
   even the delivered rows no longer exist on the host.
6. **The flip half of accept is unreachable by construction.** Activation
   needed 200 real outcome-linked rows and a consumer to flip; the site
   emits no rows and there is no tier consumer or config surface in the
   shipped tree. The 2026-09-18 `decision-resolved:` on this issue ("lets do
   all then" — the router/gate/judge/preflight/compaction in-the-loop plan,
   shadow first) does not name the intake-tier site; it is the doctrine the
   surviving sites already follow. The 200-row comparison contract lives on
   in #7553 (open, agent-ready), whose precondition — a live site emitting
   outcome-linkable rows — no longer holds; flagged there.

## Reconciled against the packet

- *Jev choice light/normal/heavy/keystone × public/private with p, logged
  beside the heuristic*: delivered by #7554 and verified on a live intake
  tick (2026-09-17T20:52:24Z) before the cut.
- *flip via config after 200 rows compared against actual run outcomes*:
  impossible — heuristic, logger, helper and the seat-group consumer are all
  deleted; nothing exists to flip and no rows can accumulate.
- *termination: next intake tick logs the jev tier per issue*: fired on this
  issue's own 2026-09-17 claim, evidenced above.

## Residual path

If a per-issue tier or seat-group decision point is ever reintroduced, the
shadow attaches via the `/jev` pass-through under the cascade pattern in
`docs/jev-cascade.md` — a new organ requiring Nish's explicit yes (no-glue
rule), preceded by its own benchmark over real outcome-linked rows. Nothing
here claims that site is wanted; the newest authoritative act on it is its
deletion.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7403 → #8111,
fleet-ops#7399 → #8108).
