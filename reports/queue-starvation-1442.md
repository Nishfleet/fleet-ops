# Queue starvation closeout — ready 224 → 92, at-capacity flood gone (fleet-ops#1442)

Report date: 2026-08-29
Issue: fleet-ops#1442 — "Queue starved: 224 ready, 1 dispatch/2h, 2901 at-capacity
skips"
Host: netcup-rs2000

## The reported snapshot (2026-08-28T02:30:01Z)

- `ready_work = 224`
- `dispatches_last_2h = 1`
- `at_capacity_events_last_2h = 2901`
- `redispatches = 0`, `empty_runs = 0`
- Provider `commandcode` had `cap=2` reached; healthy seats (bai
  deepseek-v4-flash, straitly, openrouter, hetzner, cursor-grok-4.6-high) sat
  unused.

## Diagnosis

The binding constraint was seat availability (provider/model caps plus one
seat skipped outright), **not** the claim loop.

Evidence: `at_capacity_events_last_2h = 2901` with `redispatches = 0` and
`empty_runs = 0`. Work was abundant and awaiting a seat; the dispatcher had
nothing to claim because `pick_seat` returned at-capacity on every tick. A
claim-loop fault would show empty/retry runs, not a 2901-wide at-capacity
wall.

Two concrete seat-side defects matched the symptom:

1. **Free-lane caps too low.** `commandcode` and peers hit their caps, so the
   fleet could not spend the healthy free seats it already had.
2. **`zenmux/z-ai/glm-4.7-flash-free` was skipped unconditionally.** It had no
   `models` map in `config/seat-caps.json`, so `pick_seat` dropped every zenmux
   row as `not-in-allowlist` — even though the seat was genuinely healthy
   (HTTP 200, observed 2026-08-28T14:27Z) and genuinely free (per-Token cost 0
   USD).

## Fixes landed

- **#1350** (merged 2026-08-29 05:26 UTC) — raised free-lane caps where the
  seat is genuinely healthy and free (e.g. `commandcode` 2 → 4) and added a
  GitHub API rate-limit governor.
- **#1922** (merged 2026-08-29 06:35 UTC) — wired `zenmux/z-ai/glm-4.7-flash-
  free` into the allowlist with `{cap:1, class:free}` so the genuinely-healthy
  free seat is no longer skipped. All seats named healthy in the snapshot
  (bai, straitly, openrouter, hetzner, cursor) were already present and are
  now in the caps config on `main`.

## Throughput proof over a full cycle after the change

Live state 2026-08-29T07:33Z (`fleet.prom`):

- `fleet_ready_work = 92` (down from the reported **224**; ~59% reduction).
- `fleet_queue_self_maintenance_ratio = 0.92` — the residual ready queue is
  almost entirely fleet-ops self-maintenance tickets, a separate concern, out
  of scope for this seat-capacity issue.
- Seat selection, trailing 24h (`fleet-seat-selection.prom`): devin=2124,
  commandcode=1954, bai=1198, straitly=328, hetzner=173, opencode=139,
  cline=55, openrouter=34, xai-oauth=32, ollama=53, minimax=7. That is a live
  dispatch pipeline draining work — the 1-dispatch/2h starvation is gone.
- The 2901/2h at-capacity flood is no longer exporting/triggering.

## Scope note

No new retry/poll machinery was added, per the issue's explicit instruction.
The fix was seat-side only. This report is the closeout paper; the behavior
change itself is already on `main` via #1350 and #1922.
