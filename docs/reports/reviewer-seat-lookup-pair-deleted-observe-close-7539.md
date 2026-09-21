# Observe-close for #7539 — the lookup and the availability check were both deleted; the router is the one mechanism

Issue #7539 (filed 2026-09-17T19:49:52Z) reported that `fleet-review-arm-check`
exited 0 while `find_senior_seat` — from the library that check sourced —
exited 1 with no output, and asked to reconcile the existing lookup with the
existing availability check, with the explicit note that "no new routing
mechanism is needed". It was observed while recovering Nishfleet/0509#2992 /
PR Nishfleet/0509#3590, which was left open with auto-merge off and the body
line `review: skipped, no capable seat`.

By the time this re-claim ran (2026-09-22 ~03:55 IST), the site itself no
longer exists: both halves of the contradiction were deleted in the
2026-09-18 glue sweep, together with the check and its test. This report is
the resolution record, same convention as the #7399 observe-close (PR #8108)
and the #7426 observe-close (PR #8114).

## What was found

1. **The divergence was real, and its shape is in the deleted source.** The
   deleted `lib/litellm-seat.sh` (2,040 lines) held both functions, and they
   answered the same question from different candidate sets:
   - `senior_seat_available()` read `jq -r '.senior_seats_in_order[]? //
     empty' config/seat-caps.json` and returned 0 on the first `seat_usable
     "$p" "$m"`.
   - `find_senior_seat()` never enumerated that ladder. It offered only
     `litellm\tsenior`, behind `litellm_ready && (( $(model_cap litellm
     senior) > 0 )) && seat_usable litellm senior`, and returned
     `litellm\tsenior` unconditionally when `GITHUB_ACTIONS=true`.
   The ladder's entries were `cursor/cursor-grok-4.6-high`,
   `xai-oauth/grok-4.6`, `openrouter/deepseek/deepseek-v4.1-flash` and
   `alibaba-coding/qwen3.8-max` (#3121, #4445) — `litellm/senior` is not among
   them. Two different candidate sets answering one question, so "availability
   passes, lookup returns nothing" was structural, not a race.
   `bin/fleet-review-arm-check` sourced the library and exited 0 iff
   `senior_seat_available`; the worker's reviewer round used
   `find_senior_seat`. That is exactly the reported pair.

2. **Both mechanisms, the check and the test are deleted.**
   `9853ec72c847b88bc05a5734db1c1fdb5449b413` ("cut(seat-lib): delete
   litellm-seat.sh — the router already does all of it", 2026-09-18 23:59:01
   +0530) removed `lib/litellm-seat.sh` (2,040 lines, containing both
   functions), `bin/fleet-review-arm-check` (56) and
   `tests/fleet-review-arm-check.test.sh` (144), and rewrote
   `prompts/worker.md` step 8 (4 lines). Its message: "LiteLLM's router
   already owns every one of those — retries (num_retries), cooldowns
   (litellm_deployment_cooled_down_total), fallbacks
   (litellm_deployment_successful_fallbacks_total), health
   (background_health_checks) and deployment state
   (litellm_deployment_state), all of which it also exports to Prometheus."
   `git merge-base --is-ancestor 9853ec72c origin/main` passes (verified at
   origin/main `ca33df3e2`, 2026-09-21; main was moving during the run).

3. **The deletion post-dates the observation.** Issue filed
   2026-09-17T19:49:52Z; deletion 2026-09-18 23:59 IST. The anomaly was real
   the day it was filed; the sweep is the fleet's answer to this exact class —
   one mechanism instead of a lookup and an availability check that can
   disagree.

4. **Nothing live carries the pair.** Live check 2026-09-22 ~03:55 IST:
   `which fleet-review-arm-check` → exit 1 (absent); no seat/arm-check binary
   in `~/.local/bin`. `grep -rIl` for
   `find_senior_seat|senior_seat_available|fleet-review-arm-check` over
   `~/.local/bin`, `~/.pi/agent` and this repo hits only old worker session
   transcripts under `~/.pi/agent/sessions/` (logs, not code) and, in-repo,
   the historical `_comment` text in `config/seat-caps.json` plus the
   `prompts/worker.md` step-8 prose that records the deletion. No tracked file
   defines or calls either function.

5. **The single surviving mechanism is the router, and it is live.**
   `~/.config/fleet-ops/litellm-proxy.yaml` defines `model_name: senior`
   (rung `openai/z-ai/glm-5.3-flash` @ paretoinference, order 1,
   max_parallel_requests 2) with the fallback map `senior: [worker-capable]`
   and `judge: [senior]`. `prompts/worker.md` step 8 (rewritten by
   `9853ec72c`) records the policy: the reviewer round runs on the `senior`
   LiteLLM model group, "the router owns its ordering, health and fallbacks,
   so there is nothing to pre-check". Availability is observable in one place
   — the `litellm_deployment_state` gauges the fleet live-state check already
   reads.

6. **The referenced product PR confirms the premise.** Nishfleet/0509#3590 is
   CLOSED, not merged, `autoMergeRequest: null`, and its body still carries
   the literal line `review: skipped, no capable seat` — the fallback the old
   pair's disagreement triggered.

7. **The dead config remnant is inert.** `config/seat-caps.json` still carries
   `senior_seats_in_order` and its `_comment_senior_order` (added for
   #3121/#4445). No tracked code reads either now — the only occurrences are
   the config text itself and historical prose. It is dead provision for a
   deleted lookup, noted here rather than pruned to stay inside this issue's
   scope.

## Reconciled against the issue's ask

- *"Reconcile the existing lookup with the existing availability check"*:
  nothing to reconcile — both are deleted, and the reconciliation the issue
  asked for was performed by the sweep, which replaced two divergent candidate
  sets with one router group. The `senior` group cannot return no seat while a
  separate availability check passes, because there is no separate check.
- *"no new routing mechanism is needed"*: honored. Rebuilding a reconciler
  would be exactly the hand-maintained duplicate the sweep removed, and would
  be new glue — banned by Nish 2026-09-19 (three times; #7828, merged as
  #8076) and by the worker packet's no-new-scripts rule. There is no surviving
  organ to extend.
- *The observed operational consequence*: "no capable seat" now resolves
  through one documented path — the reviewer round's `senior` group call either
  runs or fails every rung; on total failure step 8 skips the round, step 9
  refuses the arm, and the PR body carries `review: skipped, no capable seat`.
  That is the policy, not a divergence.

## Residual path

If the fleet ever wants a pre-round seat-availability gate again, it is a NEW
organ — Nish's explicit yes plus a benchmark are required before one is built
(no-glue rule) — and it would first need to justify why the router's own
health/fallback surface (`litellm_deployment_state`,
`litellm_deployment_successful_fallbacks_total`) is insufficient. Nothing here
claims that gate is wanted; the newest authoritative act on the site is its
deletion. The dead `senior_seats_in_order` config key is a separate, cosmetic
cleanup.

mechanism: the sweep itself resolved the issue's target — observe-close record
per the fleet's deleted-organ convention (fleet-ops#7399 → #8108,
fleet-ops#7426 → #8114).
