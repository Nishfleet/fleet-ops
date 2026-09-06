feat(heartbeat): move GitHub-reading sections behind webhook triggers (fleet-ops#3270)

## What changed

The four `fleet-heartbeat-tier1` sections that only read GitHub state —
`lifecycle-label-sweep` (§6b), merged-pr observe-to-close (§19),
close-duplicates (§21), and the loose-ends canary (§43) — no longer run
inside the heartbeat tick. Each now fires on the matching GitHub event via
`gh-webhook-receiver`, with a companion backstop timer for webhooks that
never arrive. The heartbeat timer keeps only host-local sections and drops
15 -> 60 min.

| Heartbeat § | Webhook dispatch | Backstop timer |
|---|---|---|
| §6b lifecycle-label-sweep | `issues/opened` + `issues/labeled` → `lifecycle-label-sweep.service` | `lifecycle-label-sweep.timer` (hourly) |
| §19 merged-pr observe-to-close | `pull_request/closed` → `fleet-merged-pr-close.service` | `fleet-merged-pr-close.timer` (hourly) |
| §21 close-duplicates | `issues/closed` → `fleet-issue-close-duplicates.service` | `fleet-issue-close-duplicates.timer` (daily) |
| §43 loose-ends canary | `pull_request/opened` → `fleet-loose-ends-canary.service` | `fleet-loose-ends-canary.timer` (hourly) |

`gh-webhook-receiver` dispatch is now a multi-fan-out: `pull_request/closed`
fires BOTH `fleet-worktree-reaper.service` (fleet-ops#3269) and
`fleet-merged-pr-close.service`; `issues/labeled`/`opened` fire the
lifecycle sweep plus the repo-specific dispatch (intake / deploy-check).
systemd's oneshot semantics guarantee a re-dispatch of an already-active
unit is a no-op, so the webhook fast-path and the backstop timer do not
fight.

Files touched:
- `bin/fleet-heartbeat-tier1` — the four GitHub-reading sections are
  replaced by retained 0-initialised variables (for the tier-1 complete
  log line + exit-code propagation); the timer keeps only host-local
  sections.
- `systemd/fleet-heartbeat.timer` — cadence `*:17/30` -> `*:17/60`
  (15 -> 60 min), with a named reason.
- `systemd/{lifecycle-label-sweep,fleet-merged-pr-close,fleet-issue-close-duplicates,fleet-loose-ends-canary}.{service,timer}` — four new webhook-triggered units + backstop timers, each with a named reason.
- `libexec/gh-webhook-receiver/serve.py` — multi-fan-out dispatch table
  (v0.1.0 -> v0.2.0).
- `systemd/timer-manifest.json` + `docs/organ-catalog.md` — every timer
  carries a named reason.
- `MANIFEST` — install mappings for the four new service/timer pairs.
- `tests/*` — the touched tests now assert the `.service`-unit contract
  instead of the tier1 call, plus new DRY dispatch-table and HTTP cases.

net-positive-because: the four GitHub-reading sections were each a
full helper invocation per heartbeat tick; moving them behind webhook
triggers and dropping the heartbeat to 60 min removes ~80% of the
heartbeat's GitHub-state polling. The added lines are the four new
systemd unit pairs (mostly named-reason comments, which the standing
"a schedule needs a named reason" rule requires) plus the dispatch-table
tests. The net reduction in per-minute fleet work is the point of the
issue (fleet-ops#3128: heartbeat CPU/day drops > 50%).

## Verification

Ran the touched tests in the worktree; all green:

```
bash tests/gh-webhook-receiver-hmac.test.sh
bash tests/gh-webhook-receiver-prom-quotes.test.sh
bash tests/lifecycle-label-sweep.test.sh
bash tests/fleet-merged-pr-close.test.sh
bash tests/fleet-loose-ends-canary.test.sh
bash tests/manifest-required-bins.test.sh
bash tests/fleet-heartbeat-verify-timers.test.sh
bash tests/fleet-heartbeat-rc-propagation.test.sh
bash tests/fleet-organ-heartbeat.test.sh
bash tests/manifest-shape.test.sh
```

Observed (excerpts):
- `OK: 7b: pull_request/closed (merged) → [fleet-worktree-reaper, fleet-merged-pr-close] (DRY=1)`
- `OK: 7c: pull_request/opened → fleet-loose-ends-canary (DRY=1)`
- `OK: 7d: issues/opened → lifecycle-label-sweep (DRY=1)`
- `OK: 7e: issues/closed → fleet-issue-close-duplicates (DRY=1)`
- `OK: 10: dispatch counter advanced for every dispatched event (6 verified + dispatched)`
- `all lifecycle-label-sweep cases passed`
- `all fleet-merged-pr-close cases passed`
- `fleet-loose-ends-canary (fleet-ops#528) — 19 scenarios green`
- `bash -n bin/fleet-heartbeat-tier1` clean; `python3 -m py_compile serve.py` clean.

The `tests/timer-manifest.test.sh` live-timer check reports a PRE-EXISTING
drift on origin/main (host timer `0509-search-tier-canary.timer` missing
from the repo manifest) — reproduced identically on a clean `origin/main`
worktree, unrelated to this diff; all five of this PR's timers are present
in `systemd/timer-manifest.json`.

run-proof: the above test commands all exited 0 (each `all ... cases
passed` / `ALL PHASES PASSED`); the receiver's DRY=1 log shows each new
dispatch firing `rc=0`.

## Research / help-first

- No new `bin/` files are added (only `bin/fleet-heartbeat-tier1` is
  modified), so `research-before-build-check` does not apply.
- The four helpers (`lifecycle-label-sweep`, `fleet-merged-pr-close`,
  `fleet-issue-file close-duplicates`, `fleet-loose-ends-canary`) already
  exist and are installed via MANIFEST; the new systemd units wrap them.
- The multi-fan-out dispatch reuses the existing `gh-webhook-receiver`
  (fleet-ops#3269 precedent), which already receives `pull_request` events.

## Test plan

1. `gh-webhook-receiver-hmac.test.sh` — dispatch-table + live-subprocess
   HTTP cases for every new fan-out (DRY=1).
2. `lifecycle-label-sweep.test.sh` / `fleet-merged-pr-close.test.sh` /
   `fleet-loose-ends-canary.test.sh` — the moved helpers still pass their
   full contract suites; the contract assertions now point at the
   `.service` units.
3. `fleet-heartbeat-verify-timers.test.sh` / `timer-manifest` — the
   heartbeat cadence and the new backstop timers are declared in the
   manifest with named reasons.

Closes #3270
