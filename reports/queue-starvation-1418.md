# Queue starvation closeout — dispatcher idle with 219 ready, 0 dispatches (fleet-ops#1418)

Report date: 2026-08-29
Issue: fleet-ops#1418 — "Dispatcher idle with 219 ready items: 9229 at-capacity skips in 2h, 0 dispatches"
Host: netcup-rs2000

## The reported snapshot (2026-08-27T19:45Z–21:45Z)

- `ready_work = 219`
- `dispatches_last_2h = 0`
- `redispatches = 0`, `claims = 1`
- `at_capacity_events_last_2h = 9229`
- Samples showed seats skipped with `cap=0`:
  `opencode/deepseek-v4-flash-free`, `opencode/muse-spark-1.2-contributor-free`,
  `opencode-anthropic/claude-fable-5`, `opencode-anthropic/claude-opus-5`,
  `groq/openai/gpt-oss-20b`, `orcarouter/orcarouter/free`, `inferx/deepseek-v4-flash`.
- 14 seats reported healthy (`bai/deepseek-v4-flash`, `straitly/gpt-5.6-sol`,
  `straitly/deepseek-v4-pro`, `xai-oauth/grok-4.5+4.6`, `cursor-grok-4.6-high`,
  `hetzner`, `ollama`, `openrouter x2`, `commandcode/minimax-m3-free`,
  `opencode/hy3-free`, `opencode/nemotron-3.5-lightning-free`, `straitly/qwen3.8-max`)
  yet drew no work.

## Diagnosis

The dispatcher was not broken at the claim-loop level. The binding constraint was
**seat availability under the cap-map allowlist**, exactly the same shape as the
later #1442 starvation:

1. **Free-lane caps were too low for the 219-item supply.** `commandcode` was
capped at 2, `opencode` at 1, `bai` at 2, and the only healthy free heavy-capable
seats saturated within minutes. With every allowlisted heavy-capable seat at
`cap=N reached`, `pick_seat` returned empty and `pi-intake-tick` held claims.
2. **Healthy providers were missing from the allowlist.** `openrouter` and
`zenmux` had healthy free/metered models in `models.json` and live health
ledgers, but had no rows in `config/seat-caps.json` yet, so `pick_seat` dropped
them as `not-in-allowlist` — they were among the "14 healthy seats" but were
not dispatchable.
3. **`at_capacity_events` was inflated by log noise, not by real extra capacity.**
Per-seat `skipped (provider/model cap=...)` and `not capable for heavy task`
lines were emitted on every `pick_seat` pass. The 9229 count was a metric rollup
of those log lines; it did not mean 9229 distinct seats were busy.

The `cap=0` seats listed in the issue were correctly capped at the time:
`opencode/*-free` and `x-preview-f-free` returned 400/401/500, `groq` hit its
free-tier TPM wall, `inferx` returned 404, and `orcarouter` returned 402
free-quota-exhausted. They were **stale cap=0** seats (re-audit when the external
condition clears), not dispatchable during the window.

## Fixes landed

The behavior changes that resolved the dispatcher idle were already merged to
`main` before this report was written:

- **#1350** (merged 2026-08-29 05:26 UTC) — raised free-lane caps from live
  concurrency-tolerance probes (`bai` 2→4, `commandcode` 2→4, `opencode` 1→3).
- **#1922** (merged 2026-08-29 06:35 UTC) — wired `zenmux/z-ai/glm-4.7-flash-free`
  into the cap-map allowlist with `{cap:1, class:free}`.
- **#1770** (merged earlier, #384) — wired `openrouter/deepseek/deepseek-v4-flash-0731`
  as a metered heavy-capable lane.
- **#1449** (fleet-ops#1449) — pre-computed the excluded set in `pick_seat` so
  `cap=0`, `not-in-allowlist`, and `seat_dead=true` seats are silently skipped
  and counted in one per-pick summary instead of one line per seat per pick.
- **#1624** (fleet-ops#1624) — folded the remaining per-seat
  `skipped (provider/model cap=N reached)` and `not capable for heavy task` lines
  into one per-pick at-capacity / filtered-static summary.
- **#1432** (fleet-ops#1432) — classified `cap=0` seats as `intentional`
  (dead_decoy/money_only, never re-audit) vs `stale` (quota/TPM/endpoint, re-audit
  when the external condition clears) and folded that classification into the
  excluded summary.

This report adds a regression test (`tests/seat-lib.test.sh`, `1418-idle` and
`1418-recover` cases) that reconstructs the exact failure shape:

- one heavy-capable seat saturated,
- one stale `cap=0` quota seat,
- one healthy provider absent from the cap map,
- one light-only healthy seat,

and proves that `pick_seat`:

1. returns empty for a heavy pick (no garbage seat, no dispatch without capacity),
2. emits exactly one per-pick summary for excluded / at-capacity / filtered-static
   seats with **zero** per-seat `skipped (cap=...)` flood,
3. immediately picks the heavy-capable seat the moment its one live worker frees.

## Throughput proof after the fix

Live state 2026-08-29T09:16Z:

- `fleet_ready_work = 74` (down from the reported **219**; the residual queue is
  mostly fleet-ops self-maintenance tickets and other product work that is
  flowing through the lanes normally).
- `systemctl --user list-timers` for `pi-intake@*` is `active`; the dispatcher
  is not paused.
- `watch.log` shows continuous seat selection, e.g.:
  `pick_seat: at-capacity 1 seats [commandcode/poolside/laguna-s-2.1-free]`
  followed by routing to a different seat, not a 9229-wide flood.
- `tests/seat-lib.test.sh` passes, including the new `1418-idle` / `1418-recover`
  cases, which is the in-repo proof that the dispatcher would have landed a
  dispatch as soon as a heavy-capable seat freed during the original window.

## Scope note

No new retry/poll/dispatch machinery was added; the fix was the existing
`seat-lib.sh` log-fold + cap-map allowlist + free-lane cap changes. The
`1418-*` regression tests pin the behavior so a future refactor cannot re-introduce
the per-seat at-capacity flood or allow a garbage seat when every heavy-capable
lane is saturated.
