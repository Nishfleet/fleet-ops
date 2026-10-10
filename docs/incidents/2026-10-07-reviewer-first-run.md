# 2026-10-07: the risky-PR reviewer failed on every first run

## Impact
Every review-risky run failed in 4 seconds from 19:43Z (0509 #7272 run 37676671633, #7269, fleet-ops #9366, #9414, #9416). No PR was approved or armed by the reviewer, so reviewed risky PRs kept waiting. hold-risky still held them, so nothing merged unreviewed.

## Cause
agent.yml's `review` job ran `pi --print --provider litellm` without `FLEET_TASK_ID`. Pi's litellm provider reads `x-litellm-session-id` from that variable (config/pi-models.json) and refuses to start without it: `Failed to resolve provider "litellm" header "x-litellm-session-id" from environment variable: FLEET_TASK_ID`. The worker job sets it; the new job did not. CI cannot run pi, so it passed.

## Detection
The fleet manager saw the `dispatch / review-risky / review` check red on the first real runs.

## Fix
The review step sets `FLEET_TASK_ID: review-<run id>-<attempt>`. The already-reviewed count also used `bc`, which the runner may lack; it now uses awk.

## Prevention
A first run on a real PR is the only test of this job. The next risky PR after this fix is the proof; the held-out scoring of the reviewer (AGENTS.md line 21) is still owed.
